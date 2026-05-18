# Azure Networking & Cloud Interview Guide

**Target Role:** Senior/Lead DevOps / Platform / MLOps Engineer  
**Background:** 12 years OpenShift/Kubernetes — translating on-prem networking mental models to Azure

---

## 1. Azure Virtual Network (VNet) Fundamentals

### What is a VNet and how does it map to on-prem concepts?

A VNet is Azure's software-defined network — an isolated network boundary in which your Azure resources communicate. Think of it as your own private datacenter network inside Azure.

| On-Prem Concept | Azure Equivalent |
|---|---|
| VLAN / L2 segment | Subnet inside a VNet |
| Firewall / ACL | Network Security Group (NSG) |
| BGP / OSPF route | User-Defined Route (UDR) / Route Table |
| MPLS / SD-WAN | ExpressRoute / VPN Gateway |
| DNS server | Azure Private DNS Zone |
| Load balancer | Azure Load Balancer / Application Gateway |

Key constraints:
- VNets are **regional** — one VNet cannot span regions
- Address spaces cannot overlap when peering
- Subnets divide a VNet's address space; each subnet can host one NSG

---

## 2. Network Security Groups (NSG)

### How do NSGs work at a senior level?

NSGs are stateful, layer-4 packet filters attached to either a **subnet** or a **network interface (NIC)**. Rules have priority (100–4096) — lower number wins.

**Effective Security Rules:** When an NSG is attached to both the subnet AND the NIC of the same VM, traffic must pass through both. The subnet NSG is evaluated first for inbound; the NIC NSG is evaluated first for outbound.

### Scenario-Based Questions

**Q: Your AKS cluster pods cannot reach an Azure SQL database in a peered VNet. NSG rules look correct. What do you check?**

1. Check **effective security rules** on the AKS node NIC — the portal shows the merged view of subnet + NIC NSGs.
2. Verify the peered VNet has **"Allow forwarded traffic"** and **"Allow gateway transit"** flags set if traffic crosses multiple hops.
3. Check if a **User-Defined Route** is sending traffic to an NVA (firewall) that is dropping it silently.
4. Check if the SQL server has a **Service Endpoint policy** or **Private Endpoint** — if Private Endpoint, traffic must route via the private IP, not the public FQDN.
5. Check **Azure Firewall / NVA logs** for deny entries.

**Q: You need to allow traffic from 300 specific IPs to an internal API. NSG rules cap at 1000 but you want maintainability. How do you solve this?**

Use **Application Security Groups (ASGs)**: tag source VMs/NICs with an ASG named `approved-clients`. Write one NSG rule referencing the ASG instead of individual IPs. Adding a new approved client = tag its NIC with the ASG, no NSG rule change needed.

Alternatively, define an **IP Group** in Azure Firewall and reference it in one policy rule.

---

## 3. Private DNS Zones

### What is Azure Private DNS and when do you use it?

Azure Private DNS zones let resources inside a VNet resolve custom FQDNs (e.g., `mydb.internal.corp`) to private IPs without DNS traffic leaving the Azure backbone.

**Key components:**
- **Private DNS Zone:** A DNS zone (e.g., `privatelink.blob.core.windows.net`) hosted by Azure
- **VNet Link:** Associates the zone with a VNet so VMs in that VNet can resolve it
- **Auto-registration:** Automatically creates A records for VMs when enabled on a VNet link

### How Private Endpoints and Private DNS work together

When you create a Private Endpoint for an Azure service (e.g., Azure Storage), Azure assigns it a private IP in your subnet. To resolve `mystorageaccount.blob.core.windows.net` to that private IP instead of the public IP, you must:

1. Create a Private DNS Zone named `privatelink.blob.core.windows.net`
2. Link it to your VNet
3. Add an A record: `mystorageaccount` → `10.1.2.5` (the private endpoint IP)

Azure does this automatically if you check "Integrate with private DNS zone" during Private Endpoint creation — but in Terraform/enterprise deployments you own this explicitly.

### Scenario-Based Questions

**Q: After deploying a Private Endpoint for Azure Key Vault, your AKS pods still resolve to the public IP. What is the issue?**

The pod is resolving through a DNS path that does not use the private zone. Typical causes:

1. **VNet link missing**: The private DNS zone `privatelink.vaultcore.azure.net` is not linked to the AKS VNet (or the VNet where the AKS node's DNS is configured).
2. **Custom DNS server**: AKS or the VNet uses a custom DNS server (e.g., on-prem via ExpressRoute). That server must forward `privatelink.*` queries to Azure DNS at `168.63.129.16` — otherwise it falls back to public DNS.
3. **DNS cache**: If using CoreDNS, the old public IP may be cached. Restart the CoreDNS pods or reduce TTL.
4. **Conditional forwarder missing**: In a hub-spoke model, add a conditional forwarder on the hub DNS resolver for `privatelink.vaultcore.azure.net` pointing to `168.63.129.16`.

Fix verification: `nslookup <vault-name>.vault.azure.net` from a pod should return `10.x.x.x`, not `20.x.x.x`.

**Q: You have a hub-spoke VNet topology. How do you set up Private DNS so all spokes resolve Private Endpoint names correctly?**

Centralized DNS pattern (recommended for enterprise):

```
Hub VNet
  └── Azure Private DNS Resolver (inbound endpoint: 10.0.0.4)
  └── DNS Forwarding Ruleset
        → privatelink.* → 168.63.129.16
        → internal.corp → on-prem DNS server

Spoke VNet DNS Settings:
  Custom DNS server = 10.0.0.4 (hub private resolver)
```

All spokes send DNS queries to the hub resolver. The resolver forwards privatelink queries to Azure's magic IP `168.63.129.16` which can resolve private zone records. Private DNS Zones are only linked to the hub VNet — spokes inherit resolution via the forwarding chain.

**Do NOT link private zones to every spoke** — this becomes unmanageable at scale.

---

## 4. Private Endpoints

### What is a Private Endpoint and how is it different from a Service Endpoint?

| | Service Endpoint | Private Endpoint |
|---|---|---|
| Traffic path | Optimized over Azure backbone, still exits VNet | Stays entirely within VNet via private IP |
| Firewall (Azure service side) | Service can restrict to specific VNets | Service can restrict to specific private endpoint IPs |
| DNS change needed | No — still resolves to public IP | Yes — must resolve to private IP |
| On-prem access | Cannot reach service via on-prem VPN/ER | Can reach via VPN/ExpressRoute (private IP is routable) |
| Cost | Free | Small hourly + data processing cost |

Senior guidance: **Always use Private Endpoints for regulated workloads** (PCI, HIPAA, SOC2). Service Endpoints are adequate for dev/test or where on-prem access is not needed.

### Scenario-Based Questions

**Q: Your Terraform plan creates Private Endpoints for 10 Azure services. Deployment succeeds but on-prem applications cannot reach the services. Why?**

On-prem to Private Endpoint requires two things:

1. **Route to private IP exists**: The private endpoint IP (e.g., `10.2.3.5`) must be reachable from on-prem. With ExpressRoute, the VNet routes are advertised via BGP — verify the private endpoint subnet route is being advertised. With VPN, ensure the VPN gateway knows this subnet.
2. **DNS resolution returns private IP on-prem**: On-prem DNS must forward privatelink queries to Azure DNS. Add a conditional forwarder on the on-prem DNS server: `privatelink.blob.core.windows.net → 168.63.129.16` (via the Azure DNS Resolver inbound endpoint).

Check: `nslookup mystorageaccount.blob.core.windows.net` from on-prem should return the private IP, not `20.xxx`.

---

## 5. ExpressRoute & VPN Gateway

### ExpressRoute vs VPN Gateway — when to use which?

| | ExpressRoute | VPN Gateway |
|---|---|---|
| Connection type | Private circuit via connectivity provider | IPsec/IKE tunnel over public internet |
| Bandwidth | Up to 100 Gbps | Up to 10 Gbps (VpnGw5AZ) |
| SLA | 99.95%+ (with redundant circuits) | 99.9% (Active-Active) |
| Latency | Low, predictable | Variable (internet) |
| Cost | High (circuit + gateway) | Lower |
| Use case | Production, regulated, high-throughput | Dev/test, small branch offices |

**ExpressRoute Global Reach**: Connects two on-prem locations through Azure's backbone (office A → Azure ER → office B) without using the public internet.

### Scenario-Based Questions

**Q: Your ExpressRoute circuit is up but AKS nodes cannot reach on-prem services. What is your troubleshooting flow?**

```
1. Is the BGP session up?
   az network express-route list-route-tables --path primary ...
   → Verify on-prem routes are in the Azure route table

2. Are UDRs overriding BGP?
   Check the subnet's effective routes — a UDR with destination 0.0.0.0/0 
   pointing to Azure Firewall may be sending traffic the wrong way

3. Is the VNet Gateway subnet NSG blocking BGP (TCP 179)?
   GatewaySubnet should have NO NSG — Microsoft requirement

4. Is the AKS node's subnet associated to the right route table?
   AKS creates its own subnets/route tables; verify the ER route 
   is visible in the node subnet's effective routes

5. Asymmetric routing?
   On-prem sends return traffic via a different path than Azure expected
   → Check on-prem firewall/router for asymmetric routing issues
```

---

## 6. Azure Firewall vs NSG vs NVA

### When do you use each?

| Component | Layer | Use Case |
|---|---|---|
| NSG | L4 (TCP/UDP/ICMP) | Micro-segmentation within/between subnets |
| Azure Firewall | L4 + L7 (FQDN, TLS inspection) | Centralized egress control, FQDN filtering |
| NVA (3rd party) | L3–L7 | Advanced inspection, compliance requirements for specific vendor |
| Application Gateway (WAF) | L7 | Inbound HTTP/HTTPS, WAF for web apps |

**Azure Firewall Policy vs Classic rules**: Always use **Firewall Policy** (the newer model) — it supports rule hierarchies (base policy + child policies per team/environment), IDPS, TLS inspection, and can be shared across multiple firewalls.

### Scenario-Based Questions

**Q: AKS pods have internet access you want to restrict. How do you implement egress control?**

1. Create an Azure Firewall in a hub VNet with a dedicated `AzureFirewallSubnet`
2. Create a **Route Table** attached to the AKS node subnet: `0.0.0.0/0 → Azure Firewall private IP`
3. In Azure Firewall Policy, create Application Rules allowing only required FQDNs (e.g., `*.ubuntu.com`, `mcr.microsoft.com`)
4. Add Network Rules for non-HTTP traffic (e.g., NTP `123/UDP`, DNS `53/UDP` to `168.63.129.16`)
5. AKS-specific: Microsoft publishes required AKS egress FQDNs — use the `AzureKubernetesService` FQDN tag in Application Rules to auto-include them

---

## 7. Load Balancing in Azure

### Choosing the right load balancer

| Service | Layer | Scope | Use Case |
|---|---|---|---|
| Azure Load Balancer | L4 | Regional | TCP/UDP LB for VMs, AKS internal/external |
| Application Gateway | L7 | Regional | HTTP/HTTPS, WAF, path-based routing, SSL offload |
| Azure Front Door | L7 | Global | Multi-region apps, CDN, WAF, failover |
| Traffic Manager | DNS | Global | DNS-based routing across regions (not a proxy) |

### Scenario-Based Questions

**Q: You have an AKS-hosted API that needs: SSL termination, WAF, path-based routing (/api → service A, /auth → service B), and multi-region failover. What Azure services do you use?**

- **Application Gateway** (with WAF tier) inside each region for SSL termination, WAF, and path-based routing
- **Azure Front Door Premium** as the global entry point — handles multi-region failover, global WAF, CDN
- AKS services are exposed as `ClusterIP`; the Application Gateway Ingress Controller (AGIC) programs the gateway directly from Kubernetes Ingress resources

Architecture:
```
User → Azure Front Door → (region A) Application Gateway + WAF
                       → (region B) Application Gateway + WAF (failover)
                AKS Ingress (AGIC) manages Application Gateway backend pools
```

---

## 8. Azure Kubernetes Service (AKS) Networking

### CNI options and when to use each

| Plugin | IP assignment | Use Case |
|---|---|---|
| Kubenet | Pods get NAT'd IPs; nodes get VNet IPs | Small clusters, IP-scarce VNets |
| Azure CNI | Each pod gets a real VNet IP | Production, Private Endpoints, policy, no NAT |
| Azure CNI Overlay | Pods get overlay IPs, nodes get VNet IPs | Large clusters; reduces VNet IP consumption |
| Cilium (Azure CNI + Cilium) | eBPF dataplane | Advanced policy, observability, high perf |

**Senior point**: With Azure CNI, pre-plan IP space carefully — each node reserves `(max_pods_per_node + 1)` IPs from the subnet. A 100-node cluster with 30 max pods = 3100 IPs reserved.

### Scenario-Based Questions

**Q: You need to enforce network policies between AKS namespaces (dev team cannot reach prod namespace). What is your approach?**

1. Enable **network policy** at cluster creation (cannot be added post-creation without rebuild): `--network-policy calico` or `--network-policy azure`
2. Deploy Kubernetes `NetworkPolicy` resources:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-cross-namespace
  namespace: prod
spec:
  podSelector: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: prod
  policyTypes:
    - Ingress
```
3. This denies all ingress to `prod` pods except from pods within the `prod` namespace itself.
4. For Cilium: use `CiliumNetworkPolicy` for L7 rules (HTTP method/path level).

---

## 9. Azure Cloud Scenarios (General)

### Scenario-Based Questions

**Q: You are migrating an on-prem OpenShift cluster to Azure. What are your first five architectural decisions?**

1. **Landing Zone**: Use Azure Landing Zone accelerator — separate subscriptions for identity, connectivity, and workloads. Don't put everything in one subscription.
2. **Connectivity**: ExpressRoute for production (latency, bandwidth), VPN as failover. Decide hub-spoke vs vWAN.
3. **AKS vs ARO**: Azure Red Hat OpenShift (ARO) gives you managed OpenShift with Red Hat support. AKS requires re-platforming workloads but gives more flexibility. ARO is preferred if OpenShift-specific APIs (Routes, DeploymentConfigs) are used.
4. **Identity**: Integrate AKS/ARO with Azure AD for RBAC. Use Workload Identity (federated OIDC) — not pod-level MSI or static service principals.
5. **Storage**: Map PV storage classes — on-prem Ceph/NFS → Azure Files (RWX) or Azure Disk (RWO). Azure Files for shared storage, Azure Disk for high-IOPS single-pod workloads.

**Q: Your AKS cluster in East US has an outage. How do you fail over to West US with minimal data loss?**

This requires active-passive or active-active multi-region design built in advance:

1. **Cluster**: Second AKS cluster in West US, deployed from the same IaC (Terraform). Cluster configs in Git.
2. **Workloads**: GitOps (Flux/ArgoCD) continuously syncs both clusters from the same Git repo. In passive mode, West US cluster has deployments running at 0 replicas or minimal.
3. **Data**: 
   - Azure SQL: Geo-replication with automatic failover group. Failover to West US replica.
   - Azure Storage / Cosmos DB: Geo-redundant replication enabled. Cosmos DB multi-region writes supported.
4. **Traffic**: Azure Front Door routes to East US. On outage, Front Door health probes detect failure and routes 100% to West US.
5. **DNS**: TTL on CNAME pointing to Front Door endpoint is low (60s) — failover is transparent.
6. **RTO/RPO**: With active-active, RPO ≈ 0 (Cosmos multi-write). With active-passive, RPO = replication lag (typically seconds for SQL geo-replication).

**Q: A developer says "my Azure resource needs to call Azure Key Vault but I don't want credentials in the code." How do you implement this?**

Use **Managed Identity** (specifically User-Assigned Managed Identity for portability):

1. Create a User-Assigned Managed Identity
2. Grant it `Key Vault Secrets User` role on the Key Vault
3. Assign the identity to the VM / App Service / AKS pod (via Workload Identity for AKS)
4. In code (Python): `DefaultAzureCredential()` automatically detects the managed identity — no credentials in code or environment variables

For AKS specifically (Workload Identity):
```yaml
# ServiceAccount in AKS annotated with the managed identity client ID
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: "<managed-identity-client-id>"
```
The pod uses a projected token (OIDC federation) to get an Azure AD token — no secrets mounted.

---

## 10. Quick-Fire Concepts (Common in Interviews)

**What is the Azure backbone / Microsoft Global Network?**  
A private fiber network connecting all Azure regions, PoPs, and edge nodes. Traffic between Azure resources and via ExpressRoute stays on this backbone, never touching the public internet.

**What is `168.63.129.16`?**  
A virtual public IP used by Azure's internal platform — it's the Azure DNS resolver address, the health probe source for Azure Load Balancer, and used by the Azure host agent. NSGs should never block this IP.

**What is a Route Table / UDR?**  
User-Defined Routes override Azure's default system routes. Commonly used to send all internet-bound traffic (`0.0.0.0/0`) through an Azure Firewall or NVA for inspection.

**What is VNet Peering vs VPN Gateway?**  
- VNet Peering: Low-latency, private connectivity between two VNets in the same or different regions. Traffic uses Azure backbone. Non-transitive (A↔B, B↔C does not give A↔C access unless Hub-Spoke with forwarding enabled).  
- VPN Gateway: IPsec tunnel — used for on-prem connectivity or as a transitive workaround (costly).

**What is Azure DDoS Protection?**  
- **Basic**: Free, always-on, protects Azure infrastructure. Does not give per-resource telemetry.  
- **Standard**: Applied to a VNet, gives per-resource dashboards, SLA, attack mitigation reports, and DDoS Rapid Response team access. Required for production public-facing workloads.
