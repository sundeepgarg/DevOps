# ODF — OpenShift Data Foundation Interview Guide

**Target Role:** Principal Platform Engineer / OpenShift Architect / SRE
**Background:** ODF deployed at Voya for model artefact storage, log stack (Loki), AI platform data

---

## 1. What is ODF?

OpenShift Data Foundation (ODF) is Red Hat's software-defined storage platform for OpenShift,
built on **Ceph** (open-source) with Red Hat support and OCP integration.

ODF provides three storage types from a single platform:

```
┌─────────────────────────────────────────────────────────────┐
│              OpenShift Data Foundation (ODF)                │
│                  (powered by Ceph + Rook)                   │
├─────────────────┬───────────────────┬───────────────────────┤
│  BLOCK STORAGE  │  FILE STORAGE     │  OBJECT STORAGE       │
│  (Ceph RBD)     │  (CephFS)         │  (Ceph RGW / RADOS)   │
│                 │                   │                       │
│  ReadWriteOnce  │  ReadWriteMany    │  S3-compatible API    │
│  (RWO PVCs)     │  (RWX PVCs)       │  REST API             │
│                 │                   │                       │
│  Use: DB        │  Use: shared NFS  │  Use: ML models,      │
│  volumes,       │  CI/CD artifacts, │  logs, backups,       │
│  stateful apps  │  shared configs   │  object storage       │
└─────────────────┴───────────────────┴───────────────────────┘
```

**Why ODF instead of external storage?**
```
External NFS/SAN:   Storage admin required, single point of failure, manual provisioning
AWS EBS/EFS:        Vendor lock-in, egress costs, not available on-prem

ODF advantages:
  → Runs on OpenShift worker nodes (no external storage needed)
  → Self-healing — loses a node? Data automatically rebalanced
  → Dynamic provisioning via StorageClasses (no manual LUN allocation)
  → S3-compatible API on-cluster (no egress costs for ML artefacts)
  → OpenShift-native — CSI drivers, operator lifecycle, monitoring built-in
  → Multi-availability-zone replication (3-way replica across failure domains)
```

---

## 2. Ceph Architecture (the engine inside ODF)

```
┌─────────────────────────────────────────────────────────────────┐
│                    CEPH CLUSTER (inside ODF)                    │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐   MON (Monitors)    │
│  │  MON 1   │  │  MON 2   │  │  MON 3   │   Track cluster     │
│  └──────────┘  └──────────┘  └──────────┘   state, quorum     │
│                                                                 │
│  ┌──────────────────────────────────────┐                       │
│  │         MGR (Manager)                │   Metrics, modules,  │
│  │         (active + standby)           │   Dashboard          │
│  └──────────────────────────────────────┘                       │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐   OSD (Object       │
│  │  OSD 1   │  │  OSD 2   │  │  OSD 3   │   Storage Daemons)  │
│  │  /dev/sdb│  │  /dev/sdb│  │  /dev/sdb│   One per disk      │
│  └──────────┘  └──────────┘  └──────────┘   Stores data       │
│                                                                 │
│  ┌──────────────────────────────────────┐                       │
│  │         MDS (Metadata Server)        │   CephFS only        │
│  │         (for CephFS only)            │   Directory metadata │
│  └──────────────────────────────────────┘                       │
│                                                                 │
│  ┌──────────────────────────────────────┐                       │
│  │         RGW (RADOS Gateway)          │   S3 / Swift API     │
│  │         (Object Store)               │   HTTP endpoint      │
│  └──────────────────────────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

### Ceph Components Explained

**MON (Monitor) — The Cluster Brain**
```
Maintains the "cluster map" — knows where every piece of data lives.
Requires quorum (majority must agree) → always deploy odd number (3 or 5).
ODF deploys 3 MONs by default, one per failure domain (node or zone).

If 2+ MONs are down: cluster becomes READ-ONLY (no writes until quorum restored).
Monitors communicate via Paxos consensus algorithm.
```

**OSD (Object Storage Daemon) — The Workhorse**
```
One OSD per physical disk (SSD or HDD).
Stores actual data as objects in RADOS (Reliable Autonomic Distributed Object Store).
Handles replication — each OSD manages its own replicas to peer OSDs.
ODF minimum: 3 OSDs (one per node in 3-node cluster).
Production: 1 OSD per SSD per node, typically 3-12 OSDs per node.

OSD states:
  up + in  = working normally, storing data
  down + in = crashed but data still attributed to it (temporary)
  up + out  = being removed, data migrated away
  down + out = failed, data already moved
```

**MGR (Manager) — Metrics and Modules**
```
Collects cluster performance metrics exposed to Prometheus.
Runs optional modules: dashboard, balancer, insights.
Active-standby: one active MGR, one standby for HA.
```

**MDS (Metadata Server) — CephFS Only**
```
Manages the directory tree for CephFS (file storage).
Not needed for block (RBD) or object (RGW) storage.
Active-standby deployment.
```

**RGW (RADOS Gateway) — Object Storage API**
```
HTTP gateway exposing RADOS object store as:
  - S3-compatible API (default)
  - Swift API
Runs as a deployment in OpenShift.
Multiple RGW instances for HA and throughput.
This is what KServe, MLflow, and Loki use to store data in ODF.
```

### CRUSH Algorithm — How Data is Placed

```
CRUSH (Controlled Replication Under Scalable Hashing)

When data is written:
  1. Hash the object ID → PGID (Placement Group ID)
  2. Apply CRUSH map to PGID → list of OSD IDs where replicas go
  3. Write to primary OSD → primary replicates to secondary/tertiary

CRUSH map hierarchy (failure domains):
  root
  ├── datacenter-a
  │   ├── rack-1
  │   │   ├── node-1 → OSD 1, OSD 2, OSD 3
  │   │   └── node-2 → OSD 4, OSD 5, OSD 6
  │   └── rack-2
  │       └── node-3 → OSD 7, OSD 8, OSD 9
  └── datacenter-b
      └── ...

ODF configures CRUSH to spread replicas across failure domains.
3-way replication across 3 nodes = tolerate 1 full node failure with no data loss.
3-way replication across 3 zones = tolerate 1 full AZ failure with no data loss.
```

---

## 3. ODF Storage Classes

### 3.1 Block Storage (Ceph RBD)

```yaml
# StorageClass created by ODF automatically
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ocs-storagecluster-ceph-rbd
provisioner: openshift-storage.rbd.csi.ceph.com
parameters:
  clusterID: <cluster-id>
  pool: ocs-storagecluster-cephblockpool
  imageFormat: "2"
  imageFeatures: layering,fast-diff,object-map,deep-flatten,exclusive-lock
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

**Using block storage:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-block-pvc
spec:
  storageClassName: ocs-storagecluster-ceph-rbd
  accessModes:
    - ReadWriteOnce    # Only ONE pod can mount at a time
  resources:
    requests:
      storage: 50Gi
```

**Use cases:** Databases (PostgreSQL, MySQL), stateful apps, Prometheus data.

### 3.2 File Storage (CephFS)

```yaml
# StorageClass for CephFS (shared file system)
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ocs-storagecluster-cephfs
provisioner: openshift-storage.cephfs.csi.ceph.com
parameters:
  clusterID: <cluster-id>
  fsName: ocs-storagecluster-cephfilesystem
reclaimPolicy: Delete
allowVolumeExpansion: true
```

**Using file storage:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-file-pvc
spec:
  storageClassName: ocs-storagecluster-cephfs
  accessModes:
    - ReadWriteMany    # MULTIPLE pods can mount simultaneously
  resources:
    requests:
      storage: 100Gi
```

**Use cases:** CI/CD shared artefact storage, Jupyter notebook home directories,
shared config files, anything needing simultaneous access from multiple pods.

### 3.3 Object Storage (Ceph RGW — S3-Compatible)

Object storage works differently — not PVCs, but Bucket claims:

```yaml
# ObjectBucketClaim — request an S3 bucket
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ml-models-bucket
  namespace: mlops
spec:
  bucketName: ml-models          # bucket name in Ceph RGW
  storageClassName: openshift-storage.noobaa.io  # or ocs-storagecluster-ceph-rgw

# cert-manager creates two objects after this:
# 1. ConfigMap "ml-models-bucket" → BUCKET_NAME, BUCKET_HOST, BUCKET_PORT, BUCKET_REGION
# 2. Secret "ml-models-bucket"    → AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
```

**Using the bucket in a pod:**
```yaml
envFrom:
  - configMapRef:
      name: ml-models-bucket   # gives BUCKET_HOST, BUCKET_NAME, etc.
  - secretRef:
      name: ml-models-bucket   # gives AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

# Then use standard boto3/S3 SDK with:
# endpoint_url = http://BUCKET_HOST:BUCKET_PORT (the RGW endpoint)
# access_key   = AWS_ACCESS_KEY_ID from Secret
# region       = "us-east-1" (dummy value, required by SDKs)
```

**Using with MLflow / KServe:**
```python
import boto3
import os

s3 = boto3.client(
    's3',
    endpoint_url=f"http://{os.environ['BUCKET_HOST']}:{os.environ['BUCKET_PORT']}",
    aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],
    aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'],
    region_name='us-east-1'
)
# Now read/write ML model artefacts to ODF S3
s3.upload_file('model.pkl', os.environ['BUCKET_NAME'], 'models/v1/model.pkl')
```

---

## 4. ODF Deployment

### Minimum Requirements

```
Nodes:      3 minimum (ODF deploys across 3 nodes for replication)
Disks:      1 dedicated SSD per node minimum (ODF does NOT use root disk)
            ODF uses raw, unformatted disks
CPU/RAM:    12 vCPU / 24 GB RAM per node minimum (production: more)
OCP version: 4.9+ for ODF 4.x

Node labels: ODF only installs on nodes labelled:
  cluster.ocs.openshift.io/openshift-storage: ""
```

### StorageCluster CRD

```yaml
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  storageDeviceSets:
  - name: ocs-deviceset
    count: 1                    # number of device sets (scales OSDs)
    replica: 3                  # 3 OSDs per device set (one per node)
    resources:
      requests:
        cpu: "2"
        memory: "5Gi"
    dataPVCTemplate:
      spec:
        storageClassName: gp2   # underlying storage for OSD data
        accessModes:
          - ReadWriteOnce
        volumeMode: Block       # raw block device (not filesystem)
        resources:
          requests:
            storage: 1Ti        # size of each OSD

  # Multi-AZ deployment
  failureDomain: zone           # spread OSDs across zones (vs node or rack)

  # Enable object storage RGW
  managedResources:
    cephObjectStoreUsers:
      reconcileStrategy: manage
    cephObjectStores:
      reconcileStrategy: manage

  # Encryption at rest (ODF 4.6+)
  encryption:
    enable: true
    kms:
      enable: true             # encrypt with Vault KMS
```

---

## 5. Log Stack on ODF — Loki + OpenShift Logging

OpenShift Logging uses **Loki** (log aggregation) with ODF object storage as the backend.
Replaces the older Elasticsearch-based stack (EFK: Elasticsearch + Fluentd + Kibana).

### Architecture Overview

```
                    ┌─────────────────────────────────────────┐
                    │         OpenShift Cluster               │
                    │                                         │
  ┌─────────────┐   │  ┌──────────┐   ┌───────────────────┐  │
  │  All pods   │   │  │  Vector  │   │   LokiStack        │  │
  │  emit logs  │──►│  │(collector│──►│                   │  │
  │  to stdout  │   │  │DaemonSet)│   │  ┌─────────────┐  │  │
  └─────────────┘   │  └──────────┘   │  │  Distributor│  │  │
                    │                 │  │  (receive)  │  │  │
  ┌─────────────┐   │  ┌──────────┐   │  └──────┬──────┘  │  │
  │  OCP audit  │──►│  │  Vector  │   │         │         │  │
  │  logs       │   │  │          │   │  ┌──────▼──────┐  │  │
  └─────────────┘   │  └──────────┘   │  │  Ingester   │  │  │
                    │                 │  │  (write WAL)│  │  │
  ┌─────────────┐   │  ┌──────────┐   │  └──────┬──────┘  │  │
  │  OCP infra  │──►│  │  Vector  │   │         │         │  │
  │  logs       │   │  │          │   │  ┌──────▼──────┐  │  │
  └─────────────┘   │  └──────────┘   │  │  Compactor  │  │  │
                    │                 │  │  (chunks)   │  │  │
                    │                 │  └──────┬──────┘  │  │
                    │                 │         │         │  │
                    │                 │  ┌──────▼──────┐  │  │
                    │                 │  │  ODF S3     │  │  │
                    │                 │  │  (chunks +  │  │  │
                    │                 │  │   index)    │  │  │
                    │                 │  └─────────────┘  │  │
                    │                 │                   │  │
                    │                 │  ┌─────────────┐  │  │
                    │                 │  │  Querier    │◄─┼──┼─── Grafana / OCP Console
                    │                 │  │  (read)     │  │  │    LogQL queries
                    │                 │  └─────────────┘  │  │
                    │                 └───────────────────┘  │
                    └─────────────────────────────────────────┘
```

### Loki Architecture Components

**Distributor:**
```
Receives log streams from Vector collectors.
Validates and pre-processes incoming logs.
Hashes the stream labels to determine which Ingester to route to.
Stateless — multiple replicas for horizontal scaling.
```

**Ingester:**
```
Holds logs in memory (Write-Ahead Log / WAL) for fast writes.
Periodically flushes chunks to object storage (ODF S3 via RGW).
Builds the index (maps labels to chunk locations).
Stateful — uses PVCs for WAL persistence.
```

**Compactor:**
```
Merges small chunks into larger ones (improves query performance).
Manages log retention — deletes expired chunks from object storage.
Runs periodically in the background.
```

**Querier:**
```
Handles LogQL queries from Grafana / OCP console.
Fetches chunks from object storage and in-memory ingesters.
Merges results and returns to client.
Stateless — scales horizontally for query load.
```

**Query Frontend:**
```
Splits large queries into smaller shards (parallelise query across Queriers).
Caches query results to reduce repeated object storage reads.
```

### What Gets Stored in ODF for Loki

```
ODF S3 bucket (loki-chunks):
  chunks/
    <stream-hash>/
      <timestamp>-<uuid>.gz   ← compressed log chunks (TSDB format)

ODF S3 bucket (loki-index):
  index/
    <period>/
      <table>/
        <file>.gz              ← BoltDB Shipper index or TSDB index

Each chunk: compressed group of log lines for one label set over a time window
Typical chunk size: 256KB–1MB uncompressed, ~50–100KB compressed (gzip)
Retention: configured in LokiStack → Compactor deletes old chunks from ODF
```

---

## 6. Installing the Log Stack

### Step 1 — Install OpenShift Logging Operator

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: stable
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

### Step 2 — Install Loki Operator

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

### Step 3 — Create ObjectBucketClaim for Loki in ODF

```yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: loki-odf-bucket
  namespace: openshift-logging
spec:
  bucketName: loki-logs
  storageClassName: openshift-storage.noobaa.io
```

### Step 4 — Create LokiStack Secret (ODF credentials)

```bash
# Extract credentials from ObjectBucketClaim
BUCKET_HOST=$(kubectl get cm loki-odf-bucket -n openshift-logging \
  -o jsonpath='{.data.BUCKET_HOST}')
BUCKET_PORT=$(kubectl get cm loki-odf-bucket -n openshift-logging \
  -o jsonpath='{.data.BUCKET_PORT}')
ACCESS_KEY=$(kubectl get secret loki-odf-bucket -n openshift-logging \
  -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SECRET_KEY=$(kubectl get secret loki-odf-bucket -n openshift-logging \
  -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

# Create the Secret Loki operator expects
kubectl create secret generic lokistack-odf-secret \
  -n openshift-logging \
  --from-literal=access_key_id="${ACCESS_KEY}" \
  --from-literal=access_key_secret="${SECRET_KEY}" \
  --from-literal=bucketnames="loki-logs" \
  --from-literal=endpoint="http://${BUCKET_HOST}:${BUCKET_PORT}" \
  --from-literal=region="us-east-1"
```

### Step 5 — Deploy LokiStack

```yaml
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  size: 1x.small    # 1x.extra-small, 1x.small, 1x.medium, 1x.large

  # Object storage backend — ODF S3
  storage:
    secret:
      name: lokistack-odf-secret
      type: s3
    schemas:
    - version: v13
      effectiveDate: "2024-01-01"

  # Log retention
  limits:
    global:
      retention:
        days: 30

  # Storage class for WAL (ingester PVCs) — use ODF block storage
  storageClassName: ocs-storagecluster-ceph-rbd

  tenancy:
    mode: openshift-logging    # multi-tenant: each namespace isolated
```

**LokiStack sizes:**

| Size | Use case | Ingesters | Queriers | Storage |
|---|---|---|---|---|
| 1x.extra-small | Dev/test | 1 | 1 | 10Gi WAL |
| 1x.small | Small cluster (<50 nodes) | 2 | 2 | 50Gi WAL |
| 1x.medium | Medium cluster (50-250 nodes) | 3 | 4 | 150Gi WAL |
| 1x.large | Large cluster (250+ nodes) | 5 | 6 | 300Gi WAL |

### Step 6 — Configure ClusterLogging (log collection)

```yaml
apiVersion: logging.openshift.io/v1
kind: ClusterLogging
metadata:
  name: instance
  namespace: openshift-logging
spec:
  managementState: Managed
  logStore:
    type: lokistack
    lokistack:
      name: logging-loki
  collection:
    type: vector    # Vector replaces Fluentd in OpenShift Logging 5.7+
```

### Step 7 — Configure ClusterLogForwarder (routing)

```yaml
apiVersion: logging.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: openshift-logging
spec:
  inputs:
  - name: application-logs
    application: {}          # All application namespace logs
  - name: infrastructure-logs
    infrastructure: {}       # kube-system, openshift-* namespace logs
  - name: audit-logs
    audit: {}                # Kubernetes/OCP API audit logs

  outputs:
  - name: loki-output
    type: lokiStack
    lokiStack:
      name: logging-loki
      namespace: openshift-logging
      authentication:
        token:
          from: serviceAccount

  pipelines:
  - name: all-to-loki
    inputRefs:
      - application-logs
      - infrastructure-logs
      - audit-logs
    outputRefs:
      - loki-output
```

---

## 7. Vector — Log Collector

Vector replaced Fluentd as the default log collector in OpenShift Logging 5.7+.

```
Fluentd (old):  Ruby-based, slower, high memory usage (~300MB per node)
Vector (new):   Rust-based, fast, low memory (~50MB per node), Datadog acquired it

Vector runs as a DaemonSet — one pod per node.
Tails: /var/log/pods/*/*/*.log  (Kubernetes container logs)
       /var/log/audit/          (node audit logs)
       journald                 (systemd journal)

Vector parsing:
  Detects log format (JSON, plain text, multiline)
  Adds Kubernetes metadata (pod name, namespace, labels, node)
  Buffers to disk if Loki is unavailable (backpressure handling)
  Ships to Loki via HTTP push API
```

**Vector configuration (generated by OpenShift Logging operator):**
```toml
# /etc/vector/vector.toml (auto-generated, do not edit manually)

[sources.raw_container_logs]
type = "kubernetes_logs"
auto_partial_merge = true

[transforms.parse_json]
type = "remap"
inputs = ["raw_container_logs"]
source = '''
  # Try to parse as JSON
  parsed, err = parse_json(.message)
  if err == null {
    . = merge(., parsed)
  }
  # Add cluster metadata
  .openshift.cluster_id = "${CLUSTER_ID}"
'''

[sinks.loki_output]
type = "loki"
inputs = ["parse_json"]
endpoint = "http://logging-loki-gateway.openshift-logging.svc:8080"
auth.strategy = "bearer"
auth.token = "${SERVICE_ACCOUNT_TOKEN}"

[sinks.loki_output.labels]
kubernetes_namespace_name = "{{ kubernetes.namespace_name }}"
kubernetes_pod_name = "{{ kubernetes.pod_name }}"
log_type = "{{ log_type }}"
```

---

## 8. Querying Logs — LogQL

LogQL is Loki's query language, inspired by PromQL.

### Basic Syntax

```
{label="value"}                   → filter by label (stream selector)
{label="value"} |= "error"        → filter lines containing "error"
{label="value"} != "debug"        → exclude lines with "debug"
{label="value"} |~ "error|warn"   → regex match
{label="value"} | json            → parse JSON log lines
{label="value"} | json | field > 5 → filter by parsed JSON field
```

### Common OpenShift Log Queries

```logql
# All logs from a specific namespace
{kubernetes_namespace_name="payments"}

# Error logs from a specific pod
{kubernetes_namespace_name="payments", kubernetes_pod_name=~"api-.*"} |= "ERROR"

# Logs from all pods in a deployment
{kubernetes_namespace_name="payments", kubernetes_deployment_name="payment-api"}

# Parse JSON logs and filter by field
{kubernetes_namespace_name="payments"}
  | json
  | level = "error"
  | line_format "{{.timestamp}} {{.message}}"

# Rate of error logs per minute (metric query)
rate({kubernetes_namespace_name="payments"} |= "ERROR" [1m])

# Audit logs for a specific user
{log_type="audit"} | json | user_username = "developer1"

# Infrastructure: etcd errors
{log_type="infrastructure", kubernetes_namespace_name="openshift-etcd"} |= "error"

# Top error messages (aggregation)
topk(10,
  sum by (kubernetes_pod_name) (
    rate({kubernetes_namespace_name="payments"} |= "error" [5m])
  )
)
```

### Querying in Grafana

```
Data source: Loki
URL: http://logging-loki-gateway.openshift-logging.svc:8080

Dashboard panel configuration:
  Query type: Logs (for log lines) or Metric (for rates/aggregations)
  Label filters: kubernetes_namespace_name, kubernetes_pod_name
  Line filters: |= "error"

Useful Grafana variables for log dashboards:
  $namespace = label_values(kubernetes_namespace_name)
  $pod       = label_values({kubernetes_namespace_name="$namespace"}, kubernetes_pod_name)
```

### Querying in OpenShift Console

```
OpenShift Console → Observe → Logs

Log types:
  Application:     logs from workload pods
  Infrastructure:  logs from kube-system, openshift-* namespaces
  Audit:           API server audit trail

Filter by:
  Namespace, pod, severity
  Time range
  Free-text search
  LogQL query
```

---

## 9. Log Retention and Storage Sizing

```
Log volume estimation:
  Average log rate: 1-5 KB/line, 100-1000 lines/min/pod
  100 pods:        ~10-50 MB/min uncompressed
  Loki compression ratio: ~10x
  So 100 pods:     ~1-5 MB/min compressed

  30-day retention for 100 pods:
    5 MB/min × 60 × 24 × 30 = 216 GB compressed
    Add 20% overhead          = ~260 GB in ODF

  ODF object storage is cheap — no problem storing this.

LokiStack retention config:
  spec:
    limits:
      global:
        retention:
          days: 30           # global retention
      tenants:
        application:
          retention:
            days: 14         # shorter retention for app logs
        infrastructure:
          retention:
            days: 90         # keep infra logs longer (compliance)
        audit:
          retention:
            days: 365        # audit logs for compliance (1 year)
```

---

## 10. ODF Monitoring and Health Checks

```bash
# ODF cluster health
oc get storagecluster -n openshift-storage
# STATUS: Ready (or Progressing, Error)

# Ceph cluster status (via toolbox pod)
TOOLS_POD=$(oc get pod -n openshift-storage -l app=rook-ceph-tools \
  -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-storage -it ${TOOLS_POD} -- ceph status
# health: HEALTH_OK
# mon: 3 daemons, quorum a,b,c
# mgr: a(active), standbys: b
# osd: 9 osds: 9 up, 9 in
# data: 850 GiB used, 2.1 TiB avail

# OSD utilisation
oc exec -n openshift-storage -it ${TOOLS_POD} -- ceph osd df tree

# RGW (S3) status
oc exec -n openshift-storage -it ${TOOLS_POD} -- radosgw-admin zone get

# List S3 buckets
oc exec -n openshift-storage -it ${TOOLS_POD} -- radosgw-admin bucket list

# PVC check
oc get pvc -n openshift-storage

# ObjectBucketClaims
oc get objectbucketclaim -A

# Loki health
oc get lokistack -n openshift-logging
oc get pods -n openshift-logging
```

### Key Metrics to Watch

```
Ceph metrics (via Prometheus):
  ceph_health_status == 0 (0=OK, 1=WARN, 2=ERROR)
  ceph_osd_up         ← number of OSDs up (should equal total OSDs)
  ceph_osd_in         ← number of OSDs in (participating in data)
  ceph_pool_percent_used < 80  ← OSD usage per pool
  ceph_mon_quorum_status == 1  ← monitor quorum healthy

Loki metrics:
  loki_ingester_chunks_flushed_total  ← chunks written to ODF
  loki_request_duration_seconds       ← query latency
  loki_distributor_bytes_received_total ← ingest rate
  loki_compactor_running              ← compactor health
```

---

## 11. Common Issues and Troubleshooting

### OSD Down

```
Symptom: ceph status shows "osd: X up, Y in" where X < Y

Cause:   OSD pod crashed — usually disk issue, OOM, or node failure

Debug:
  oc get pods -n openshift-storage | grep osd
  oc describe pod <osd-pod> -n openshift-storage
  oc logs <osd-pod> -n openshift-storage

Recovery:
  If node is down: ODF waits 10 min before marking OSD "out" and rebalancing
  If OSD crashed: pod auto-restarts (Deployment controller)
  If disk failed: replace disk, ODF will provision new OSD automatically

Data safety: With 3-way replication, 1 OSD failure = no data loss
             2 OSD failures in same replica set = potential data loss
```

### Logs Not Appearing in Grafana

```
Check 1: Vector collector is running
  oc get pods -n openshift-logging | grep vector
  oc logs -n openshift-logging daemonset/collector

Check 2: LokiStack is healthy
  oc get lokistack -n openshift-logging
  oc get pods -n openshift-logging | grep loki

Check 3: ClusterLogForwarder is configured
  oc describe clusterlogforwarder instance -n openshift-logging
  # Check pipeline status conditions

Check 4: ODF bucket is accessible
  oc get objectbucketclaim loki-odf-bucket -n openshift-logging
  oc describe objectbucketclaim loki-odf-bucket -n openshift-logging

Check 5: Loki can reach ODF S3
  oc exec -n openshift-logging deploy/logging-loki-compactor -- \
    curl http://<bucket-host>:<port>/health
```

### Object Storage Full

```
Symptom: ODF storage utilisation > 80% → HEALTH_WARN
         ODF storage utilisation > 85% → cluster stops accepting writes

Immediate fix:
  # Reduce Loki retention
  oc patch lokistack logging-loki -n openshift-logging \
    --type merge -p '{"spec":{"limits":{"global":{"retention":{"days":7}}}}}'

  # Or add more OSD nodes (scale out ODF)
  oc patch storagecluster ocs-storagecluster -n openshift-storage \
    --type json -p '[{"op":"replace","path":"/spec/storageDeviceSets/0/count","value":2}]'
  # Increases from 3 to 6 OSDs if count was 1
```

---

## 12. Interview Questions

### Q: What is ODF and how does it differ from external NFS/SAN storage?

ODF is a software-defined storage platform running ON OpenShift nodes, powered by Ceph + Rook.
It provides block (RBD), file (CephFS), and object (RGW/S3) storage from a single platform.

Key differences from external storage:
- **Self-healing:** ODF rebalances data automatically when a node fails. External NFS needs manual repair.
- **Dynamic provisioning:** StorageClasses provision PVCs automatically. External SAN requires LUN allocation by a storage admin.
- **On-cluster S3:** RGW provides S3-compatible API without egress. No external AWS S3 or Minio needed.
- **Multi-failure-domain:** Data replicated across 3 nodes/zones. NFS is typically single-node.

---

### Q: Explain Ceph's CRUSH algorithm.

CRUSH (Controlled Replication Under Scalable Hashing) determines which OSDs store each piece of data.

When data is written:
1. Object ID is hashed to a Placement Group (PG) number.
2. CRUSH algorithm takes the PG number and the cluster map (topology of nodes, racks, zones).
3. CRUSH computes which OSDs to use for each replica deterministically — no central directory needed.
4. Data is written to the primary OSD; primary replicates to 2 secondary OSDs.

The CRUSH failure domain rules ensure replicas land in different nodes/racks/zones.
A 3-replica pool with zone failure domain tolerates a full AZ failure with no data loss.

---

### Q: How does the Loki log stack work on ODF?

Log flow: Container logs → Vector DaemonSet → Loki Distributor → Loki Ingester → ODF S3.

Vector (one pod per node) tails container logs from `/var/log/pods` and ships them to Loki's HTTP push API with Kubernetes metadata (namespace, pod, labels) as stream labels.

Loki's Distributor receives logs, validates, and routes to Ingesters based on stream label hashing. Ingesters buffer in memory (Write-Ahead Log on ODF RBD PVCs) then flush compressed chunks to ODF S3 (via Ceph RGW).

Queries from Grafana hit the Loki Querier, which fetches relevant chunks from ODF S3 and in-memory Ingesters, merges results, and returns to the user.

ODF provides: WAL persistence (RBD block PVCs for Ingesters), chunk storage (S3/RGW for compressed log chunks), index storage (S3 for BoltDB/TSDB index).

---

### Q: What is an ObjectBucketClaim and how does it work?

ObjectBucketClaim (OBC) is a Kubernetes CRD that provisions an S3 bucket in ODF (or any S3-compatible storage via OBC operator).

When an OBC is created:
1. OBC operator talks to the object store (Ceph RGW or NooBaa).
2. Creates the bucket and a dedicated set of credentials.
3. Creates a ConfigMap with bucket endpoint details (host, port, name).
4. Creates a Secret with AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.

Applications mount the ConfigMap and Secret as environment variables and connect using standard S3 SDK (boto3, AWS SDK) with the ODF endpoint URL.

This is how MLflow, KServe, and Loki store data on ODF without hardcoded credentials.

---

### Q: CephFS vs Ceph RBD — when do you use each?

**Ceph RBD (block storage):**
- Access mode: ReadWriteOnce (one pod at a time)
- Use for: databases, stateful apps that need exclusive access
- Better performance for sequential I/O (database writes)
- Like a virtual hard drive

**CephFS (file storage):**
- Access mode: ReadWriteMany (multiple pods simultaneously)
- Use for: CI/CD shared artefacts, Jupyter notebook home dirs, shared config
- POSIX filesystem — directory tree, file permissions
- Slightly more overhead than RBD (MDS coordinates metadata)

---

### Q: How does ODF handle a node failure?

ODF stores 3 replicas of every piece of data on 3 different nodes (with default 3x replication).

When a node fails:
1. Ceph monitors (MONs) detect the OSDs on that node are down.
2. After a configurable timeout (default 10 minutes), the OSDs are marked "out."
3. CRUSH recalculates data placement — data that was on the failed OSDs needs new replicas.
4. Ceph begins "recovery" — copying data from surviving replicas to other OSDs.
5. Cluster goes into HEALTH_WARN during recovery (degraded but no data loss).
6. When recovery completes: HEALTH_OK restored.
7. If the failed node comes back: Ceph backfills it (restores its OSD data from peers).

With 3-way replication: 1 node failure = no data loss, just degraded performance during recovery.

---

## Quick Reference

```
ODF StorageClasses:
  ocs-storagecluster-ceph-rbd      Block (RWO)    → DBs, stateful apps
  ocs-storagecluster-cephfs        File (RWX)     → shared storage, CI/CD
  openshift-storage.noobaa.io      Object (S3)    → OBC provisioner (NooBaa)

Ceph daemons:
  MON = cluster brain, maintains map, requires quorum (3+ odd number)
  OSD = actual data storage, one per disk
  MGR = metrics, modules, dashboard
  MDS = CephFS metadata only
  RGW = S3/Swift HTTP gateway

Loki components:
  Distributor  = receives logs, routes to ingesters
  Ingester     = writes to WAL (PVC), flushes chunks to ODF S3
  Compactor    = merges chunks, enforces retention
  Querier      = executes LogQL queries from Grafana

Log flow:
  Container stdout → Vector (DaemonSet) → Loki Distributor
  → Loki Ingester → ODF S3 (RGW) → Querier → Grafana

ObjectBucketClaim creates:
  ConfigMap: BUCKET_HOST, BUCKET_PORT, BUCKET_NAME, BUCKET_REGION
  Secret:    AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

Key commands:
  oc get storagecluster -n openshift-storage       → ODF health
  oc get lokistack -n openshift-logging            → Loki health
  oc exec <tools-pod> -- ceph status               → full Ceph status
  oc get objectbucketclaim -A                      → all S3 buckets
  oc get pods -n openshift-logging | grep vector   → log collectors
```
