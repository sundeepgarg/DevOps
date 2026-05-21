# Red Hat OpenShift OCP 4.x / ARO Interview Guide

**Target Role:** Senior/Principal Platform Engineer / MLOps Engineer  
**Background:** 8 years OpenShift (OCP 3.x → 4.x), ARO at Voya India, large-scale at IBM (aviation)

---

## 1. OCP 4.x Architecture

### How OCP 4.x Differs From OCP 3.x

OCP 4.x is built entirely on Kubernetes Operators. Every component of the platform is self-managing.

```
OCP 4.x Control Plane
├── Cluster Version Operator (CVO)        — orchestrates cluster upgrades
├── Machine Config Operator (MCO)         — manages node OS config via MachineConfig
├── Cluster Network Operator (CNO)        — deploys and manages OVN-Kubernetes
├── Cluster Storage Operator              — manages storage backends
├── Openshift API Server                  — extends k8s API with OCP resources
└── etcd (3-node HA)                      — stores all cluster state

Worker/Infrastructure Nodes
├── MachineConfig Daemon (per node)       — applies MachineConfigs, reboots when needed
├── CRI-O container runtime               — OCP default (not Docker)
└── kubelet + kube-proxy
```

**Infrastructure nodes**: dedicated nodes for platform workloads (router, registry, monitoring).
Assign via `node-role.kubernetes.io/infra: ""` label + MachineSets.
Keeps platform workloads off worker nodes and avoids extra OpenShift entitlement cost for platform pods.

### Cluster Version Operator (CVO)
The CVO is the brains of OCP upgrades. It:
1. Reads the `ClusterVersion` CR for the desired channel + version
2. Downloads the release image from `quay.io/openshift-release-dev`
3. Applies manifests from the release image to update all cluster operators
4. Tracks operator status via `ClusterOperator` CRs

```bash
# Current cluster version and upgrade availability
oc get clusterversion
oc adm upgrade                          # Show available updates

# Force a specific version upgrade
oc adm upgrade --to=4.14.5

# Check operator health before/after upgrade
oc get co                               # All ClusterOperators
oc get co | grep -v "True.*False.*False"  # Show degraded operators
```

---

## 2. ARO (Azure Red Hat OpenShift)

### ARO vs Self-Managed OCP

| Aspect | ARO | Self-Managed OCP |
|--------|-----|-----------------|
| Control plane management | Red Hat + Microsoft SRE | Your team |
| Upgrades | Managed (auto or manual via portal) | `oc adm upgrade` |
| etcd backups | Managed automatically | You must schedule `oc adm etcd-backup` |
| SLA | 99.95% uptime SLA | Your responsibility |
| Cost | Per-node + Red Hat subscription included | BYOL (Bring Your Own License) |
| RBAC | Azure AD integration via OAuth | Configure Identity Provider |
| Networking | VNet injection — you own the VNet | IPI/UPI networking |
| Shared responsibility | Microsoft/RH own masters; you own workers + workloads | You own everything |

### ARO-Specific Day 2 Operations

```bash
# ARO cluster: authenticate via Azure CLI + kubeconfig
az aro get-credentials --resource-group myRG --name myARO --overwrite-existing

# ARO update channel management (via Azure Portal or CLI)
az aro update --resource-group myRG --name myARO --worker-count 5

# Check ARO operator status
oc get co -A
```

**Key ARO design decisions at Voya:**
- VNet injected into spoke VNet; hub VNet for shared services (DNS, Firewall)
- Azure AD groups mapped to OCP groups via OAuth Identity Provider
- ARO private cluster: API server not public — requires VPN or ExpressRoute for `oc` access

---

## 3. Operator Framework

### OLM (Operator Lifecycle Manager) Components

```
OperatorHub (catalog source)
    ↓
Subscription (subscribe to operator channel)
    ↓
InstallPlan (approved automatically or manually)
    ↓
ClusterServiceVersion (CSV — the operator itself)
    ↓
Operator Pod running in cluster
```

```yaml
# Subscribe to an operator
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: v24.3
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic   # or Manual for production
```

```bash
# Check operator install status
oc get subscription -A
oc get csv -n nvidia-gpu-operator          # ClusterServiceVersion
oc get installplan -n nvidia-gpu-operator  # Pending = needs manual approval
oc patch installplan <name> --type merge -p '{"spec":{"approved":true}}'
```

**Production pattern**: use `installPlanApproval: Manual` in production namespaces.
An automated pipeline checks for new InstallPlans, runs tests, then approves.
Prevents operators auto-updating and breaking workloads.

---

## 4. Security Context Constraints (SCCs)

### SCCs vs Kubernetes Pod Security Admission

| Feature | SCCs (OpenShift) | PSA (Kubernetes) |
|---------|-----------------|-----------------|
| Granularity | Per service account | Per namespace (label) |
| Volume types | Controlled | Controlled |
| Capabilities | Can allow specific caps | Baseline/Restricted/Privileged |
| RunAsUser | `MustRunAsRange` (UID from namespace range) | Numeric UID |
| Custom policies | Full custom SCCs | No — only 3 built-in levels |
| SELinux | Fine-grained control | Limited |

OCP 4.11+ ships both SCCs and PSA. PSA is enforced at admission; SCCs are evaluated by the SCC admission plugin and are more powerful.

### Common SCCs and When to Use Them

```bash
oc get scc                          # List all SCCs
oc describe scc restricted-v2      # Default for all pods in OCP 4.11+
oc describe scc anyuid             # Run as any UID (needed for some third-party images)
oc describe scc privileged         # Full host access (avoid — only for node-level agents)

# Grant a service account an SCC
oc adm policy add-scc-to-user anyuid -z my-service-account -n my-namespace

# Check which SCC a running pod uses
oc get pod my-pod -o jsonpath='{.metadata.annotations.openshift\.io/scc}'
```

### Custom SCC Example (Falcon Sensor)

```yaml
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: falcon-node-sensor
allowPrivileged: false
allowPrivilegeEscalation: false
allowedCapabilities:
  - SYS_PTRACE          # Needed for eBPF-based sensor
requiredDropCapabilities:
  - ALL
runAsUser:
  type: MustRunAsNonRoot
seLinuxContext:
  type: MustRunAs
  seLinuxOptions:
    type: spc_t           # Falcon requires spc_t SELinux type
volumes:
  - configMap
  - secret
  - hostPath             # Access /proc for process monitoring
```

---

## 5. OpenShift Networking

### OVN-Kubernetes (Default CNI in OCP 4.12+)

```
OVN-Kubernetes architecture:
  ovn-northd (control plane)  →  OVN North DB  →  OVN South DB
                                                       ↓
  ovs-vswitchd (per node)     ←  ovn-controller (per node)
```

Key features over OpenShift SDN (legacy):
- True NetworkPolicy enforcement at the OVS level (not iptables)
- EgressIP: stable outbound IP per namespace (important for firewall rules)
- EgressFirewall: block/allow egress by CIDR or DNS name
- Multi-homing via Multus (secondary NICs for storage or ML traffic)

```bash
# Check CNI plugin
oc get network.config cluster -o jsonpath='{.spec.networkType}'

# EgressIP for namespace — give namespace a stable outbound IP
oc label namespace ml-platform k8s.ovn.org/egress-assignable=""
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: ml-platform-egress
spec:
  egressIPs:
    - 10.0.1.50
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: ml-platform
EOF
```

### Routes vs Ingress

| Feature | OpenShift Route | Kubernetes Ingress |
|---------|----------------|--------------------|
| TLS termination | Edge / Passthrough / Re-encrypt | Edge (via cert-manager + annotations) |
| Certificate management | Route-level or wildcard on router | cert-manager ClusterIssuer |
| Sharding | Router shards via label selector | IngressClass |
| Sticky sessions | Annotation-based | Annotation-based |
| WebSocket | Supported | Depends on Ingress controller |
| Status tracking | Route `status.ingress` | Ingress `status.loadBalancer` |

```yaml
# Passthrough route (TLS handled by the backend — for mTLS with Istio)
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: model-serving
spec:
  host: model.apps.cluster.example.com
  to:
    kind: Service
    name: kserve-gateway
  tls:
    termination: passthrough
```

---

## 6. MachineConfig and MachineConfigPool

### How MachineConfig Works

```
MachineConfig (desired OS state)
    ↓ rendered by MCO
MachineConfigPool (group of nodes)
    ↓
MachineConfigDaemon (per node daemon)
    ↓
Node reboots with new config applied
```

**Key use cases:**
- Add custom sysctl settings (e.g., `vm.max_map_count` for Elasticsearch/OpenSearch)
- Deploy custom CA certificates to nodes
- Configure chrony NTP
- Tune kernel parameters for GPU workloads

```yaml
# Add sysctl for Elasticsearch on all worker nodes
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-sysctl
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/sysctl.d/99-elasticsearch.conf
          mode: 0644
          contents:
            source: "data:,vm.max_map_count%3D262144%0A"
```

```bash
# Check MachineConfigPool status
oc get mcp
# NAME     CONFIG                  UPDATED   UPDATING   DEGRADED
# master   rendered-master-abc     True      False      False
# worker   rendered-worker-xyz     False     True       False  ← rolling update in progress

# Pause MCP before an upgrade to prevent unexpected node reboots
oc patch mcp worker --type merge -p '{"spec":{"paused":true}}'
# Resume after upgrade is stable
oc patch mcp worker --type merge -p '{"spec":{"paused":false}}'
```

---

## 7. OpenShift Data Foundation (ODF)

### What ODF Provides

ODF = Rook-Ceph running as an OCP Operator. Provides:
- **Block (RBD)**: `ocs-storagecluster-ceph-rbd` — RWO, for databases, stateful apps
- **File (CephFS)**: `ocs-storagecluster-cephfs` — **RWX**, for shared ML model artifacts, notebooks
- **Object (S3-compatible NooBaa)**: `ocs-storagecluster-ceph-rgw` — for MLflow artifacts, model registry

```bash
# Check ODF health
oc get storagecluster -n openshift-storage
oc get cephcluster -n openshift-storage
# HEALTH_OK = all Ceph OSDs healthy

# Common storage classes
oc get sc
# ocs-storagecluster-ceph-rbd         RWO  (databases)
# ocs-storagecluster-cephfs            RWX  (shared notebooks, model artifacts)
# ocs-storagecluster-ceph-rgw          S3   (object storage via Route)
```

### ODF for ML Workloads at Voya

```yaml
# PVC for shared model artifacts — multiple KServe pods can read simultaneously
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-artifacts-pvc
  namespace: ml-platform
spec:
  accessModes:
    - ReadWriteMany           # RWX — CephFS
  storageClassName: ocs-storagecluster-cephfs
  resources:
    requests:
      storage: 100Gi
```

**Interview talking point**: ODF-backed RWX storage solved the model artifact sharing problem — multiple
inference pods (KServe) can read from the same PVC without copying models to each pod. This
reduced model load time from 8 minutes (per pod, from object storage) to 30 seconds (shared PVC).

---

## 8. Cluster Upgrades

### OCP Upgrade Channels

| Channel | Stability | Use Case |
|---------|-----------|----------|
| `candidate-4.14` | Pre-GA, may have bugs | Dev/test only |
| `fast-4.14` | GA + early patches | Non-critical environments |
| `stable-4.14` | Fully vetted patches | Production |
| `eus-4.14` | Extended Update Support | Long-term stable (even versions only) |

### Upgrade Sequence

```bash
# 1. Check current channel and available updates
oc get clusterversion
oc adm upgrade

# 2. Switch to stable channel (if not already)
oc patch clusterversion version --type merge \
  -p '{"spec":{"channel":"stable-4.14"}}'

# 3. Review upgrade graph — ensure no blocked paths
oc adm upgrade --to-latest=true  # dry-run shows the target

# 4. (Optional) Pause worker MCP to control when nodes reboot
oc patch mcp worker --type merge -p '{"spec":{"paused":true}}'

# 5. Trigger upgrade
oc adm upgrade --to=4.14.5

# 6. Monitor upgrade progress
watch oc get co         # All ClusterOperators must reach True/False/False
watch oc get nodes      # Nodes will cycle through SchedulingDisabled as they reboot

# 7. Resume worker MCP after control plane is healthy
oc patch mcp worker --type merge -p '{"spec":{"paused":false}}'

# 8. Verify
oc get clusterversion   # VERSION should show 4.14.5, PROGRESSING=False
```

---

## 9. OpenShift RBAC

### OCP-Specific RBAC Concepts

```bash
# OCP Projects = Kubernetes Namespaces + annotations + network isolation
oc new-project ml-platform --description="ML inference platform"

# Add a user to a project with edit role
oc adm policy add-role-to-user edit sundeep -n ml-platform

# Grant cluster-admin to a group (use sparingly)
oc adm policy add-cluster-role-to-group cluster-admin platform-admins

# Check all roles a user has
oc get rolebinding -A -o json | jq '.items[] | select(.subjects[]?.name=="sundeep")'

# OCP-specific roles
oc describe clusterrole view            # Read-only on most resources
oc describe clusterrole edit            # Create/update/delete workloads
oc describe clusterrole admin           # Full namespace control + RBAC
oc describe clusterrole cluster-reader  # Read-only cluster-wide
```

### Service Account Tokens (OCP 4.11+ Bound Tokens)

OCP 4.11+ uses time-bound service account tokens (not long-lived secrets).

```bash
# Create a dedicated service account for CI/CD (not cluster-admin)
oc create sa github-actions -n ml-platform
oc adm policy add-role-to-user edit -z github-actions -n ml-platform

# Get a short-lived token for CI/CD (expires in 1 hour)
oc create token github-actions -n ml-platform --duration=3600s
```

---

## 10. ImageStreams and Internal Registry

### Why ImageStreams?

ImageStreams provide a layer of indirection between a tag name and a real image SHA.
When the underlying image changes, an ImageStream trigger can automatically redeploy.

```bash
# Import an external image into the internal registry
oc import-image my-app:latest \
  --from=quay.io/myorg/my-app:latest \
  --scheduled=true \          # Re-check quay.io every 15 minutes
  --confirm -n ml-platform

# Trigger a new Deployment when the ImageStream tag changes
# (Add this annotation to Deployment)
kubectl annotate deployment my-app \
  image.openshift.io/triggers='[{"from":{"kind":"ImageStreamTag","name":"my-app:latest"},"fieldPath":"spec.template.spec.containers[0].image"}]'
```

**Internal Registry** (`image-registry.openshift-image-registry.svc:5000`):
- Every OCP cluster has an internal registry backed by ODF or blob storage
- Used for BuildConfig output images, CI/CD pipelines without external registry
- Exposed externally via Route for `docker push` from CI

---

## 11. Scenario-Based Interview Questions

**Q: A pod in your OpenShift cluster is stuck in `CreateContainerConfigError`. How do you debug it?**

1. `oc describe pod <pod-name>` — look for the exact error message in Events section.
2. Common cause: SCC violation. Look for: "unable to validate against any security context constraint."
3. Check what SCC the pod needs:
   ```bash
   oc get pod <pod-name> -o yaml | grep -A5 securityContext
   ```
4. Check what SCCs the pod's service account can use:
   ```bash
   oc adm policy who-can use scc anyuid | grep <service-account>
   ```
5. Fix: Grant the service account the required SCC:
   ```bash
   oc adm policy add-scc-to-user anyuid -z <sa-name> -n <namespace>
   ```
6. If using a third-party Helm chart that runs as root: override the `securityContext` in values.yaml to use `runAsUser: 1000`, `runAsNonRoot: true` — this avoids needing `anyuid`.

**Q: You need to upgrade your ARO cluster from 4.13 to 4.14. Walk through your process.**

1. Read the 4.14 release notes for breaking changes and deprecated APIs (e.g., check for removed API versions).
2. Run `oc get apirequestcounts` to identify any deprecated APIs still in use:
   ```bash
   oc get apirequestcount -o json | jq '.items[] | select(.status.removedInRelease != null) | .metadata.name'
   ```
3. Check all ClusterOperators are healthy: `oc get co | grep -v "True.*False.*False"`.
4. Verify etcd cluster health: `oc get etcd -o json | jq '.items[].status.conditions'`.
5. In ARO: use the Azure Portal → ARO cluster → Update → select 4.14.x.
6. Monitor via `watch oc get co` and `watch oc get nodes`.
7. Worker nodes reboot one at a time (rolling); verify each node becomes Ready before next.
8. Post-upgrade: run your smoke test suite against all critical services.

**Q: A MachineConfig you applied is causing nodes to fail to boot. How do you recover?**

1. Identify the failing MachineConfigPool: `oc get mcp worker` — look for `DEGRADED=True`.
2. `oc describe machineconfigpool worker` — shows which node is failing and the error.
3. SSH to the failing node (via `oc debug node/<node-name>`):
   ```bash
   oc debug node/worker-0
   chroot /host
   journalctl -xeu machine-config-daemon
   ```
4. If the Ignition config is malformed, the MCDaemon won't apply it. The node stays on the previous config.
5. Fix: Delete the bad MachineConfig. MCO will re-render the pool without it and reboot the node to the previous good config.
6. Prevention: Test MachineConfigs on a single node pool first using a dedicated `MachineConfigPool` with one test node before rolling out to all workers.

**Q: How did you configure the multi-cluster east-west gateway with Maistra at Voya?**

At Voya we had two OpenShift clusters (ARO + on-prem OCP) needing to communicate with end-to-end mTLS.
The challenge: Kubernetes Services can't route across clusters without overlay networking.

Solution with Maistra Service Mesh 3:
1. Deployed an east-west `IngressGateway` in each cluster dedicated to cross-cluster traffic (not the public-facing gateway).
2. The gateway listens on port 15443 with `AUTO_PASSTHROUGH` mode — it routes based on SNI without decrypting TLS. This preserves end-to-end mTLS.
3. In Cluster A, created a `ServiceEntry` pointing to Cluster B's east-west gateway IP for the remote services.
4. Configured a `DestinationRule` to use `mTLS` mode for all traffic to the remote service.
5. The SPIFFE identity (`spiffe://cluster-b.local/ns/ml-platform/sa/inference-service`) in the client cert identifies the source, and the remote cluster's Citadel validates it against its trust bundle.
6. For the trust bundle: exported Cluster A's root CA cert and added it to Cluster B's `PeerAuthentication` trusted CAs (and vice versa). This is the key config that makes cross-cluster mTLS work.

Result: ML inference requests from frontend services in Cluster A routed to backend models in Cluster B with zero-trust mTLS, no plaintext at any hop.

**Q: How do you choose between CephFS and Ceph RBD storage classes for ML workloads on ODF?**

Mental model:
- **CephFS (RWX)**: multiple pods can mount the same PVC simultaneously. Use for:
  - Shared model artifact storage (multiple KServe inference pods reading the same model)
  - Jupyter notebook home directories (user reads/writes from multiple pods)
  - Log aggregation PVCs
- **Ceph RBD (RWO)**: single pod mounts, higher IOPS performance. Use for:
  - PostgreSQL, MongoDB, MySQL data volumes
  - MLflow backend database
  - Single-writer checkpointing during model training
  - KServe model storage *if* you pre-load the model to a single init-container (not multi-pod)

Performance: RBD has lower latency than CephFS (no POSIX filesystem overhead). For a training job that writes checkpoints, use RBD. For inference pods that only read the model at startup, use CephFS with ReadWriteMany.

At Voya: CephFS for model artifacts (shared by 3-5 inference replicas), RBD for MLflow's PostgreSQL backend.

**Q: A developer says `oc login` works but `oc get pods` returns "Forbidden". What do you check?**

1. Check what project/namespace they're in: `oc project` — they may be in the wrong namespace.
2. Check their roles in the target namespace:
   ```bash
   oc get rolebinding -n <namespace> | grep <username>
   oc adm policy who-can get pods -n <namespace>
   ```
3. Check if they have a ClusterRole (cluster-reader, view): `oc get clusterrolebinding | grep <username>`.
4. Verify they're using the right Identity Provider — ARO with Azure AD sometimes creates duplicate users with different IDs (email vs UPN format). Check: `oc get user`.
5. If the user exists but has no bindings: add the minimum required role:
   ```bash
   oc adm policy add-role-to-user view <username> -n <namespace>
   ```
6. Check group membership — if access is managed via groups, ensure the user is in the right Azure AD group synced to OCP.

**Q: How do you safely drain a node in OpenShift before maintenance?**

```bash
# 1. Mark node unschedulable (prevents new pods from landing)
oc adm cordon worker-2

# 2. Drain: evict all pods (respects PodDisruptionBudgets)
oc adm drain worker-2 \
  --delete-emptydir-data \      # Remove emptyDir volumes (non-persistent data)
  --ignore-daemonsets \          # Don't try to evict DaemonSet pods (they can't move)
  --timeout=300s

# 3. Perform maintenance (patch OS, replace hardware)

# 4. Uncordon: make node schedulable again
oc adm uncordon worker-2
```

Gotchas:
- If PodDisruptionBudget blocks drain (e.g., `maxUnavailable=0`): temporarily patch PDB or coordinate with app team.
- DaemonSet pods (Falcon sensor, OVN agent, monitoring) are skipped automatically with `--ignore-daemonsets`.
- Platform Operator pods (on infrastructure nodes) need their node drained carefully to avoid control plane disruption.

**Q: How do you deploy the NVIDIA GPU Operator on OpenShift?**

```bash
# 1. Create the namespace
oc create ns nvidia-gpu-operator

# 2. Label GPU nodes
oc label node gpu-worker-0 feature.node.kubernetes.io/pci-10de.present=true

# 3. Install Node Feature Discovery (NFD) first — detects hardware
# Subscribe to nfd-operator via OperatorHub

# 4. Install GPU Operator via OperatorHub (certified-operators catalog)
# Subscribe to gpu-operator-certified

# 5. Create the ClusterPolicy CR to deploy all GPU components
cat <<EOF | oc apply -f -
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  driver:
    enabled: true        # Install NVIDIA driver as container
  toolkit:
    enabled: true        # nvidia-container-toolkit
  devicePlugin:
    enabled: true        # Exposes nvidia.com/gpu resource
  dcgmExporter:
    enabled: true        # GPU metrics to Prometheus
  mig:
    strategy: single     # For A100 MIG: use 'mixed' for multiple MIG profiles
EOF
```

After 5-10 minutes:
```bash
oc get pods -n nvidia-gpu-operator      # All should be Running
oc describe node gpu-worker-0 | grep nvidia.com/gpu  # Shows available GPUs
```

**Q: A build in OpenShift is failing with "ImagePullBackOff" even though the image exists. How do you debug?**

1. `oc describe pod <build-pod>` — check the exact pull error.
2. Common causes and fixes:
   - **Registry auth**: ImagePullSecret not added to the service account:
     ```bash
     oc secrets link default quay-pull-secret --for=pull -n myproject
     ```
   - **Wrong registry hostname**: corporate proxy may block `quay.io` but allow the internal mirror. Check `oc get imagecontentsourcepolicy` for any image mirrors.
   - **ARO private cluster**: ACR (Azure Container Registry) must have private endpoint in the same VNet, or the ARO VNet must have NSG rules allowing outbound to ACR.
   - **Rate limiting**: Docker Hub rate limits — authenticate even for public images. Use `oc create secret docker-registry`.
3. Test manually: `oc debug node/<node> -- chroot /host crictl pull <image>` — see the exact pull error from the node's perspective.

**Q: How do you migrate Jenkins pipelines to GitHub Actions with ARC on OpenShift? (Voya experience)**

At Voya we migrated 3,000+ Jenkins jobs across 250+ applications to GitHub Actions with ARC (Actions Runner Controller) running on OpenShift ARO.

Architecture:
1. Deployed ARC's `controller-manager` and `runner-sets` as deployments in OpenShift.
2. ARC runners run as pods in a dedicated namespace with ephemeral lifecycle (pod-per-job, deleted after run).
3. Assigned ARC runner pods to infrastructure nodes (not worker nodes) to isolate CI workloads.

Key OCP-specific configurations:
- ARC runner pods need `anyuid` SCC for some build operations (or a custom SCC).
- Used PodDisruptionBudget on ARC controller to prevent accidental eviction during node drains.
- Shared PVC (CephFS RWX) for Maven/npm/pip cache mounted by all runner pods — improved build times by 40%.
- ArgoCD deployed ARC configurations; GitHub repo is single source of truth.

Migration approach:
1. Ran Jenkins and GitHub Actions in parallel for 4 weeks per team.
2. Required all pipelines to define reusable workflow templates from a shared `platform-workflows` repo.
3. Used a custom Python audit script (`oc get jobs -A -o json` + GitHub API) to verify parity — reduced audit from 10 hours to 10 minutes via automation.

**Q: What is the difference between `oc delete` and `oc adm remove` for project cleanup?**

- `oc delete project myproject` — deletes the Project CR. OCP's project controller then deletes all resources inside (pods, services, routes, PVCs, etc.) asynchronously. Takes 30 seconds to several minutes if there are many resources or finalizers.
- `oc adm` commands are administrative and bypass some checks: `oc adm top nodes` (requires cluster-reader), `oc adm drain`, `oc adm policy` — these are operations that modify cluster state beyond a single namespace.
- When a project is stuck in `Terminating`: check for finalizers on resources inside it. Common culprit: `ServiceMeshMember` or `ResourceQuota` resources that have finalizers. Use `oc get all -n myproject` and patch finalizers:
  ```bash
  oc patch namespace myproject -p '{"spec":{"finalizers":[]}}' --type merge
  ```
