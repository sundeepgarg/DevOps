# Azure System Design Interview Guide

**Target Role:** Principal Platform Engineer / Azure Solutions Architect / SRE Lead
**Focus:** Burst traffic, zero-downtime deployments, cross-cluster data sync, HA, DR

---

## How to Approach Azure System Design

**Same RADIO framework as AWS — ask first:**
- What is the scale? (requests/sec, users, data volume)
- Availability requirement? (99.9%, 99.95%, 99.99%)
- Data residency requirements? (GDPR, India DPDP Act)
- Existing Azure footprint? (are they using AKS, or App Service?)
- Budget constraints? (AKS vs App Service — significant cost difference)

**Azure vs AWS mental model:**

| AWS | Azure Equivalent |
|---|---|
| EC2 + ASG | Virtual Machine Scale Sets (VMSS) |
| ECS Fargate | Azure Container Apps / ACI |
| EKS | AKS (Azure Kubernetes Service) |
| Lambda | Azure Functions |
| ALB | Application Gateway |
| NLB | Azure Load Balancer (Standard) |
| CloudFront | Azure CDN / Azure Front Door |
| Route 53 | Azure DNS + Traffic Manager / Front Door |
| SQS | Azure Service Bus (Queue) |
| SNS | Azure Service Bus (Topic) |
| EventBridge | Azure Event Grid |
| Kinesis | Azure Event Hubs |
| RDS Aurora | Azure SQL Database / Azure Database for PostgreSQL Flexible |
| DynamoDB | Azure Cosmos DB |
| ElastiCache | Azure Cache for Redis |
| S3 | Azure Blob Storage |
| EBS | Azure Managed Disks |
| EFS | Azure Files |
| Secrets Manager | Azure Key Vault |
| CloudWatch | Azure Monitor + Log Analytics |
| X-Ray | Azure Application Insights |
| CodePipeline | Azure DevOps Pipelines |

---

## Design 1: Handle Burst Traffic on Azure

### Scenario
"Design a system on Azure that normally handles 2,000 RPS but must handle 100,000 RPS during a product launch. Response time < 200ms p99."

### Architecture

```
                   ┌──────────────────────┐
Users ──HTTPS──▶   │   Azure Front Door   │  Global CDN + WAF + load balancing
                   │   (Premium tier)     │  Anycast routing to nearest PoP
                   └──────────┬───────────┘
                              │ Cache miss
                   ┌──────────▼───────────┐
                   │  Application Gateway │  Layer 7 LB within region
                   │  (WAF v2)            │  Path-based routing, SSL offload
                   └────┬─────────────────┘
                        │
           ┌────────────▼────────────┐
           │  AKS (API pods)         │  Kubernetes — KEDA auto-scaling
           │  HPA + KEDA             │  Scale on queue depth or RPS
           └────────────┬────────────┘
                        │
           ┌────────────▼────────────┐
           │  Azure Cache for Redis  │  Hot data, sessions, rate limiting
           │  (Premium, zone redund) │  ~0.2ms reads, cluster mode
           └────────────┬────────────┘
                        │ Cache miss
           ┌────────────▼────────────┐
           │  Azure SQL DB           │  General Purpose tier, read replicas
           │  (Business Critical)    │  99.99% SLA, zone redundant
           └─────────────────────────┘

Async burst buffer:
API ──▶ Service Bus Queue ──▶ Azure Functions (consumption plan) ──▶ Cosmos DB
```

### Key Azure-Specific Decisions

**Azure Front Door (Premium):**
- Global anycast routing — user hits nearest of 100+ PoPs worldwide
- Built-in WAF (OWASP rules), DDoS protection
- Origin health probes — routes away from unhealthy origins automatically
- CDN caching at edge: static assets, API responses with appropriate Cache-Control headers
- Private Link to backend — no public IP on AKS/App Service required

```json
// Front Door origin group with health probes
{
  "originGroup": {
    "healthProbeSettings": {
      "probePath": "/health",
      "probeProtocol": "Https",
      "probeIntervalInSeconds": 5
    },
    "loadBalancingSettings": {
      "sampleSize": 4,
      "successfulSamplesRequired": 3
    }
  }
}
```

**KEDA (Kubernetes Event-Driven Autoscaling) on AKS:**

KEDA extends HPA to scale on external event sources — queue depth, HTTP traffic, cron schedule.

```yaml
# KEDA ScaledObject — scale on Service Bus queue depth
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: api-scaler
spec:
  scaleTargetRef:
    name: api-deployment
  minReplicaCount: 3
  maxReplicaCount: 100
  triggers:
  - type: azure-servicebus
    metadata:
      queueName: order-queue
      namespace: my-servicebus
      messageCount: "50"          # 1 replica per 50 messages
  - type: cpu
    metricType: Utilization
    metadata:
      value: "70"                 # also scale on CPU
```

**VMSS (Virtual Machine Scale Sets) — alternative to AKS:**

When you need VMs instead of containers:
```
VMSS Configuration:
  - Scale-out trigger: CPU > 70% for 5 min → add 2 VMs
  - Scale-in trigger: CPU < 30% for 15 min → remove 1 VM
  - Minimum: 2 instances, Maximum: 50 instances
  - Custom autoscale with scheduled profiles (pre-scale for known events)
  - Spot instances (interruptible) for batch workloads — 60-80% cheaper
```

**Azure Service Bus for burst buffering:**

```python
# Producer: API accepts request immediately, queues for async processing
from azure.servicebus import ServiceBusClient, ServiceBusMessage

with ServiceBusClient.from_connection_string(conn_str) as client:
    with client.get_queue_sender("orders") as sender:
        msg = ServiceBusMessage(
            json.dumps(order),
            message_id=order['id'],           # idempotency
            session_id=order['userId']        # ordered per user (session-enabled queue)
        )
        sender.send_messages(msg)
        return {"status": "accepted", "orderId": order['id']}  # 202 Accepted
```

---

## Design 2: Zero-Downtime Deployment on Azure

### Scenario
"Design a deployment pipeline for an AKS-hosted API with zero-downtime releases, automatic validation, and instant rollback."

### Strategy A: AKS Rolling Update + ArgoCD

```yaml
# Kubernetes Deployment — zero-downtime rolling update
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 3           # temporarily run 13 pods during update
      maxUnavailable: 0     # never reduce below 10 running pods
  template:
    spec:
      containers:
      - name: api
        image: myregistry.azurecr.io/api:v2.1.0
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
          failureThreshold: 3       # pod never gets traffic until 3 consecutive passes
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 15
        lifecycle:
          preStop:
            exec:
              command: ["sleep", "15"]   # drain connections before SIGTERM
      terminationGracePeriodSeconds: 30
```

**ArgoCD GitOps flow:**
```
Dev pushes to feature branch
  └──▶ PR → merge to main
         └──▶ Azure DevOps Pipeline
                ├── Build image → push to ACR (Azure Container Registry)
                ├── Run unit tests + integration tests
                ├── Update image tag in Helm values.yaml → commit to Git
                └── ArgoCD detects Git change → syncs to AKS
                        └── Rolling update begins
                                └── Prometheus scrapes metrics
                                        └── If error rate spikes → alert
                                                └── ArgoCD rollback: sync to previous Git commit
```

### Strategy B: Azure App Service Deployment Slots (Simplest)

Best for: App Service workloads. Built-in, no extra tooling needed.

```
Production slot (v1.0) ← 100% traffic
Staging slot (v2.0)    ← 0% traffic

Steps:
1. Deploy v2.0 to staging slot (zero impact on production)
2. Run smoke tests against staging slot URL
3. Swap slots (atomic, < 30 seconds):
   - Production slot becomes: v2.0
   - Staging slot becomes: v1.0 (instant rollback available)
4. Monitor for 15 minutes
5. If bad → swap back (v1.0 returns to production in < 30 seconds)
```

```bash
# Azure CLI — deploy to staging, swap to production
az webapp deployment slot create --name my-api --slot staging
az webapp deploy --name my-api --slot staging --src-path app.zip
# Run tests against staging...
az webapp deployment slot swap --name my-api --slot staging --target-slot production
```

**Traffic splitting (canary) with slots:**
```bash
# Route 10% to staging (canary)
az webapp traffic-routing set --name my-api \
  --distribution staging=10
# Monitor, then gradually increase or swap
```

### Strategy C: Blue/Green with Azure Traffic Manager + Front Door

```
Azure Traffic Manager (weighted routing)
    │
    ├──▶ Blue environment (v1) — weight: 90
    │      AKS cluster / App Service / VM
    │
    └──▶ Green environment (v2) — weight: 10
           AKS cluster / App Service / VM

Automated promotion:
1. Deploy to Green
2. Smoke test Green directly via its endpoint
3. Shift 10% via Traffic Manager → watch Application Insights for 20 min
4. If healthy: shift to 50% → 100%
5. Keep Blue warm for 2 hours → drain → decommission
```

### Azure DevOps Pipeline with Gates

```yaml
# azure-pipelines.yml — zero-downtime deployment with quality gates
stages:
- stage: Build
  jobs:
  - job: BuildAndTest
    steps:
    - task: Docker@2
      inputs:
        command: buildAndPush
        containerRegistry: myACRServiceConnection
        repository: my-api
        tags: $(Build.BuildId)

- stage: DeployStaging
  jobs:
  - deployment: DeployToStaging
    environment: staging
    strategy:
      runOnce:
        deploy:
          steps:
          - task: HelmDeploy@0
            inputs:
              namespace: staging
              releaseName: my-api-staging
              overrideValues: image.tag=$(Build.BuildId)

- stage: CanaryPromotion
  jobs:
  - job: SmokeTest
    steps:
    - script: |
        response=$(curl -s -o /dev/null -w "%{http_code}" https://staging.myapi.com/health)
        if [ "$response" != "200" ]; then exit 1; fi
  - job: PromoteCanary
    dependsOn: SmokeTest
    steps:
    - task: AzureCLI@2
      inputs:
        scriptType: bash
        inlineScript: |
          az network front-door routing-rule update \
            --weight-staging 10 --weight-production 90

- stage: DeployProduction
  condition: succeeded()
  jobs:
  - deployment: SwapSlots
    environment:
      name: production
      resourceType: VirtualMachine
    strategy:
      runOnce:
        deploy:
          steps:
          - task: AzureAppServiceManage@0
            inputs:
              action: SwapSlots
              sourceSlot: staging
```

---

## Design 3: Data Sync Across Clusters / Regions

### Scenario
"Design a multi-region Azure architecture where users in West Europe and East US both write, and data must sync in under 5 seconds."

### Architecture

```
East US                                    West Europe
────────────────────────────────────────────────────────────────

Azure Front Door (global routing by latency)
    │ US users                              │ EU users
    ▼                                       ▼
AKS (East US)                          AKS (West Europe)
    │                                       │
    ▼                                       ▼
Azure Cache for Redis                  Azure Cache for Redis
(local — no cross-region sync)         (local — no cross-region sync)
    │                                       │
    ▼                                       ▼
Azure SQL DB                           Azure SQL DB
(Primary — Writer)  ◄══════════════►  (Active Geo-Replica)
                    < 5 sec replication  (can be promoted to writer)
    │                                       │
    ▼                                       ▼
Cosmos DB (East US)  ◄════════════►  Cosmos DB (West Europe)
(multi-region write)  ~1 sec sync    (multi-region write)
    │                                       │
    ▼                                       ▼
Blob Storage (East US) ══════════════▶ Blob Storage (West Europe)
               GRS / Object Replication (async)

Event sync:
Event Hub (East US) ──▶ Kafka MirrorMaker ──▶ Event Hub (West Europe)
                         OR Azure Event Grid cross-region
```

### Service-by-Service Deep Dive

#### Azure SQL Database — Active Geo-Replication

```
Active Geo-Replication:
  - 4 readable secondaries across different regions
  - Asynchronous replication (typically < 5 seconds lag)
  - Failover: manual (for planned) or auto with Failover Groups
  - RPO: 5 seconds    RTO: 30 seconds (with Auto-Failover Group)
```

```bash
# Create geo-replica
az sql db replica create \
  --name my-database \
  --server primary-server \
  --resource-group primary-rg \
  --partner-server secondary-server \
  --partner-resource-group secondary-rg

# Create Auto-Failover Group (automatic failover)
az sql failover-group create \
  --name my-failover-group \
  --server primary-server \
  --partner-server secondary-server \
  --failover-policy Automatic \
  --grace-period 1    # hours before automatic failover
```

**Limitation:** Single writer region (like Aurora Global DB). For multi-region writes → Cosmos DB.

#### Azure Cosmos DB — True Multi-Region Active-Active

Best for: globally distributed write workloads with eventual consistency acceptable.

```
Consistency levels (choose based on requirements):
  Strong           → linearizable reads, highest latency
  Bounded Staleness → reads lag writes by K versions or T seconds
  Session          → consistent reads within a session (default for most apps)
  Consistent Prefix → no out-of-order reads
  Eventual         → best performance, lowest latency, may read stale

For multi-region active-active: use Session consistency or Bounded Staleness
```

```python
# Cosmos DB — write to local region, reads from local region
from azure.cosmos import CosmosClient

client = CosmosClient(
    url="https://my-cosmos.documents.azure.com:443/",
    credential=credential,
    preferred_locations=["West Europe", "East US"]  # prefer local region
)

container = client.get_database_client("orders").get_container_client("items")

# Write → goes to local region, auto-replicated globally
container.upsert_item({
    "id": order_id,
    "userId": user_id,
    "amount": 99.99,
    "_ts": int(time.time())    # used for conflict resolution (last-writer-wins default)
})
```

**Custom conflict resolution in Cosmos DB:**
```javascript
// Stored procedure for merge-based conflict resolution
function conflictResolution(incomingItem, existingItem) {
    // Example: merge shopping cart items instead of overwrite
    if (existingItem) {
        incomingItem.cartItems = mergeArrays(
            incomingItem.cartItems,
            existingItem.cartItems
        );
    }
    return incomingItem;
}
```

#### Azure Event Hubs — Cross-Region Event Streaming

```
Event Hub Geo-Redundancy (Disaster Recovery pairing):
  Primary namespace ──metadata sync──▶ Secondary namespace
  Producers write to primary
  On failover: alias DNS redirects to secondary (no client code change)

Event Hub Geo-Replication (Preview / new feature):
  Active replication of events across regions
  Secondary can be used for reads during normal operation
```

```python
# Producers always use the alias (not region-specific endpoint)
producer = EventHubProducerClient(
    fully_qualified_namespace="my-eventhub-alias.servicebus.windows.net",
    eventhub_name="orders",
    credential=credential
)
```

#### Azure Blob Storage — Cross-Region Replication

```
Options:
  GRS (Geo-Redundant Storage): async replication to paired region, ~15 min lag
    - Read from secondary: enable RA-GRS (Read-Access GRS)
    - Microsoft-managed failover
  
  Object Replication: copy specific containers to any region
    - Configurable filter rules (replicate only specific prefix)
    - Good for model artefacts, media files

  GZRS: Zone-redundant in primary + GRS — highest availability (99.99999%)
```

---

## Design 4: AKS High Availability Architecture

### Scenario
"Design a production AKS cluster with 99.99% availability."

### Architecture

```
                         Azure Front Door
                               │
                         Application Gateway
                         (zone-redundant)
                               │
              ┌────────────────┼────────────────┐
              │                │                │
          Zone 1           Zone 2           Zone 3
          ┌───────┐        ┌───────┐        ┌───────┐
          │ AKS   │        │ AKS   │        │ AKS   │
          │ Node  │        │ Node  │        │ Node  │
          │ Pool  │        │ Pool  │        │ Pool  │
          └───────┘        └───────┘        └───────┘
              │                │                │
              └────────────────┼────────────────┘
                               │
                    ┌──────────┼──────────┐
                    │          │          │
              Redis Zone1  Redis Zone2  Redis Zone3
              (Premium cluster, zone redundant)

              Azure SQL Business Critical
              (3 replicas, one per zone, automatic HA)

              Azure Key Vault (zone redundant)
              Azure Container Registry (geo-replicated)
```

**AKS System Node Pool (control plane nodes):**
```bash
az aks create \
  --resource-group my-rg \
  --name my-aks \
  --node-count 3 \
  --zones 1 2 3 \                    # spread across 3 availability zones
  --enable-cluster-autoscaler \
  --min-count 3 \
  --max-count 10 \
  --tier Standard \                  # AKS Standard tier = 99.95% SLA on API server
  --network-plugin azure \           # Azure CNI for pod network
  --network-policy calico \          # network policies
  --enable-oidc-issuer \             # workload identity
  --enable-workload-identity
```

**Pod Topology Spread Constraints:**
```yaml
# Spread pods across zones and nodes
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule    # hard requirement
    labelSelector:
      matchLabels:
        app: api
  - maxSkew: 2
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway   # soft preference
    labelSelector:
      matchLabels:
        app: api
```

### Cluster Autoscaler vs KEDA vs HPA — When to Use Each

| | HPA | KEDA | Cluster Autoscaler |
|---|---|---|---|
| What scales | Pod replicas | Pod replicas | Node count |
| Triggers | CPU / memory | Any external metric | Pending pods |
| Use case | CPU-bound workloads | Event-driven (queue depth) | Node-level scaling |
| Speed | ~1-2 min | ~30 sec | ~5-10 min |

**Correct order:** HPA/KEDA scales pods → if no capacity, Cluster Autoscaler adds nodes → new pods schedule on new nodes.

---

## Design 5: Azure Disaster Recovery

### DR Tiers on Azure

| Tier | Azure Services | RTO | RPO |
|---|---|---|---|
| **Backup only** | Azure Backup, MARS agent | Hours | Hours |
| **Cold standby** | ARM templates, runbooks | 1-2 hours | Minutes |
| **Warm standby** | Geo-replica DB, stopped VMSS | 15-30 min | Seconds |
| **Hot standby** | Active-Active Front Door + Cosmos DB | < 1 min | Near-zero |

### DR Runbook — Regional Failover

```bash
#!/bin/bash
# Failover from East US to West Europe

echo "Step 1: Promote Azure SQL geo-replica to primary"
az sql failover-group set-primary \
  --name my-failover-group \
  --server secondary-server \
  --resource-group secondary-rg

echo "Step 2: Scale up West Europe AKS (if using warm standby)"
az aks scale \
  --resource-group secondary-rg \
  --name secondary-aks \
  --node-count 10

echo "Step 3: Update Front Door origin weights"
az network front-door origin update \
  --front-door-name my-frontdoor \
  --origin-group production \
  --name eastus-origin \
  --weight 0

az network front-door origin update \
  --front-door-name my-frontdoor \
  --origin-group production \
  --name westeurope-origin \
  --weight 1000

echo "Step 4: Verify health"
curl https://my-api.azurefd.net/health
```

---

## Common Interview Questions

### Q: Azure Traffic Manager vs Azure Front Door vs Application Gateway — when to use each?

| Service | Layer | Scope | Use case |
|---|---|---|---|
| **Traffic Manager** | DNS (L4) | Global | Route between regions by latency/priority; no traffic inspection |
| **Front Door** | HTTP (L7) | Global | CDN + WAF + global load balancing; terminate SSL at edge |
| **Application Gateway** | HTTP (L7) | Regional | WAF within a region; path-based routing within AKS/VMSS |

**Typical stack:** Front Door (global) → Application Gateway (regional WAF) → AKS

### Q: When would you use Azure Service Bus vs Azure Event Hubs vs Azure Event Grid?

| | Service Bus | Event Hubs | Event Grid |
|---|---|---|---|
| Pattern | Message queue / pub-sub | Event streaming | Event routing |
| Order guarantee | FIFO (sessions) | Per-partition | No guarantee |
| Retention | 80 GB, 14 days max | Up to 90 days | 24 hours |
| Protocol | AMQP, HTTP | AMQP, Kafka, HTTP | HTTP webhooks |
| Best for | Order processing, transactions | Telemetry, log ingestion, streaming | Azure resource events, webhook triggers |
| Throughput | ~1M msg/sec | Millions events/sec | ~10M events/day |

### Q: How does Cosmos DB handle conflicts in multi-region writes?

Three conflict resolution modes:
1. **Last-Write-Wins (default):** based on `_ts` timestamp — whichever write is more recent wins. Simple but requires clock synchronisation.
2. **Custom (stored procedure):** you define a JavaScript merge function. Can implement CRDT-style merges.
3. **Async conflicts feed:** all conflicts recorded in conflict feed — application resolves them asynchronously.

### Q: How do you design for 99.99% availability on Azure?

99.99% = 52 minutes downtime per year.

Requirements:
- **Compute:** AKS Standard tier across 3 AZs + VMSS zone-redundant
- **Database:** Azure SQL Business Critical (3 replicas, one per zone) OR Cosmos DB (99.999% SLA)
- **Networking:** Front Door (99.99%) + Application Gateway (zone-redundant)
- **Storage:** ZRS (Zone-Redundant Storage) for Blob
- **Cache:** Redis Premium with zone redundancy
- **Eliminate single points of failure:** no single-instance resources

No single service guarantees 99.99% — it comes from the combination of redundancy layers.

---

## Quick Reference — Azure Services at a Glance

| Problem | Azure Service |
|---|---|
| Global HTTP LB + CDN + WAF | Azure Front Door |
| Regional HTTP LB + WAF | Application Gateway |
| TCP/UDP load balancing | Azure Load Balancer (Standard) |
| Global DNS routing | Traffic Manager |
| Kubernetes | AKS |
| Serverless containers | Azure Container Apps / ACI |
| Serverless functions | Azure Functions |
| Message queue | Service Bus Queue |
| Pub/Sub | Service Bus Topic |
| Event routing (Azure events) | Event Grid |
| Event streaming (high throughput) | Event Hubs |
| Relational DB | Azure SQL Database / Azure DB for PostgreSQL |
| Globally distributed NoSQL | Cosmos DB |
| In-memory cache | Azure Cache for Redis |
| Object storage | Blob Storage |
| File share (SMB/NFS) | Azure Files |
| Block storage | Managed Disks |
| Container registry | Azure Container Registry (ACR) |
| Secret management | Azure Key Vault |
| Monitoring + alerting | Azure Monitor |
| APM + distributed tracing | Application Insights |
| CI/CD | Azure DevOps Pipelines |
| GitOps | ArgoCD on AKS / Flux |
| IaC | Terraform / Bicep / ARM |
