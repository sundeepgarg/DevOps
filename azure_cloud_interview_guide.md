# Azure Cloud Services Interview Guide

**Target Role:** Senior/Principal Platform / DevOps / MLOps Engineer  
**Background:** Azure primary cloud (Voya ARO, AKS, Azure Functions, Azure Monitor), AZ-104 certified

---

## Azure Global Architecture

```
Azure Structure:
┌───────────────────────────────────────────────────────────────┐
│  Management Group (Root)                                      │
│  └── Management Group (Platform)                             │
│       ├── Subscription: Production                           │
│       │   ├── Resource Group: platform-rg                    │
│       │   │   ├── AKS Cluster                               │
│       │   │   ├── VNet                                      │
│       │   │   └── Key Vault                                 │
│       │   └── Resource Group: data-rg                       │
│       │       ├── Storage Account                           │
│       │       └── Azure SQL                                 │
│       └── Subscription: Development                         │
└───────────────────────────────────────────────────────────────┘

Management Groups → Subscriptions → Resource Groups → Resources
Azure Policy applied at any level → inherited downward
RBAC applied at any level → inherited downward
```

---

## 1. Azure Networking Architecture

```
Hub-and-Spoke Topology (Enterprise Standard):
┌─────────────────────────────────────────────────────────┐
│                   Hub VNet (10.0.0.0/16)                │
│  ┌────────────────────────────────────────────────┐     │
│  │  GatewaySubnet    Azure Firewall   DNS Resolver│     │
│  │  VPN/ExpressRoute  (egress control) (168.x.x.x)│     │
│  └────────────────────────────────────────────────┘     │
│         │                │                │             │
│    VNet Peering     VNet Peering     VNet Peering       │
│         │                │                │             │
│  ┌──────▼─────┐  ┌───────▼────┐  ┌───────▼────┐       │
│  │ Spoke VNet │  │ Spoke VNet │  │ Spoke VNet │       │
│  │ Platform   │  │ ML/AI      │  │ Data       │       │
│  │ AKS/ARO    │  │ GPU Nodes  │  │ PostgreSQL │       │
│  └────────────┘  └────────────┘  └────────────┘       │
└─────────────────────────────────────────────────────────┘

Traffic flow:
  Spoke → Hub Firewall → Internet (forced tunneling)
  Spoke → Spoke: via Hub (hub-spoke routing, not direct peering)
  On-prem → Hub Gateway → all Spokes
```

### Azure VNet Key Concepts

```bash
# VNet address space: 10.0.0.0/16 = 65,536 IPs
# Subnets carve out ranges within the VNet

# Reserved IPs in every subnet (Azure takes 5):
# x.x.x.0   Network address
# x.x.x.1   Default gateway (Azure)
# x.x.x.2-3 Azure DNS
# x.x.x.255 Broadcast
# So /24 = 256 - 5 = 251 usable IPs

# NSG (Network Security Group) — stateful, applied to subnet or NIC
# Priority 100-4096: lower = higher priority; 65000 = default deny all inbound
# Rule: Priority | Name | Port | Protocol | Source | Destination | Action

# Create NSG rule allowing HTTPS inbound
az network nsg rule create \
  --resource-group platform-rg \
  --nsg-name aks-nsg \
  --name Allow-HTTPS-Inbound \
  --priority 100 \
  --protocol Tcp \
  --destination-port-ranges 443 \
  --access Allow \
  --direction Inbound
```

### Private Endpoints and DNS

```
Private Endpoint Flow:
  Resource (Key Vault, Storage, SQL)
       │
  Private Endpoint (NIC with private IP in your VNet)
       │
  Private DNS Zone (privatelink.vaultcore.azure.net)
       │
  VNet Link → your VNet resolves the private name to private IP
  
  Without Private Endpoint:
    vault.vault.azure.net → 52.180.x.x (public IP)
  
  With Private Endpoint:
    vault.privatelink.vaultcore.azure.net → 10.0.2.5 (private IP)
    
  On-prem DNS resolution:
    On-prem DNS → Azure DNS Resolver (168.63.129.16) → Private DNS Zone
    (Requires DNS Resolver in Hub VNet or DNS forwarder)
```

---

## 2. Azure Functions — Deep Dive

### Architecture Overview

```
Azure Functions Architecture:

  Trigger (What starts the function?)
       │
  ┌────▼──────────────────────────────────────────┐
  │  Function App (unit of deployment)            │
  │  ┌─────────────────────────────────────────┐  │
  │  │  Function 1: HTTP Trigger               │  │
  │  │  Function 2: Timer Trigger              │  │
  │  │  Function 3: Service Bus Trigger        │  │
  │  │  Function 4: Blob Storage Trigger       │  │
  │  └─────────────────────────────────────────┘  │
  │                                               │
  │  Hosting Plan: Consumption | Premium | Ded.   │
  │  Runtime: Python | .NET | Node.js | Java      │
  └───────────────────────────────────────────────┘
       │
  Bindings (Input/Output — connect to other services)
  ┌────▼──────────────────────────────────────────┐
  │  Input:  Blob Storage, Cosmos DB, SQL, Queue  │
  │  Output: Blob Storage, Service Bus, Cosmos DB │
  └───────────────────────────────────────────────┘
```

### Hosting Plans Comparison

| Plan | Scale | Cold Start | VNet | Max Duration | Cost |
|------|-------|-----------|------|-------------|------|
| **Consumption** | 0→200 instances | Yes (1-3s) | No (Flex: Yes) | 10 min | Per execution |
| **Premium** | Pre-warmed instances | No | Yes | Unlimited | Per vCPU-s (min 1) |
| **Dedicated (App Service)** | Manual/auto | No | Yes | Unlimited | Always-on cost |
| **Container Apps** | 0→N pods | Yes (container) | Yes | Unlimited | Per vCPU-s |

### Trigger Types

```python
# 1. HTTP Trigger — REST API endpoint
import azure.functions as func

app = func.FunctionApp()

@app.function_name("process_inference")
@app.route(route="predict", methods=["POST"], auth_level=func.AuthLevel.FUNCTION)
def predict(req: func.HttpRequest) -> func.HttpResponse:
    data = req.get_json()
    result = model.predict(data["features"])
    return func.HttpResponse(json.dumps({"prediction": result}), mimetype="application/json")


# 2. Timer Trigger — Cron-based scheduling
@app.function_name("drift_detector")
@app.timer_trigger(schedule="0 0 2 * * 0",  # Every Sunday 2am
                   arg_name="myTimer",
                   run_on_startup=False)
def run_drift_check(myTimer: func.TimerRequest) -> None:
    psi_score = compute_psi(reference_data, production_data)
    if psi_score > 0.25:
        trigger_retraining_pipeline()


# 3. Service Bus Trigger — event-driven processing
@app.function_name("process_queue_message")
@app.service_bus_queue_trigger(arg_name="msg",
                               queue_name="ml-inference-queue",
                               connection="ServiceBusConnectionString")
def process_message(msg: func.ServiceBusMessage) -> None:
    body = msg.get_body().decode("utf-8")
    payload = json.loads(body)
    result = inference_pipeline(payload)
    # Output binding: save result to Blob Storage


# 4. Blob Storage Trigger — react to new files
@app.function_name("process_uploaded_document")
@app.blob_trigger(arg_name="myblob",
                  path="uploads/{name}",
                  connection="StorageConnectionString")
def process_blob(myblob: func.InputStream) -> None:
    content = myblob.read()
    text = extract_text(content)
    embed_and_index(text, source=myblob.name)


# 5. Event Grid Trigger — react to Azure events
@app.function_name("handle_model_event")
@app.event_grid_trigger(arg_name="event")
def handle_event(event: func.EventGridEvent) -> None:
    event_data = event.get_json()
    if event.event_type == "Microsoft.Storage.BlobCreated":
        process_new_model(event_data["url"])
```

### Function App Configuration

```yaml
# local.settings.json (local development)
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "ServiceBusConnectionString": "@Microsoft.KeyVault(VaultName=myvault;SecretName=sb-conn)",
    "MLFLOW_TRACKING_URI": "https://mlflow.internal.company.com"
  }
}

# Terraform deployment
resource "azurerm_linux_function_app" "drift_monitor" {
  name                = "drift-monitor-func"
  resource_group_name = azurerm_resource_group.platform.name
  location            = azurerm_resource_group.platform.location
  service_plan_id     = azurerm_service_plan.premium.id
  storage_account_name = azurerm_storage_account.func_storage.name

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME" = "python"
    "MLFLOW_TRACKING_URI"      = var.mlflow_uri
    # Key Vault reference — no secrets in app settings
    "DB_PASSWORD" = "@Microsoft.KeyVault(VaultName=${azurerm_key_vault.kv.name};SecretName=db-password)"
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
    vnet_route_all_enabled = true   # All traffic through VNet (for Private Endpoints)
  }

  virtual_network_subnet_id = azurerm_subnet.function_subnet.id  # VNet integration
}
```

### Durable Functions (Stateful Orchestration)

```python
# Durable Functions: orchestrate multi-step workflows
# Used at Voya for ETL pipeline orchestration (azure-ai-etl-pipeline project)

import azure.durable_functions as df

# Orchestrator function (defines the workflow)
def orchestrator_function(context: df.DurableOrchestrationContext):
    # 1. Ingest data
    raw_data = yield context.call_activity("IngestData", {"source": "s3://bucket/daily"})
    
    # 2. Process in parallel (fan-out)
    parallel_tasks = [
        context.call_activity("ProcessChunk", chunk)
        for chunk in raw_data["chunks"]
    ]
    results = yield context.task_all(parallel_tasks)  # Fan-in: wait for all
    
    # 3. Aggregate and store
    yield context.call_activity("AggregateResults", results)
    
    return "Pipeline complete"

main = df.Orchestrator.create(orchestrator_function)
```

---

## 3. Azure Storage Services

```
Azure Storage Account:
┌──────────────────────────────────────────────────────────┐
│  Storage Account (namespace: mystorageaccount)           │
│  ┌─────────────┐ ┌───────────┐ ┌────────┐ ┌──────────┐  │
│  │ Blob Storage│ │   Files   │ │ Queues │ │  Tables  │  │
│  │ (objects)   │ │ (SMB/NFS) │ │(async) │ │(NoSQL)   │  │
│  │             │ │           │ │        │ │          │  │
│  │ Containers: │ │ Shares:   │ │FIFO    │ │Key-Value │  │
│  │ hot/cool/   │ │ mount to  │ │message │ │PartKey + │  │
│  │ archive tiers│ │ VMs/AKS  │ │queue   │ │ RowKey   │  │
│  └─────────────┘ └───────────┘ └────────┘ └──────────┘  │
└──────────────────────────────────────────────────────────┘

Blob access tiers:
  Hot:     frequent access, higher storage cost, lower retrieval
  Cool:    infrequent access (30-day minimum), lower storage
  Cold:    rarely accessed (90-day minimum)
  Archive: rarely needed (180-day minimum), hours to rehydrate

Use for ML:
  Model artifacts → Blob (Hot tier)
  Training datasets → Blob (Cool tier, lifecycle to Cold after 90 days)
  ODF-like shared storage on AKS → Azure Files (NFS 4.1, RWX)
  Message queue for inference jobs → Storage Queues or Service Bus
```

---

## 4. Azure Identity — Managed Identity

```
Managed Identity Flow:
  Azure Resource (VM, AKS Pod, Function App)
       │ requests token
  Azure Instance Metadata Service (169.254.169.254)
       │ returns JWT
  Azure AD (validates identity of the Azure resource)
       │
  Target service (Key Vault, Storage, SQL)
       │ validates token against RBAC/policy
  Access granted ✓

Types:
  System-Assigned MI: tied to the resource lifecycle (delete resource = delete MI)
  User-Assigned MI:   independent lifecycle, can be shared across resources

AKS Workload Identity (Kubernetes-native):
  Pod → Service Account → Azure AD Federated Credential → Managed Identity → Key Vault
  (Similar to AWS IRSA)
```

```yaml
# AKS Pod using Workload Identity
apiVersion: v1
kind: ServiceAccount
metadata:
  name: inference-sa
  namespace: ml-platform
  annotations:
    azure.workload.identity/client-id: "<user-assigned-mi-client-id>"
---
spec:
  serviceAccountName: inference-sa
  # Pod automatically gets Azure AD token via projected volume
  # Azure SDK picks it up: DefaultAzureCredential() handles it
```

---

## 5. Azure Service Bus vs Event Hub vs Event Grid

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  Event Grid              Event Hub              Service Bus     │
│  (Event routing)         (Data streaming)       (Message queue) │
│                                                                 │
│  - Infrastructure        - 1M+ events/sec       - Up to 80GB   │
│    events                - Time-ordered          messages       │
│  - Azure events:         - Partitioned           - FIFO         │
│    blob created,         - Kafka-compatible      - At-least-once│
│    resource changed      - 1-7 day retention     - Ordering     │
│  - Serverless,           - Consumer groups       - Dead-letter  │
│    push model            - Capture to Blob       - Transactions │
│                                                                 │
│  Use for:                Use for:                Use for:       │
│  React to Azure          ML training data        Job queues     │
│  platform events         Real-time telemetry     Order processing│
│  Webhook routing         Log streaming           Retry logic    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. Azure Monitor + Application Insights

```
Azure Observability Stack:
┌─────────────────────────────────────────────────────────┐
│                  Azure Monitor                          │
│  ┌─────────────────────────────────────────────────┐   │
│  │  Log Analytics Workspace                        │   │
│  │  - Kusto Query Language (KQL)                  │   │
│  │  - Retains logs/metrics up to 2 years          │   │
│  │  - Linked to: AKS, VMs, Functions, AppInsights │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  ┌──────────────────┐  ┌──────────────────────────┐    │
│  │ Application      │  │ Azure Monitor Metrics    │    │
│  │ Insights         │  │ (Platform metrics:       │    │
│  │ - Distributed    │  │  CPU, memory, storage)   │    │
│  │   tracing        │  │ - Custom metrics         │    │
│  │ - Dependency map │  │ - Alerts → Action Groups │    │
│  │ - Live Metrics   │  └──────────────────────────┘    │
│  │ - Availability   │                                  │
│  │   tests          │                                  │
│  └──────────────────┘                                  │
└─────────────────────────────────────────────────────────┘

KQL query examples:
// Exceptions in last 1 hour
exceptions
| where timestamp > ago(1h)
| summarize count() by type, outerMessage
| order by count_ desc

// P95 request latency
requests
| where timestamp > ago(1h)
| summarize percentile(duration, 95) by bin(timestamp, 5m)
| render timechart
```

---

## 7. Azure DevOps Pipelines vs GitHub Actions

```
Azure DevOps Pipeline:                GitHub Actions:
  - YAML or classic GUI               - YAML only
  - Azure Boards integration          - GitHub Issues/PRs integration
  - Azure Artifacts (package feed)    - GitHub Packages
  - Self-hosted agents on AKS/VMs     - self-hosted runners (ARC on OCP)
  - Gate approvals built-in           - Environment protection rules
  - Multi-stage pipelines             - Workflow jobs
  - Variable groups (secrets)         - Repository secrets

Both support: container jobs, matrix builds, caching, OIDC to Azure
```

---

## 8. Scenario-Based Interview Questions

**Q: An Azure Function with VNet integration can't reach a Key Vault private endpoint. Debug it.**

1. **Check Private Endpoint exists**: `az keyvault show --name myvault | jq .properties.networkAcls`
2. **Check Private DNS Zone**: Does `privatelink.vaultcore.azure.net` exist with an A record for the vault?
3. **Check VNet Link**: Is the Private DNS Zone linked to the Function App's integration VNet?
4. **Check Route Table**: Function App's integration subnet needs UDR to route traffic through the VNet (not back to internet). Check `vnet_route_all_enabled = true` in Function App config.
5. **Check NSG on the vault's subnet**: inbound rule allowing TCP 443 from the Function App subnet CIDR.
6. **DNS resolution test**: `nslookup myvault.vault.azure.net` from within the VNet — should return a `10.x.x.x` private IP, not a public Azure IP.

**Q: How would you design an event-driven ML pipeline using Azure Functions?**

```
Architecture:
  User uploads document to Blob Storage (uploads/ container)
       │ Blob Created event → Event Grid
  Azure Function: process_document (Blob Trigger)
       │ Extract text → chunk → embed
       │ Write chunks + vectors to Storage Queue
  Azure Function: index_chunks (Queue Trigger)
       │ Batch upsert to Azure AI Search (vector index)
       │ Write metadata to Cosmos DB
  Azure Function: notify_complete (Queue Trigger)
       │ POST webhook to calling application
       │ Write completion event to Event Hub (audit log)

Scaling:
  Queue-triggered Functions scale with queue depth (KEDA-like)
  Premium plan: no cold start, VNet integration for Private Endpoints
  Idempotency: use blob name as idempotency key (re-process = safe)
```

**Q: What is the difference between Azure Functions Consumption plan and Premium plan?**

**Consumption**:
- Scales 0 to 200 instances automatically
- Cold start: 1-3 seconds on first invocation after idle
- No VNet integration (unless Flex Consumption preview)
- Max 10 minute execution time
- Cost: pay per execution ($0.000016/GB-s)

**Premium**:
- Always-warm pre-warmed instances (no cold start)
- VNet integration → can access Private Endpoints (Key Vault, Storage, databases)
- Unlimited execution duration
- Up to 4 vCPU, 14GB RAM per instance
- Cost: minimum 1 instance always running (~$135/month minimum)

**When to choose Premium**: any Function that needs to access private network resources (databases, Key Vault via private endpoint, AKS internal services). Voya's ETL Azure Functions use Premium for VNet access to private Storage Accounts and databases.

**Q: How does Azure RBAC work and how is it different from Azure AD permissions?**

**Azure RBAC**: controls access to *Azure resources* (VMs, Storage, AKS, Key Vault secrets).
  - Scope: Management Group → Subscription → Resource Group → Resource
  - Roles: Owner, Contributor, Reader + built-in service roles + custom roles
  - Assignment: who (user/group/MI/SP) + role + scope

**Azure AD (Entra ID) permissions**: controls access to *Azure AD* itself (create users, read directory, app registrations).
  - Roles: Global Admin, User Admin, Application Developer
  - Separate from RBAC

Example confusion: granting someone `Contributor` on a subscription gives them full resource management rights, but they still can't read Azure AD users. Those are separate.

For ML platform: Managed Identity gets `Storage Blob Data Contributor` (RBAC) on the storage account. That's different from the storage account's network firewall rules (which control which VNets/IPs can reach the storage account API).
