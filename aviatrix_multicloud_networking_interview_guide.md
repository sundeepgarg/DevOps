# Aviatrix Multi-Cloud Networking Interview Guide

**Target Role:** Principal Platform Engineer / Cloud Network Engineer  
**Background:** ACE (Aviatrix Certified Engineer), multi-cloud networking at enterprise scale

---

## 1. Aviatrix Architecture

### The Single-Pane Problem Aviatrix Solves

Each cloud provider has its own networking primitives:
- AWS: VPC, Transit Gateway (TGW), VPC Peering, Route Tables
- Azure: VNet, VNet Peering, VPN Gateway, Route Tables, NSGs
- GCP: VPC, Shared VPC, Cloud Router, Cloud VPN

Managing multi-cloud networking natively means learning three different tools, three consoles, and writing three different IaC implementations. Aviatrix abstracts all of this into a single control plane.

### Core Components

```
Aviatrix Architecture:
│
├── Aviatrix Controller (1 per enterprise, any cloud)
│   ├── Single-pane management UI + API
│   ├── Orchestrates all gateway deployments via Terraform/API
│   └── Stores network topology, routing policies, segmentation rules
│
├── Aviatrix Gateways (1+ per VPC/VNet/VCN)
│   ├── Deployed as cloud VMs (t3.medium → c5n.4xlarge depending on throughput)
│   ├── Run Aviatrix software on top of cloud instances
│   ├── High Availability: always deploy in pairs (active + standby, same or different AZ)
│   └── Types: Transit GW, Spoke GW, Edge GW (for on-prem), CloudN (appliance)
│
└── CoPilot (separate SaaS component)
    ├── Topology visualisation (live multi-cloud network map)
    ├── FlightPath (packet trace across the full network path)
    ├── Network anomaly detection
    └── Cost analytics per VPC/VNet
```

---

## 2. Transit Architecture

### Hub-and-Spoke with Aviatrix Transit

```
Cloud A (AWS):
  Spoke VPC (Dev)    ←→  Transit VPC (AWS)  ←→  Spoke VPC (Prod)
                              ↕ BGP peering ↕
Cloud B (Azure):
  Spoke VNet (Data)  ←→  Transit VNet (Azure) ←→  Spoke VNet (ML Platform)
                              ↕ BGP peering ↕
On-Premises:
  Data Center        ←→  Edge Gateway / CloudN

All spokes communicate via Transit. No spoke-to-spoke direct peering.
```

### Transit Gateway Configuration

```hcl
# Terraform: Deploy Aviatrix Transit GW in Azure
resource "aviatrix_transit_gateway" "azure_transit" {
  cloud_type   = 8            # 8 = Azure
  account_name = "azure-prod"
  gw_name      = "transit-azure-eastus"
  vpc_id       = "platform-transit-vnet:eastus:sub-abc123"
  vpc_reg      = "eastus"
  gw_size      = "Standard_D3_v2"
  subnet       = "10.10.0.0/28"    # Must be a dedicated /28 for Aviatrix
  ha_subnet    = "10.10.0.16/28"   # HA gateway in secondary AZ
  ha_gw_size   = "Standard_D3_v2"
  connected_transit = true          # Enables full mesh between spokes via this transit
  bgp_ecmp = true                   # Load-balance over multiple BGP paths
}

# Attach a Spoke VNet to the Transit
resource "aviatrix_spoke_transit_attachment" "ml_platform_to_transit" {
  spoke_gw_name   = "spoke-ml-platform"
  transit_gw_name = "transit-azure-eastus"
}
```

### BGP and Route Advertisement

Aviatrix Transit Gateways run BGP:
- Spoke gateways advertise their VPC/VNet CIDR to the Transit over BGP
- Transit GWs peer with each other (over private encrypted tunnels) and exchange routes
- On-prem peering: Transit GW peers with the on-prem router via BGP over a Site2Cloud tunnel
- ECMP: multiple paths to the same destination → load balanced across all equal-cost paths

```bash
# View BGP route table (from Aviatrix Controller UI or API)
# Controller → Diagnostics → Gateway → select gateway → BGP Info
# Shows: neighbors, advertised routes, received routes, BGP state
```

---

## 3. Network Domains and Connection Policies

### The Segmentation Model

Native cloud networking segmentation = complex route table manipulation.
Aviatrix Network Domains = logical labels that replace route table management.

```
Network Domain: "Production"
  Spoke: ml-platform-vnet (Azure)
  Spoke: inference-vpc (AWS us-east)

Network Domain: "Development"
  Spoke: dev-vnet (Azure)
  Spoke: dev-vpc (AWS)

Network Domain: "Shared Services"
  Spoke: dns-vnet
  Spoke: monitoring-vnet
  Spoke: vault-vpc

Connection Policies:
  Production ↔ Shared Services    (ALLOW)
  Development ↔ Shared Services   (ALLOW)
  Production ↔ Development        (DENY)   ← Segmentation enforced here
```

Without Aviatrix: to prevent Prod↔Dev traffic, you'd need to manipulate route tables in every VPC/VNet and maintain them as the network grows. With Aviatrix: toggle a checkbox in Connection Policy.

```hcl
# Terraform: Define network domains and connection policy
resource "aviatrix_segmentation_security_domain" "production" {
  domain_name = "production"
}

resource "aviatrix_segmentation_security_domain" "development" {
  domain_name = "development"
}

resource "aviatrix_segmentation_security_domain_connection_policy" "prod_to_shared" {
  domain_name_1 = "production"
  domain_name_2 = "shared-services"
}
# No policy between production and development = no connectivity (default deny)
```

---

## 4. Aviatrix vs Native Cloud Networking

### Comparison Table

| Feature | Aviatrix | AWS TGW | Azure VNet Peering | Azure VPN GW |
|---------|----------|---------|-------------------|--------------|
| Multi-cloud | Yes | AWS only | Azure only | Azure only |
| Network segmentation | Domain + policy model | Route tables (complex) | No native segmentation | No |
| BGP dynamic routing | Yes | Yes (with attach) | No | Yes (limited) |
| Packet-level visibility | FlightPath | VPC Flow Logs (limited) | NSG Flow Logs | No |
| Bandwidth limit | GW instance size (up to 25Gbps) | 50Gbps (aggregate) | Up to 10Gbps | 10Gbps |
| Encryption in transit | Always (AES-256 GRE tunnels) | Optional (MACsec for Direct Connect) | No (requires VPN on top) | Yes |
| Egress FQDN filtering | Yes | Via AWS Network Firewall | Via Azure Firewall | No |
| Cost (simple 2-VPC) | Higher (GW VMs + controller) | Lower (TGW + attachments) | Lowest (peering free) | Medium |
| Complexity at scale | Lower (policy model) | High (many route tables) | Very high | Medium |

**When to choose Aviatrix**:
- Multi-cloud (AWS + Azure + GCP) with uniform security policy
- Need packet-level troubleshooting (FlightPath)
- Need encryption for all inter-VPC traffic (compliance requirement)
- > 50 VPCs/VNets (policy model scales better than route tables)

**When to use native**:
- Single cloud, simple topology (< 10 VPCs)
- Cost sensitivity (Aviatrix GW VMs add $200-1000/month per VPC)
- Team already expert in native constructs

---

## 5. FlightPath — Network Troubleshooting

FlightPath traces a packet's path through the entire network, layer by layer:

```
FlightPath trace: source=10.10.5.100 → destination=10.20.5.100

Layer 1: Source EC2/VM
  ✓ Source VM: running, network interface up
  ✓ Security Group (SG) / NSG: outbound rule allows TCP:443

Layer 2: Source Spoke Gateway  
  ✓ Spoke GW: 10.10.5.100 is in spoke's CIDR
  ✓ Route to Transit: 10.20.0.0/16 via Transit GW

Layer 3: Transit Gateway
  ✓ BGP route for 10.20.5.100 received from Azure Transit
  ✓ Tunnel to Azure Transit: UP (tunnel health: green)

Layer 4: Destination Transit Gateway
  ✓ Received packet from AWS Transit
  ✗ Route to 10.20.5.100 NOT FOUND in Transit routing table
  → Destination spoke not attached to this Transit
  → Missing: spoke attachment for vnet-ml-platform

ROOT CAUSE: vnet-ml-platform spoke is not attached to the Azure Transit GW
FIX: aviatrix_spoke_transit_attachment resource missing
```

This is **far faster** than checking 5 different console pages (Route Tables, BGP tables, tunnel status, Security Groups, Flow Logs).

```bash
# FlightPath via API
curl -X POST "https://<controller>/v1/api" \
  -d "action=get_flightpath_summary&CID=$CID&src_ip=10.10.5.100&dst_ip=10.20.5.100&protocol=tcp&port=443"
```

---

## 6. FQDN Egress Filtering

Problem: cloud workloads should only egress to approved internet destinations. Blocking by IP is impractical (CDNs change IPs constantly).

Aviatrix FQDN Gateway: a Spoke GW with DNS-based outbound filtering.

```hcl
# Allow specific FQDNs (allowlist mode)
resource "aviatrix_fqdn" "ml_platform_egress" {
  fqdn_tag     = "ml-platform-allowed"
  fqdn_enabled = true
  fqdn_mode    = "white"    # allowlist — block everything not listed

  gw_filter_tag_list {
    gw_name = "spoke-ml-platform"
  }

  domain_names {
    fqdn   = "*.huggingface.co"   # Model downloads
    proto  = "https"
    port   = "443"
    action = "Allow"
  }
  domain_names {
    fqdn   = "*.pypi.org"          # Python packages
    proto  = "https"
    port   = "443"
    action = "Allow"
  }
  domain_names {
    fqdn   = "pypi.python.org"
    proto  = "https"
    port   = "443"
    action = "Allow"
  }
}
```

**How it works**: Aviatrix FQDN GW acts as a transparent HTTP/HTTPS proxy. It intercepts DNS queries, resolves FQDNs to IPs, and allows/denies based on the FQDN tag. SNI inspection for HTTPS (no decryption — inspects the TLS SNI header only).

---

## 7. Site2Cloud — On-Premises Connectivity

Site2Cloud creates IPsec VPN tunnels between an Aviatrix GW and on-prem routers.

```hcl
resource "aviatrix_site2cloud" "on_prem_connection" {
  vpc_id                     = "platform-transit-vnet:eastus:sub-abc"
  connection_name            = "corpnet-to-azure-transit"
  connection_type            = "mapped"        # or "unmapped" for simple BGP
  remote_gateway_type        = "generic"       # or: aws, azure, paloalto, etc.
  tunnel_type                = "route"         # policy-based or route-based
  primary_cloud_gateway_name = "transit-azure-eastus"

  # On-premises router details
  remote_gateway_ip          = "203.0.113.10"  # On-prem router public IP
  pre_shared_key             = "ChangeMe123!"  # Use Vault for this in production

  # Routes to advertise to on-prem
  remote_subnet_cidr         = "192.168.0.0/16"  # On-prem CIDR
  local_subnet_cidr          = "10.0.0.0/8"      # Cloud CIDRs

  # BGP for dynamic routing
  bgp_manual_spoke_advertise_cidrs = "10.10.0.0/16,10.20.0.0/16"
}
```

**BGP over Site2Cloud**: for production use BGP (not static routes). On-prem router advertises its subnets; Aviatrix Transit advertises cloud subnets. Route failover happens automatically when paths change.

---

## 8. CoPilot

CoPilot is Aviatrix's network observability plane:

| Feature | What It Shows |
|---------|---------------|
| Topology Map | Live multi-cloud network graph with traffic flows |
| FlightPath | Step-by-step packet trace (see Section 5) |
| ThreatIQ | Anomalous traffic patterns, geo-based anomalies |
| FlowIQ | Per-flow traffic analytics, top talkers, port usage |
| Cost Analysis | Egress costs per VPC, per region, per destination |
| BGP | BGP state, route tables, AS path per gateway |

```bash
# CoPilot topology API example
curl "https://copilot.aviatrix.com/api/topology" \
  -H "Authorization: Bearer $COPILOT_TOKEN" \
  | jq '.nodes[] | {name: .name, type: .type, cloud: .cloud, status: .status}'
```

---

## 9. Aviatrix on Azure — Key Details

### VNET Injection

Aviatrix Transit and Spoke GWs are injected into existing VNets (your VNets, not managed VNets):

```
Azure subscription:
  platform-transit-vnet (10.10.0.0/16)
    ├── aviatrix-gw-subnet (10.10.0.0/28)     ← Transit GW deployed here
    ├── aviatrix-gw-ha-subnet (10.10.0.16/28) ← HA Transit GW
    └── ... other subnets (your workloads)

  ml-platform-vnet (10.20.0.0/16)
    ├── aviatrix-gw-subnet (10.20.0.0/28)     ← Spoke GW deployed here
    └── ... your workloads
```

The dedicated `/28` subnet for Aviatrix is a hard requirement — always reserve these when creating VNets in Aviatrix environments.

### UDR (User Defined Routes) in Azure

Aviatrix automatically programs Azure UDRs to route traffic through Aviatrix GWs:
```
Route table on ml-platform-vnet/workload-subnet:
  10.0.0.0/8  →  spoke-gw-private-IP   (all RFC1918 through Aviatrix)
  0.0.0.0/0   →  fqdn-gw-private-IP    (internet through FQDN filter)
```

Never manually edit these UDRs — Aviatrix manages them. Manual edits get overwritten by Aviatrix on the next controller sync.

---

## 10. Scenario-Based Interview Questions

**Q: Cross-cloud traffic from an AWS VPC to an Azure VNet is failing. How do you debug with Aviatrix?**

1. **CoPilot topology**: open the live network map. Are the AWS Spoke GW and Azure Spoke GW both green (connected to their respective Transits)?
2. **FlightPath**: source=AWS instance IP, destination=Azure instance IP, TCP port 443. Run it.
   - If FlightPath shows the packet stops at the AWS Transit (no route to Azure): the AWS-Azure Transit peering is broken.
   - If packet stops at the Azure Spoke GW: the Spoke isn't attached to the Azure Transit.
3. **Check Transit peering**: Aviatrix Controller → Multi-Cloud Transit → Transit Peering. Is the AWS-to-Azure peering showing "Up"?
4. **Check BGP**: Controller → Diagnostics → Gateway → select AWS Transit → BGP Info. Is the Azure Transit's CIDR in the BGP route table?
5. **Common fix**: tunnel between AWS and Azure Transits went down due to cloud provider maintenance. Aviatrix auto-recovers tunnels; wait 60 seconds or restart the peering from Controller.
6. **Security group / NSG**: even if Aviatrix routing is correct, AWS SG or Azure NSG may block the port. Check both endpoints with FlightPath's Layer 1 check.

**Q: A new spoke VNet was added to Azure but can't reach on-premises. What do you check?**

Route for the new spoke to propagate to on-prem takes a specific configuration:

1. **Spoke attached to Transit?**: `aviatrix_spoke_transit_attachment` resource created for the new spoke?
2. **Network Domain assigned?**: If using segmentation, the new spoke must be added to a Network Domain that has a Connection Policy to the "On-Premises" domain.
3. **On-prem BGP route propagation**: Aviatrix Transit advertises the spoke's CIDR to on-prem via BGP. Run FlightPath to see if the route exists in the Transit's BGP table.
4. **On-prem route filter**: some on-prem routers have inbound route filters. Verify the on-prem BGP neighbor accepts the new CIDR.
5. **UDR on spoke subnets**: check that Aviatrix has programmed a UDR on the new spoke's subnets pointing to the Spoke GW for on-prem CIDRs.
6. **Aviatrix Controller**: check if there are any pending tasks or errors in the audit log after the spoke attachment.

**Q: Why would you choose Aviatrix over building the same connectivity with native Azure VPN Gateway?**

For 3-5 VNets in a single cloud: Azure VPN Gateway is simpler and cheaper.
For 20+ VNets across AWS and Azure with compliance requirements:

| Consideration | Aviatrix | Azure VPN Gateway |
|---------------|----------|------------------|
| Multi-cloud routing | Unified policy | Azure only |
| Troubleshooting | FlightPath traces full path in 30s | Hours of Flow Log analysis |
| Segmentation | Network Domains (click, no routing changes) | Complex Route Table manipulation |
| Encryption | Always on between all VPCs | Must configure each pair separately |
| Compliance | AES-256 on all paths, auditable | Depends on configuration |
| Scale | 1 Controller manages all | Multiple GWs, separate management |

At an ACE level, the answer is: Aviatrix is justified when the operational savings (faster troubleshooting, policy-based segmentation, multi-cloud uniformity) outweigh the GW VM costs. For a 2-cloud, 20+ VPC enterprise with compliance requirements (encrypted transit, FQDN egress filtering), the ROI is clear.

**Q: Aviatrix Transit Gateway is showing BGP session down to on-premises. How do you recover?**

1. **CoPilot → Site2Cloud**: check the tunnel status. Is the IPsec tunnel up or down?
2. If IPsec tunnel is down: check on-prem firewall for IKE (UDP 500, 4500) and ESP (IP protocol 50) traffic. Aviatrix GW's public IP must be reachable from on-prem.
3. If IPsec tunnel is up but BGP is down: BGP uses TCP 179 over the IPsec tunnel. Check:
   - On-prem router: `show bgp summary` → is the Aviatrix GW IP showing as the neighbor?
   - AS numbers: Aviatrix uses AS 65000 by default; confirm the on-prem router is configured with the right remote AS.
   - BGP keepalive timers: mismatch causes session to drop.
4. **Aviatrix Controller → Diagnostics → Gateway → select Transit → BGP Info**: shows current BGP neighbors and state.
5. **Quick recovery**: from the Controller, trigger a BGP reset: `reset bgp` for the affected neighbor.
6. **Root cause**: BGP sessions drop due to TCP keepalive timeout (30-second hold timer). If on-prem router rebooted or the IPsec tunnel flapped, BGP needs to re-establish. Aviatrix should auto-recover within 90 seconds; if not, manual reset.

**Q: A developer asks why traffic from the ML platform VNet to a PyPI server is being blocked. You have FQDN filtering enabled.**

1. Check if `pypi.org` and `pypi.python.org` are in the FQDN allowlist for the ML platform spoke:
   ```bash
   # Controller → Security → FQDN → check the tag applied to spoke-ml-platform
   ```
2. Note: PyPI uses multiple FQDNs — `pypi.org`, `pypi.python.org`, `files.pythonhosted.org`. All three must be in the allowlist.
3. **Test**: from the ML platform VM: `curl -I https://pypi.org/simple/` — does it succeed after adding the FQDN?
4. **FQDN log**: Controller → Security → FQDN → Logs — shows which FQDNs were blocked and which were allowed. Find `files.pythonhosted.org` in the deny log.
5. **Fix**: add `files.pythonhosted.org`, `pypi.org`, `pypi.python.org` to the allowlist.
6. **Better practice**: create a named tag "python-package-managers" with all PyPI + pip + conda related FQDNs, and apply it as a reusable tag to all development and ML spoke GWs.

**Q: How does Aviatrix handle high availability (HA) for gateways?**

Every Aviatrix Gateway deployed in production should have an HA pair:

```
Primary GW: transit-azure-eastus        (AZ: eastus-1)
HA GW:      transit-azure-eastus-hagw   (AZ: eastus-2)

BGP: both GWs advertise the same routes (ECMP — traffic load-balanced)
Failover: if primary goes down, HA GW takes over within 60 seconds
  - IPsec tunnels re-established on HA GW
  - BGP sessions reconverge
  - Azure UDRs updated to point to HA GW's IP
```

For Spoke GWs:
- `ha_subnet` configured → Aviatrix deploys an HA Spoke GW automatically
- Traffic load-balanced between Primary and HA Spoke GWs (ECMP)
- Failover: < 60 seconds (BGP reconvergence)

Without HA: single GW failure = complete loss of connectivity for all workloads in that VPC/VNet. Always deploy HA in production.
