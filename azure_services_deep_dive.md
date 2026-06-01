# Azure Services Deep Dive — Addendum

**Covers gaps in azure_cloud_interview_guide.md:**
Azure AD/Entra ID, Key Vault, AKS operations, ACR, Cosmos DB, RBAC/Policy deep dive

---

## 1. Azure AD / Entra ID — Deep Dive

### What is Azure AD (Entra ID)?

```
Azure Active Directory (now called Microsoft Entra ID) is Microsoft's
cloud-based identity and access management service.

It handles:
  WHO you are:  Authentication — verify identity (passwords, MFA, certificates)
  WHAT you can do: Authorisation — Azure RBAC uses Azure AD identities as subjects

Key distinction from on-prem Active Directory:
  On-prem AD:  Manages Windows devices, GPO, LDAP, Kerberos
  Azure AD:    Manages cloud identities, OAuth2, OIDC, SAML, REST APIs
  Azure AD DS: Managed version of on-prem AD (not the same as Azure AD)
```

### Identity Types

```
1. User accounts:
   Human users (employees, guests)
   Guest (B2B): external collaborators from other orgs
   Member: employees in your tenant

2. Service Principals:
   App identity — represents an APPLICATION (not a human)
   Has AppId (client ID) + Secret or Certificate for auth
   Used by: GitHub Actions, Terraform, any external system calling Azure APIs

3. Managed Identities:
   Service Principal but Azure-managed (no credentials you touch)
   System-assigned MI: lifecycle tied to the Azure resource (deleted with it)
   User-assigned MI:   independent lifecycle, shareable across resources
   Used by: AKS pods, App Service, Azure Functions, VMs

4. Workload Identity (AKS-specific):
   Kubernetes Service Account → federated credential → Managed Identity
   No secrets in pods. Uses OIDC token exchange.
```

### Service Principal Deep Dive

```bash
# Create a service principal with Contributor on a resource group
az ad sp create-for-rbac \
  --name "my-terraform-sp" \
  --role "Contributor" \
  --scopes "/subscriptions/<sub-id>/resourceGroups/my-rg" \
  --sdk-auth    # outputs JSON for GitHub Actions

# Output:
{
  "clientId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",     # App ID
  "clientSecret": "~abc123...",                            # Password/secret
  "subscriptionId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "activeDirectoryEndpointUrl": "https://login.microsoftonline.com",
  "resourceManagerEndpointUrl": "https://management.azure.com/"
}

# List service principals
az ad sp list --display-name "my-terraform-sp"

# Rotate secret (good practice: rotate every 90 days)
az ad sp credential reset --id <appId> --years 1
```

**Service Principal vs Managed Identity:**
```
Service Principal:
  You manage the secret/certificate
  Secret expires → must rotate manually (set calendar reminder)
  Use for: external systems (GitHub Actions, Terraform from on-prem, Jenkins)

Managed Identity:
  Azure manages everything — no secret to handle, no expiry
  Use for: anything running ON Azure (AKS pods, Functions, VMs, App Service)
  Preferred whenever possible — eliminates entire class of security incidents
```

### App Registrations

```
App Registration = the definition of an application in Azure AD
Service Principal = the instance of that app in a tenant

One App Registration can have Service Principals in multiple tenants (multi-tenant apps).

App Registration contains:
  App ID (client ID):    unique identifier (like a username)
  Redirect URIs:         where auth tokens are sent after login
  API permissions:       what APIs the app can call (Microsoft Graph, your API)
  Certificates & secrets: credentials for the service principal
  Expose an API:         define scopes your API exposes (for OAuth2)

OAuth2 flows:
  Authorization Code:   user logs in → consent → access token
  Client Credentials:   service-to-service (no user involved)
  Device Code:          CLI tools (user logs in on another device)
```

### OIDC Federation (Keyless auth for GitHub Actions)

```yaml
# No client secrets. GitHub Actions proves identity via OIDC token.

# 1. Create federated credential on your Service Principal
az ad app federated-credential create \
  --id <app-id> \
  --parameters '{
    "name": "github-prod",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:myorg/myrepo:environment:production",
    "audiences": ["api://AzureADTokenExchange"]
  }'

# 2. GitHub Actions workflow — no secrets needed
jobs:
  deploy:
    permissions:
      id-token: write    # required for OIDC
      contents: read
    steps:
    - uses: azure/login@v1
      with:
        client-id: ${{ vars.AZURE_CLIENT_ID }}       # not a secret
        tenant-id: ${{ vars.AZURE_TENANT_ID }}       # not a secret
        subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}  # not a secret
    - run: az deployment group create ...
```

---

## 2. Azure Key Vault — Deep Dive

### Three Object Types

```
Secrets:      Arbitrary string values (passwords, connection strings, API keys)
              Versioned — each update creates a new version (old versions retained)
              URL format: https://my-vault.vault.azure.net/secrets/db-password/v1

Keys:         Cryptographic keys (RSA, EC, AES)
              Operations: encrypt, decrypt, sign, verify, wrap, unwrap
              HSM-backed option: key never leaves hardware (FIPS 140-2 Level 3)
              URL format: https://my-vault.vault.azure.net/keys/signing-key/v1

Certificates: X.509 TLS certificates
              Integrated with DigiCert/GlobalSign CAs for auto-renewal
              Auto-rotate 90 days before expiry
              Stores both cert AND private key
              Used by: App Service, API Management, Azure CDN (auto-bind)
```

### Tiers

```
Standard:  Software-protected keys. Lower cost. Most use cases.
           $0.03/10,000 operations for secrets/keys

Premium:   HSM-backed keys (FIPS 140-2 Level 3).
           Managed HSM option: dedicated single-tenant HSM
           Required for: PCI-DSS, financial services, regulated industries
           ~$5/key/month for HSM-backed
```

### Access Control Models

```
Vault Access Policies (legacy, per-vault):
  Grant a principal: Get, List, Set, Delete permissions per object type
  All-or-nothing per vault — can't grant access to specific secrets

Azure RBAC for Key Vault (recommended, GA 2021):
  Standard Azure RBAC — same model as Storage/AKS/etc.
  Granular roles:
    Key Vault Secrets User:      Read secrets (GetSecretValue equivalent)
    Key Vault Secrets Officer:   Read + write + delete secrets
    Key Vault Crypto User:       Use keys (encrypt/decrypt/sign)
    Key Vault Crypto Officer:    Manage keys
    Key Vault Administrator:     Full access
  Scope to specific secret: /vaults/<name>/secrets/<secret-name>

# Grant AKS pod access to specific secret only
az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee <managed-identity-object-id> \
  --scope "/subscriptions/.../vaults/my-vault/secrets/db-password"
```

### Soft Delete and Purge Protection

```
Soft delete (now MANDATORY — cannot disable):
  Deleted secrets/keys go to "deleted" state for 7–90 days (configurable)
  Can be recovered during retention period
  After period: permanently deleted

Purge Protection:
  Once enabled: cannot FORCE delete during soft-delete period
  Even the Key Vault admin cannot purge — must wait for retention period
  Required for: BYOK (Bring Your Own Key) scenarios, compliance

# Enable purge protection on vault creation
az keyvault create \
  --name my-vault \
  --resource-group my-rg \
  --enable-purge-protection true \
  --retention-days 90

# Recover a soft-deleted secret
az keyvault secret recover --vault-name my-vault --name db-password
```

### Key Vault in Code — Best Practices

```python
# Python — use DefaultAzureCredential (tries MI first, then dev credentials)
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

credential = DefaultAzureCredential()
client = SecretClient(
    vault_url="https://my-vault.vault.azure.net",
    credential=credential
)

# Get current version (don't hardcode version in production)
secret = client.get_secret("db-password")
password = secret.value

# Get specific version (for audit/rollback)
secret = client.get_secret("db-password", version="abc123")

# List all versions
versions = client.list_properties_of_secret_versions("db-password")
```

### Certificate Rotation (zero-downtime)

```
Key Vault + App Service auto-rotation:
  1. Create certificate in Key Vault (or import existing)
  2. Bind Key Vault cert to App Service custom domain
  3. Key Vault sends an event to Event Grid when cert expires soon
  4. App Service fetches latest version automatically (polling every ~48h)
  5. For custom apps: use Event Grid trigger → Lambda/Function → restart app

cert-manager integration:
  ClusterIssuer → Azure Key Vault as backend (akv2k8s operator)
  Syncs Key Vault certificates to Kubernetes Secrets
  Handles rotation automatically
```

---

## 3. AKS — Operations Deep Dive

*(Azure networking covered in azure_networking_guide. This covers operations.)*

### Node Pools

```
System node pool:
  Required (1 minimum per cluster)
  Runs AKS system components: CoreDNS, konnectivity, metrics-server
  Taint: CriticalAddonsOnly=true:NoSchedule (user workloads don't run here)
  Recommendation: use dedicated system pool, not for user workloads
  VM size: standard_D2s_v3 minimum (memory-optimised for system pods)

User node pools:
  Run your application workloads
  Can have multiple pools with different VM sizes, OS, configurations
  Add GPU pool, spot pool, Windows pool as separate node pools

# Create cluster with separate system and user pools
az aks create \
  --name my-aks \
  --node-count 3 \
  --node-vm-size Standard_D4s_v3 \
  --mode System         # system pool

az aks nodepool add \
  --cluster-name my-aks \
  --name userpool \
  --node-count 3 \
  --node-vm-size Standard_D8s_v3 \
  --mode User

# Spot node pool (70-80% cheaper, interruptible)
az aks nodepool add \
  --cluster-name my-aks \
  --name spotpool \
  --priority Spot \
  --eviction-policy Delete \
  --spot-max-price -1 \   # pay market price
  --node-vm-size Standard_D4s_v3 \
  --node-count 0 \
  --enable-cluster-autoscaler \
  --min-count 0 \
  --max-count 20
```

### Cluster Upgrades (zero-downtime strategy)

```
AKS upgrade process:
  1. New node with new K8s version added to pool
  2. Old node cordon'd (no new pods scheduled)
  3. Old node drain'd (existing pods evicted, rescheduled on new/other nodes)
  4. Old node deleted
  5. Repeat for each node

Upgrade strategies:
  Surge (default):  Add N extra nodes during upgrade, then delete old ones
    maxSurge: 1    → upgrade 1 node at a time (slow, safe)
    maxSurge: 33%  → upgrade 1/3 of nodes simultaneously (faster)
    maxSurge: 100% → double the fleet during upgrade (fastest, double cost temporarily)

  Node image upgrade: update only OS image (security patches), NOT K8s version
    Faster (minutes vs hours), less disruptive
    Auto-upgrade available: daily node image upgrades

Available K8s versions:
  Generally Supported: N and N-2 minor versions
  LTS (Long Term Support): 2-year support for N-1 version
  Check: az aks get-versions --location eastus

# Upgrade cluster control plane
az aks upgrade --name my-aks --kubernetes-version 1.29.5

# Upgrade specific node pool only
az aks nodepool upgrade \
  --cluster-name my-aks \
  --name userpool \
  --kubernetes-version 1.29.5

# Configure auto-upgrade channel
az aks update \
  --name my-aks \
  --auto-upgrade-channel stable  # node-image | patch | stable | rapid | none

# PodDisruptionBudget prevents all pods being evicted at once
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  minAvailable: "75%"  # at least 75% of pods must remain during drain
```

### Cluster Autoscaler

```
Cluster Autoscaler: adds/removes NODES when pods can't be scheduled or nodes are underutilised.

Scale-out trigger: pod stays in Pending for >N minutes (default: 10s check)
  → CA checks: would adding a node allow this pod to schedule?
  → If yes: add node

Scale-in trigger: node utilisation < 50% for >10 minutes
  → CA checks: can all pods on this node move to other nodes?
  → If yes: cordon, drain, delete node

# Enable on a node pool
az aks nodepool update \
  --cluster-name my-aks \
  --name userpool \
  --enable-cluster-autoscaler \
  --min-count 2 \
  --max-count 20

Important: CA and HPA work together.
  HPA scales PODS within existing nodes.
  CA scales NODES when pods can't be scheduled.
  Set HPA first → CA adds nodes when needed.
```

### AKS RBAC and Azure AD Integration

```
Two levels of RBAC in AKS:
  1. Azure RBAC → who can access the AKS resource (control plane API)
  2. Kubernetes RBAC → what permissions inside the cluster

Azure RBAC roles for AKS:
  Azure Kubernetes Service RBAC Cluster Admin:  kubectl everything
  Azure Kubernetes Service RBAC Admin:          namespace admin
  Azure Kubernetes Service RBAC Writer:         deploy, scale, etc.
  Azure Kubernetes Service RBAC Reader:         read-only
  Azure Kubernetes Service Cluster User Role:   get kubeconfig

# Enable Azure AD integration + Azure RBAC
az aks create \
  --name my-aks \
  --enable-aad \
  --enable-azure-rbac

# Grant a developer read access to a namespace
az role assignment create \
  --role "Azure Kubernetes Service RBAC Reader" \
  --assignee developer@company.com \
  --scope "/subscriptions/.../namespaces/dev"

# Get kubeconfig for a user (uses their Azure AD token)
az aks get-credentials --name my-aks --resource-group my-rg
kubectl get pods  # prompts for Azure AD login if needed
```

### Workload Identity in AKS

```
Old approach: aad-pod-identity (deprecated)
  Pod annotations → intercept IMDS calls → MSI token
  Problems: DaemonSet with cluster-admin, security issues

New approach: AKS Workload Identity (GA 2023)
  Based on OIDC federation — same pattern as GitHub Actions
  No privileged DaemonSet needed

Setup:
  1. Enable OIDC issuer on AKS
  2. Create User-Assigned Managed Identity
  3. Create Kubernetes Service Account with annotation
  4. Create federated credential linking SA → MI
  5. Grant MI access to Key Vault / Storage / etc.

az aks update --name my-aks --enable-oidc-issuer --enable-workload-identity

# Create MI
az identity create --name my-app-mi --resource-group my-rg

# Get OIDC issuer URL
OIDC_URL=$(az aks show --name my-aks \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

# Create federated credential
az identity federated-credential create \
  --name my-app-fed-cred \
  --identity-name my-app-mi \
  --resource-group my-rg \
  --issuer $OIDC_URL \
  --subject "system:serviceaccount:my-namespace:my-service-account" \
  --audiences "api://AzureADTokenExchange"

# Kubernetes ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-service-account
  namespace: my-namespace
  annotations:
    azure.workload.identity/client-id: "<mi-client-id>"
```

---

## 4. ACR — Azure Container Registry

### What ACR Does

```
ACR = Azure's managed private container registry.
Stores Docker images, Helm charts, and OCI artefacts.

Tiers:
  Basic:     5GB storage, dev/test, no geo-replication, no private endpoints
  Standard:  100GB, production, webhooks, Tasks (CI builds)
  Premium:   500GB, geo-replication, private endpoints, dedicated data endpoints
             Required for: multi-region deployments, private network access
```

### Authentication Methods

```
Admin account (simple, insecure):
  Single username/password for the registry
  NOT recommended for production (shared secret, no audit trail)
  Use only: quick local testing

Service Principal (CI/CD):
  Create SP → assign AcrPush/AcrPull role → use client ID + secret
  az ad sp create-for-rbac --name "acr-push-sp" \
    --role AcrPush \
    --scopes /subscriptions/.../registries/my-registry

Azure AD (recommended for humans):
  az acr login --name my-registry
  Uses your az CLI identity — no separate credentials

Managed Identity (AKS and other Azure services — recommended):
  AKS cluster MI: assign AcrPull role → no credentials in cluster
  az aks update --name my-aks \
    --attach-acr my-registry  # grants AcrPull to AKS kubelet identity
```

### ACR Tasks — Build in the Cloud

```bash
# Build image in ACR without local Docker (ACR Tasks)
az acr build \
  --registry my-registry \
  --image my-app:v1.0 \
  --file Dockerfile \
  .

# Multi-step task — build, test, push
az acr task create \
  --registry my-registry \
  --name build-and-push \
  --image my-app:{{.Run.ID}} \
  --context https://github.com/myorg/my-app.git \
  --branch main \
  --file acr-task.yaml \
  --git-access-token <token>

# acr-task.yaml
version: v1.1.0
steps:
  - build: -t $Registry/my-app:$ID .
  - push: ["$Registry/my-app:$ID"]
  - cmd: $Registry/my-app:$ID pytest tests/
```

### Geo-Replication (Premium)

```
Replicate registry to multiple Azure regions.
AKS in each region pulls from local registry replica → no cross-region egress.

az acr replication create \
  --registry my-registry \
  --location westeurope     # replicates to West Europe

# Webhooks on replication — notify when image available in region
az acr webhook create \
  --registry my-registry \
  --name notify-deploy \
  --uri https://my-ci.example.com/hook \
  --actions push
```

### Content Trust + Image Signing

```
Enable content trust → images must be signed before they can be pulled.
Integrates with Notary (CNCF) or Cosign (Sigstore).

# Enable content trust enforcement in AKS
# Use Azure Policy: "Only signed images should be deployed"
# Or Gatekeeper OPA policy to validate image signatures

# Sigstore Cosign with ACR
cosign sign \
  --key my-signing-key.pem \
  my-registry.azurecr.io/my-app:v1.0

cosign verify \
  --key my-signing-key.pem \
  my-registry.azurecr.io/my-app:v1.0
```

---

## 5. Cosmos DB — Deep Dive

### APIs (choose once, cannot change)

```
Core (SQL) API:       JSON documents, SQL-like queries. Default, most features.
MongoDB API:          Wire-compatible with MongoDB drivers. Migrate existing apps.
Cassandra API:        CQL-compatible. Migrate from Apache Cassandra.
Gremlin API:          Graph database. Traversal queries.
Table API:            Key-value, compatible with Azure Table Storage.

Choose Core (SQL) for new projects — most Cosmos DB features available.
Choose MongoDB/Cassandra API only if migrating existing workloads.
```

### Partition Key — The Most Important Design Decision

```
Cosmos DB stores data across physical partitions (internal shards).
Partition key determines which partition an item goes to.

Logical partition: all items with the same partition key value
Physical partition: group of logical partitions (managed by Cosmos)
  Max size: 50GB per logical partition
  Max throughput: 10,000 RU/s per physical partition

Good partition key:
  HIGH cardinality → many distinct values → even distribution
  Appears in most queries → enables in-partition queries (cheap)
  Not a timestamp/sequential → hot partition risk

Examples:
  Users collection:       PK = userId         ✓ high cardinality, per-user queries
  Orders collection:      PK = customerId     ✓ query "all orders for customer X"
  IoT telemetry:          PK = deviceId       ✓ high cardinality
  
  BAD: PK = country       ✗ low cardinality, "US" is hot
  BAD: PK = status        ✗ only 3 values (active/inactive/pending)
  BAD: PK = date (today)  ✗ all writes go to today's partition

Hierarchical partition keys (Cosmos DB 2023):
  PK = [tenantId, userId]
  First level: tenant (isolates tenants)
  Second level: userId (distributes within tenant)
```

### Request Units (RU) — Cosmos DB Currency

```
All operations cost RUs:
  1 RU  = 1 point read (get by ID + partition key) of 1KB item
  ~3 RU = SQL query with index hit
  ~10 RU = SQL query with full partition scan
  ~5 RU = write 1KB item

Cost factors: item size, indexing policy, query complexity, partition scan vs index

Pre-provisioned throughput:
  Set RU/s → pay whether used or not
  Autoscale: set max RU/s → Cosmos scales 10%–100% of max automatically

Serverless: pay per RU consumed. No minimum. Good for dev/test or bursty.

Monitoring: watch "Normalized RU Consumption" metric
  > 100% = throttled (429 Too Many Requests)
  < 30%  = over-provisioned (reduce and save cost)
```

### Consistency Levels

```
Five levels (strongest to weakest):
                                 Latency  Throughput  Availability
Strong:        Linearizable       High     Low         Lower
               (always latest)
Bounded         Staleness is      Medium   Medium      Medium
Staleness:     bounded (K ops     
               or T seconds)
Session:        Consistent         Low      High        High
                within session     ← DEFAULT, recommended for most apps
Consistent      No out-of-order    Low      High        High
Prefix:         reads, may be stale
Eventual:       Maximum            Lowest   Highest     Highest
               performance,
               may read stale

Session consistency:
  Within one session: reads always reflect your own writes
  Across sessions: may read slightly stale data
  Use for: shopping carts, user profiles, most web apps

Strong consistency:
  Read always returns latest committed write globally
  Double the latency (must check all regions)
  Use for: financial ledgers, critical state

Strong consistency with multi-region write = not supported.
For multi-region writes, maximum is Bounded Staleness.
```

### Change Feed

```
Cosmos DB Change Feed: ordered log of all create/update operations.
(Deletes NOT included by default — use soft-delete pattern)

Use cases:
  → Event-driven: trigger Azure Function on item change
  → Cache invalidation: update Redis when Cosmos item changes
  → Data sync: replicate to SQL for reporting
  → Audit trail: stream all changes to Event Hub

Change feed processor pattern:
  Multiple consumers, each gets a partition range
  Checkpoints stored in a separate "lease" container
  At-least-once delivery

# Azure Function trigger on change feed
@app.cosmos_db_trigger(
    arg_name="documents",
    database_name="mydb",
    container_name="orders",
    connection="CosmosDBConnection",
    lease_container_name="leases"
)
def cosmosdb_trigger(documents: func.DocumentList):
    for doc in documents:
        logging.info(f"Order changed: {doc['id']}")
        # invalidate cache, trigger downstream processing
```

---

## 6. Azure RBAC + Azure Policy — Deep Dive

### Azure RBAC Architecture

```
Assignment structure:
  Security principal (WHO):    User, Group, Service Principal, Managed Identity
  Role definition (WHAT):      List of allowed actions (Operations)
  Scope (WHERE):               Management Group → Subscription → Resource Group → Resource

Scope hierarchy (assignment at parent = inherited by children):
  Management Group
    └── Subscription
          └── Resource Group
                └── Resource

Example:
  Assign "Contributor" at Subscription level
  → principal gets Contributor on ALL resource groups and resources in that subscription
  
  Assign "Storage Blob Data Reader" at specific storage account
  → principal can only read blobs in THAT account, nothing else
```

### Built-in Roles (most asked in interviews)

```
Owner:            All actions including assigning roles (USE SPARINGLY)
Contributor:      All actions EXCEPT assigning roles (full resource control)
Reader:           Read-only on all resources
User Access Admin: Only assign/remove roles (no resource actions)

Service-specific:
  AcrPull / AcrPush:              Pull/push container images from ACR
  AKS RBAC Cluster Admin:         kubectl everything in AKS
  Key Vault Secrets User:         Read secrets from Key Vault
  Key Vault Secrets Officer:      Read + write + delete Key Vault secrets
  Storage Blob Data Contributor:  Read + write blobs (NOT storage account management)
  Storage Blob Data Reader:       Read blobs (ML model reads, Loki reads)
  Managed Identity Operator:      Assign/use managed identities
```

### Custom Roles

```json
{
  "Name": "AKS Namespace Reader",
  "Description": "Read pods and deployments in AKS namespace",
  "Actions": [
    "Microsoft.ContainerService/managedClusters/read",
    "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action"
  ],
  "NotActions": [],
  "DataActions": [
    "Microsoft.ContainerService/managedClusters/namespaces/*/read",
    "Microsoft.ContainerService/managedClusters/pods/*/read"
  ],
  "NotDataActions": [],
  "AssignableScopes": [
    "/subscriptions/<sub-id>"
  ]
}
```

**Actions vs DataActions:**
```
Actions:     Azure Resource Manager control plane
             e.g., create/delete/list Azure resources
             Microsoft.Compute/virtualMachines/start/action

DataActions: Data plane operations
             e.g., read/write INSIDE resources
             Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read
             Microsoft.ContainerService/managedClusters/pods/read (kubectl get pods)

Storage Blob Data Contributor = DataAction
Storage Account Contributor = Action (manage the storage account resource, not its data)
```

### Azure Policy — Deep Dive

```
Azure Policy: define RULES for Azure resources. Enforce governance at scale.

Effect types (in order of severity):
  Disabled:              Policy does nothing (testing)
  Audit:                 Non-compliant resources flagged, no block
  AuditIfNotExists:      Audit if related resource doesn't exist
  Append:                Add properties to resource on create/update
  Modify:                Change properties on resource
  Deny:                  Block non-compliant resource creation/update
  DeployIfNotExists:     Deploy a related resource if it doesn't exist
                         e.g., "if VM created without disk encryption, deploy it"

Policy hierarchy:
  Initiative (Policy Set): group of related policies
  Policy Definition:       single rule
  Assignment:              apply to scope with parameters

Important built-in policies for platform:
  "Kubernetes cluster should not allow privileged containers"
  "Ensure AKS cluster has Azure Policy add-on installed"  
  "Require tag on resource groups" (Append)
  "Allowed locations" (Deny — enforce data residency)
  "Storage accounts should use private endpoints" (Deny)
  "Enable Azure Defender for Kubernetes" (DeployIfNotExists)

Compliance: see % of resources compliant in Azure portal
Remediation tasks: trigger DeployIfNotExists/Modify on existing resources
```

### Policy Example — Require Tags

```json
{
  "mode": "Indexed",
  "parameters": {
    "tagName": {"type": "String"},
    "tagValue": {"type": "String"}
  },
  "policyRule": {
    "if": {
      "allOf": [
        {"field": "type", "equals": "Microsoft.Compute/virtualMachines"},
        {
          "field": "[concat('tags[', parameters('tagName'), ']')]",
          "notEquals": "[parameters('tagValue')]"
        }
      ]
    },
    "then": {
      "effect": "Deny"
    }
  }
}
```

**Azure Policy + Kubernetes (OPA Gatekeeper):**
```
Azure Policy for AKS installs OPA Gatekeeper (ConstraintTemplate + Constraint)
Policies evaluated at admission control — pods blocked before creation.

Useful AKS policies:
  "Do not allow privileged containers"
  "Ensure container CPU and memory resource limits are set"
  "Require only allowed container registries"
  "Ensure pod uses approved service account"
```

---

## Quick Reference — What the Existing Guides Cover vs This File

| Service | azure_cloud_guide | azure_networking_guide | azure_system_design | This file |
|---|---|---|---|---|
| Networking (VNet/NSG/PE) | Good | Deep dive | Used | — |
| Azure Functions | Deep dive | 1 mention | Used | — |
| Storage Account | Good | — | — | — |
| Managed Identity | Good | 1 mention | — | **Enhanced here** |
| Service Bus/Event Hub | Good | — | — | — |
| Azure Monitor | Good | — | — | — |
| AKS Networking | — | Deep dive | Used | — |
| **Azure AD/Entra ID** | 1 page | 1 mention | — | **Deep dive here** |
| **Key Vault** | 3 lines | 1 line | — | **Deep dive here** |
| **AKS operations** | — | Networking only | HA only | **Deep dive here** |
| **ACR** | Missing | — | — | **Deep dive here** |
| **Cosmos DB** | 2 lines | 1 line | 3 lines | **Deep dive here** |
| **RBAC + Policy** | 1 page | 1 page | — | **Deep dive here** |
| **Service Principals** | 1 line | — | — | **Deep dive here** |
