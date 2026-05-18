# Terraform Interview Guide

**Target Role:** Senior/Lead DevOps / Platform / MLOps Engineer  
**Background:** 12 years OpenShift/Kubernetes; using Terraform for cloud infrastructure provisioning

---

## 1. Core Concepts

### What is Terraform and why does it matter for MLOps/Platform roles?

Terraform is a declarative IaC tool that provisions and manages cloud infrastructure via provider APIs. For platform/MLOps roles, Terraform is the standard way to provision:
- AKS/ARO clusters, VNets, NSGs, Private Endpoints
- MLflow tracking servers, storage accounts, Azure ML workspaces
- Kubernetes add-ons, DNS zones, monitoring resources

Key mental model: **Terraform is an API orchestrator** — it calls provider APIs (Azure RM, Kubernetes, Helm) and reconciles desired state (`.tf` files) with actual state (`.tfstate`).

### The three-stage workflow

```
terraform init     # Download providers, configure backend
terraform plan     # Show diff: desired state vs current state
terraform apply    # Apply the diff via provider API calls
```

`terraform destroy` reverses all resources managed by the state file.

---

## 2. State Management

### What is Terraform state and why is it critical?

State (`terraform.tfstate`) is a JSON file mapping your `.tf` resource definitions to real cloud resource IDs. Without state, Terraform cannot know what it already created.

**Why remote state is mandatory for teams:**
- Local state causes "works on my machine" problems — team members have different state files
- Remote state (Azure Blob Storage, Terraform Cloud, S3) is the single source of truth
- Remote state backends support **state locking** to prevent concurrent applies corrupting state

### Remote backend configuration (Azure Blob Storage)

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "tf-state-rg"
    storage_account_name = "tfstate12345"
    container_name       = "tfstate"
    key                  = "prod/aks-cluster.tfstate"
  }
}
```

Best practice: one state file per environment per layer (`prod/networking.tfstate`, `prod/aks.tfstate`) rather than one giant state file. Smaller blast radius, faster plans.

### Scenario-Based Questions

**Q: Your Terraform apply fails halfway through. The state file shows some resources created, others not. How do you recover?**

1. Run `terraform plan` — Terraform compares state to desired config. Already-created resources show no change; failed resources show as needing creation.
2. Fix the root cause of the failure (e.g., quota exceeded, missing permission).
3. Run `terraform apply` again — Terraform is idempotent. It will only create the resources that are missing from state.
4. If a resource was partially created in the cloud but not recorded in state (rare but possible), use `terraform import` to pull the existing resource into state.
5. Never manually edit the state file to remove entries — use `terraform state rm` for explicit removal.

**Q: A resource was manually deleted in the Azure portal (not via Terraform). What happens on the next apply?**

This is **drift** — state says the resource exists, but reality does not.  

On `terraform plan`, Terraform detects the resource is missing and shows it as `+ create`. On `terraform apply`, it re-creates it.

To detect drift proactively without applying: `terraform plan -refresh-only` (Terraform 1.1+). This shows what changed in reality vs state without making changes.

**Q: A teammate ran `terraform apply` at the same time as you. What happens?**

With a properly configured remote backend with locking (Azure Blob + lease, or Terraform Cloud), one of you gets the lock and the other receives:
```
Error: Error acquiring the state lock
Lock Info:
  ID:        <uuid>
  Operation: apply
  Who:       teammate@host
```
The apply is blocked until the lock is released. This prevents state corruption from concurrent writes.

If the lock is stale (e.g., teammate's apply crashed without releasing lock): `terraform force-unlock <lock-id>` — confirm with the team first.

---

## 3. Modules

### What is a Terraform module?

A module is a reusable, parameterized collection of `.tf` files. Everything in Terraform is technically a module — the root module (your working directory) + any child modules you call.

**Root module** calls child modules:
```hcl
module "aks_cluster" {
  source              = "./modules/aks"
  cluster_name        = "prod-aks"
  node_count          = 3
  kubernetes_version  = "1.28"
  vnet_subnet_id      = module.networking.aks_subnet_id
}
```

### Module design principles for senior engineers

1. **Input/output contracts**: Every module has `variables.tf` (inputs) and `outputs.tf` (outputs). Treat these like an API — breaking changes require version bumps.
2. **Single responsibility**: A module does one thing (networking, AKS cluster, monitoring). Don't combine unrelated resources.
3. **No hardcoded values**: Everything configurable via variables. Sensible defaults in `variables.tf` `default` blocks.
4. **Versioned in source control**: Pin module versions: `source = "git::https://github.com/org/tf-modules.git//aks?ref=v2.3.0"` — prevents unexpected changes when the module is updated.
5. **Terraform Registry**: Public modules at `registry.terraform.io`. Use with version pinning: `source = "Azure/aks/azurerm"` + `version = "~> 7.0"`.

### Scenario-Based Questions

**Q: Your team has 5 product teams each deploying AKS clusters. How do you prevent each team from writing their own Terraform from scratch?**

Create a **Platform Module Library** — an internal Git repo of vetted, opinionated Terraform modules:

```
tf-platform-modules/
├── modules/
│   ├── aks-cluster/      # AKS with standard config, monitoring, RBAC
│   ├── networking/       # VNet, subnets, NSG, private DNS
│   ├── private-endpoint/ # Reusable private endpoint + DNS record
│   └── monitoring/       # Log Analytics, diagnostics, alerts
```

Each team references these modules at pinned versions. The platform team reviews + updates modules centrally. Teams get a "golden path" — they configure inputs, not Kubernetes internals.

Enforce via **policy** (Azure Policy / OPA Gatekeeper) that production clusters must come from the approved module at an approved minimum version.

---

## 4. Workspaces

### What are Terraform workspaces?

Workspaces allow multiple state files within the same Terraform configuration. Each workspace has an isolated state file.

```bash
terraform workspace new staging
terraform workspace select production
terraform workspace list
```

Inside `.tf` files: `terraform.workspace` returns the current workspace name — use it to vary resources per environment:

```hcl
variable "node_counts" {
  default = {
    staging    = 2
    production = 5
  }
}

resource "azurerm_kubernetes_cluster" "aks" {
  default_node_pool {
    node_count = var.node_counts[terraform.workspace]
  }
}
```

### When NOT to use workspaces

Workspaces are fine for small teams / simple environments. For enterprise use, prefer **separate state files per environment** in separate directories or separate backends. Reasons:
- Workspaces share the same provider/backend config — harder to enforce production requires MFA/approval
- IAM separation is harder — dev engineers shouldn't have write access to production state
- Separate directories make it obvious which environment you're in; workspace switching is easy to forget

---

## 5. Import and Existing Infrastructure

### How do you bring existing Azure resources under Terraform management?

```bash
# Import an existing AKS cluster into state
terraform import azurerm_kubernetes_cluster.aks \
  /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.ContainerService/managedClusters/<name>
```

This writes the resource to state but does **not** generate `.tf` code. You must write the matching resource block manually (or use `terraform state show` to see the attributes and replicate them).

**Terraform 1.5+ `import` block** (preferred): Write an import block in `.tf` — it's reviewable in PRs and idempotent:
```hcl
import {
  to = azurerm_kubernetes_cluster.aks
  id = "/subscriptions/.../managedClusters/prod-aks"
}
```

**`terraform plan -generate-config-out=generated.tf`**: Auto-generates the resource block from the imported state — saves manual work, but review carefully before committing.

---

## 6. Drift Detection and Drift Management

### What is Terraform drift?

Drift = gap between Terraform state and actual infrastructure. Causes:
- Manual changes in Azure portal
- Another tool modifying the same resource
- Azure auto-patching or auto-healing changing a property

### Detecting and handling drift

```bash
# Refresh state from real infrastructure, show diff
terraform plan -refresh-only

# Apply the refresh (update state to match reality, no resource changes)
terraform apply -refresh-only
```

**Drift in CI/CD**: Set up a scheduled pipeline (daily/weekly) that runs `terraform plan` and alerts on non-zero output. Tools like **Atlantis**, **Terraform Cloud**, or **env0** provide drift detection dashboards.

**Never run `terraform apply` to "fix" drift blindly** — understand why the drift occurred. If a human manually changed a resource for a good reason (e.g., incident response), the `.tf` code should be updated to match, not the resource reverted.

---

## 7. Terraform in CI/CD Pipelines

### Standard GitOps flow for Terraform

```
Developer → PR → GitHub/GitLab
  → CI: terraform fmt, terraform validate, tflint, tfsec
  → PR comment: terraform plan output (via Atlantis or GitHub Actions)
  → Reviewer approves plan + PR
  → Merge → CD: terraform apply (production)
```

### GitHub Actions example for Terraform

```yaml
jobs:
  terraform:
    steps:
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.7.0"

      - name: Init
        run: terraform init
        env:
          ARM_CLIENT_ID: ${{ secrets.ARM_CLIENT_ID }}
          ARM_CLIENT_SECRET: ${{ secrets.ARM_CLIENT_SECRET }}
          ARM_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
          ARM_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Plan
        run: terraform plan -out=tfplan

      - name: Apply  # Only on main branch merge
        if: github.ref == 'refs/heads/main'
        run: terraform apply tfplan
```

**Best practice**: Use **OIDC federation** instead of `ARM_CLIENT_SECRET` — GitHub Actions can request a token from Azure AD directly via OIDC, no secret to rotate:
```yaml
- uses: azure/login@v1
  with:
    client-id: ${{ vars.AZURE_CLIENT_ID }}
    tenant-id: ${{ vars.AZURE_TENANT_ID }}
    subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

### Scenario-Based Questions

**Q: Your Terraform CI pipeline runs `terraform plan` on every PR. A plan shows it will delete and recreate an AKS cluster (downtime). What do you do?**

1. **Do not merge**. Re-read the plan carefully — understand *why* Terraform wants to replace the resource.
2. Common reasons for replacement (`-/+`):
   - Changed an immutable property (e.g., `resource_group_name`, `location`, `os_disk_type` on node pool)
   - Changed a `ForceNew` attribute in the provider
3. Workarounds:
   - If the property shouldn't have changed: revert the accidental change in `.tf`
   - If intentional: use `create_before_destroy` lifecycle block + blue/green approach
   - If you must avoid downtime: use `lifecycle { prevent_destroy = true }` on critical resources as a guardrail, then plan the migration with node pool rotation
4. For AKS node pool changes: prefer adding a new node pool + draining the old one over in-place replacement.

**Q: A developer accidentally deleted the Terraform state file for production. How do you recover?**

1. **Remote backend (Azure Blob)**: Enable **versioning** on the storage container — recover the previous version of the `.tfstate` blob from version history. This is why you always use versioned remote state.
2. If state is unrecoverable: run `terraform import` for each resource to rebuild state from scratch. Start with the most critical resources. A CMDB or resource inventory helps.
3. With Terraform Cloud: state history is built-in and retained.
4. **Prevention**: Lock down state storage with RBAC (only CI/CD service principal can write), enable soft delete on the blob container, and alert on any manual state file changes.

---

## 8. Security Best Practices

### How do you manage secrets in Terraform?

**What NOT to do:**
```hcl
# Never hardcode secrets
resource "azurerm_postgresql_server" "db" {
  administrator_login_password = "MyPassword123!"  # BAD
}
```

**What to do:**

1. **Variables with sensitive flag** (keeps value out of plan output):
```hcl
variable "db_password" {
  type      = string
  sensitive = true
}
```
Pass value via env var: `TF_VAR_db_password=<value>` or CI/CD secret.

2. **Azure Key Vault data source** — fetch secret at plan time:
```hcl
data "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  key_vault_id = azurerm_key_vault.kv.id
}
```

3. **Never commit `.tfvars` files containing secrets to Git** — add `*.auto.tfvars` to `.gitignore`.

### tfsec and Checkov for policy-as-code

Run security scanning in CI before apply:
```bash
tfsec .                    # Static analysis for misconfigurations
checkov -d . --framework terraform  # Policy as code (CIS benchmarks)
```

These catch issues like: storage accounts with public access, AKS without RBAC, open NSG rules, unencrypted disks.

---

## 9. Terraform vs Pulumi vs Bicep — Quick Interview Comparison

| | Terraform | Pulumi | Azure Bicep |
|---|---|---|---|
| Language | HCL (declarative) | Python/TypeScript/Go | JSON superset |
| Multi-cloud | Yes | Yes | Azure only |
| State | External (file/backend) | Pulumi Service or self-managed | ARM (Azure manages) |
| Testing | `terraform test`, Terratest | Standard language test frameworks | Pester |
| Learning curve | Medium (HCL simple, state complex) | High (real code, debugging) | Low (Azure-native) |
| Best for | Multi-cloud, large platform teams | Developer-owned infra, complex logic | Azure-native shops |

**Senior answer**: "For multi-cloud or team-managed platform infra I use Terraform. For Azure-only shops where developers own their infra as code, Bicep removes the state management complexity. Pulumi when the infra logic is genuinely complex — loops, conditionals, existing libraries."

---

## 10. Quick-Fire Concepts

**What is `terraform taint` / `terraform apply -replace`?**  
Forces re-creation of a specific resource on the next apply. `taint` is deprecated — use `terraform apply -replace="azurerm_virtual_machine.vm"`.

**What is `depends_on`?**  
Explicit dependency when Terraform cannot infer it from references. Use sparingly — most dependencies are implicit through resource attribute references.

**What is `count` vs `for_each`?**  
- `count = 3` creates 3 copies addressed by index (count.index). Problem: inserting/deleting an element in the middle shifts all indices and causes unnecessary replacements.  
- `for_each = toset(["a","b","c"])` creates copies addressed by key. Safer for lists of named resources — adding/removing one key only affects that resource.

**What is `lifecycle { ignore_changes = [...] }`?**  
Tells Terraform to ignore drift on specific attributes. Useful when Azure auto-manages a field (e.g., `tags` auto-added by Azure Policy). Don't overuse — it hides real drift.

**What is a `data` source?**  
Reads existing infrastructure that Terraform didn't create. Example: reference an existing Key Vault or VNet without managing it:
```hcl
data "azurerm_virtual_network" "existing" {
  name                = "hub-vnet"
  resource_group_name = "hub-rg"
}
```
