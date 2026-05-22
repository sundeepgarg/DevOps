# Kubernetes Networking Deep Dive Interview Guide

**Target Role:** Senior/Principal Platform Engineer — CKA level  
**Resume Anchor:** 8 years Kubernetes/OpenShift, CKA certified, OVN-Kubernetes at Voya/IBM

---

## Kubernetes Networking Model

```
Fundamental Requirements (Kubernetes networking contract):
  1. Every pod gets a unique IP address
  2. Pods on the same node can communicate without NAT
  3. Pods on different nodes can communicate without NAT
  4. The IP a pod sees for itself = the IP other pods see for it
     (no SNAT for pod-to-pod traffic)

How this is implemented:
  CNI plugin creates a network namespace per pod
  Assigns pod IP from the node's CIDR (e.g., 10.244.1.0/24)
  Programs routes so nodes can reach each other's pod CIDRs
```

---

## 1. Pod Networking Internals

```
Pod Network Namespace:
┌──────────────────────────────────────────────────────────┐
│  Node (Linux Host)                                       │
│                                                          │
│  ┌────────────────────┐  ┌────────────────────┐         │
│  │  Pod A             │  │  Pod B             │         │
│  │  netns: ns-abc     │  │  netns: ns-def     │         │
│  │  IP: 10.244.1.5    │  │  IP: 10.244.1.6    │         │
│  │  eth0              │  │  eth0              │         │
│  └────────┬───────────┘  └────────┬───────────┘         │
│           │ veth pair             │ veth pair             │
│      veth-abc                veth-def                    │
│           │                       │                       │
│  ┌────────▼───────────────────────▼───────────────────┐  │
│  │  Linux Bridge (cbr0) or OVS switch                 │  │
│  │  IP: 10.244.1.1/24 (gateway for pods on this node) │  │
│  └────────────────────────────────────────────────────┘  │
│           │                                               │
│      eth0 (node interface, e.g., 192.168.1.10)           │
└──────────────────────────────────────────────────────────┘

Inter-node pod traffic:
  Pod A (10.244.1.5) → Node A bridge → Node A eth0
  → Encapsulation (VXLAN/GRE) or route-based
  → Node B eth0 → Node B bridge → Pod B (10.244.2.7)
```

### CNI Plugin Comparison

| CNI | Mode | Performance | Features | OpenShift |
|-----|------|-------------|----------|-----------|
| **Flannel** | VXLAN overlay | Medium | Simple, basic | No |
| **Calico** | BGP or VXLAN | High | NetworkPolicy, eBPF option | Yes |
| **Cilium** | eBPF | Highest | L7 policy, Hubble observability | Yes (OpenShift 4.12+) |
| **OVN-K8s** | OVS+OVN | High | Full NetworkPolicy, EgressIP | OCP default |
| **Azure CNI** | Native VNet | High | Pod gets VNet IP | AKS default |
| **Weave** | Mesh overlay | Medium | Encryption built-in | Rare |

---

## 2. Services Deep Dive

### Service Types

```
ClusterIP (default):
  Virtual IP only reachable inside the cluster
  kube-proxy programs iptables/IPVS rules to load-balance to pod IPs
  
NodePort:
  Exposes port on EVERY node (30000-32767 range)
  client → NodeIP:NodePort → kube-proxy → pod
  Limitation: exposes on all nodes, security concern
  
LoadBalancer:
  Creates a cloud LB (AWS ALB/NLB, Azure LB) pointing to NodePorts
  Gets an external IP
  
ExternalName:
  DNS CNAME record → external DNS name
  No proxying, pure DNS mapping
  Use: abstract external services (migrate legacy endpoints)
  
Headless (ClusterIP: None):
  No virtual IP
  DNS returns pod IPs directly
  Use: StatefulSets (clients connect to specific pod), service discovery
```

### kube-proxy Modes

```
iptables mode (default on most clusters):
  kube-proxy adds iptables rules for each Service/Endpoint
  Traffic randomly distributed (no connection tracking)
  Scales OK up to ~10K services
  
IPVS mode (better for large clusters):
  Uses Linux IPVS (IP Virtual Server) kernel module
  Hash-based lookup O(1) vs iptables O(n)
  More scheduling algorithms (round-robin, least-conn, SH)
  Scales to 100K+ services
  
eBPF mode (Cilium):
  Bypasses iptables/IPVS entirely
  Programs kernel with BPF programs
  ~50% lower latency, much lower overhead
  Best performance but requires Cilium

# Check current mode
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode
```

### Service DNS Resolution

```
DNS pattern: <service>.<namespace>.svc.cluster.local
  
  # Full name (works from any namespace)
  inference-service.ml-platform.svc.cluster.local
  
  # Short name (works within same namespace)
  inference-service
  
  # Cross-namespace (works from any namespace)
  inference-service.ml-platform
  
  # Pod DNS (rarely used)
  pod-ip-dashes.namespace.pod.cluster.local
  10-244-1-5.ml-platform.pod.cluster.local

CoreDNS:
  - Runs as Deployment in kube-system
  - All pods configured to use CoreDNS as resolver (via /etc/resolv.conf)
  - search: ml-platform.svc.cluster.local svc.cluster.local cluster.local
  - ndots:5 → names with < 5 dots go to DNS server first (avoid extra lookups with FQDN)
```

---

## 3. NetworkPolicy — Kubernetes Firewall

### Default Behaviour Without NetworkPolicy

```
No NetworkPolicy = no restrictions:
  Any pod in any namespace can talk to any other pod
  Any pod can reach the internet

With NetworkPolicy:
  A policy selects pods via podSelector
  Specifies allowed ingress (inbound) and/or egress (outbound)
  Unlisted traffic = denied (additive model: all matching policies are combined)
```

### NetworkPolicy Patterns

```yaml
# 1. Default deny all (baseline — apply first, then add allow rules)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: ml-platform
spec:
  podSelector: {}       # matches ALL pods in namespace
  policyTypes:
    - Ingress
    - Egress
  # No ingress or egress rules = deny all traffic both ways

---
# 2. Allow specific namespace to reach inference API
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-inference
  namespace: ml-platform
spec:
  podSelector:
    matchLabels:
      app: inference-api              # applies to inference pods
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: frontend   # only from frontend namespace
          podSelector:
            matchLabels:
              app: web-app            # AND only from web-app pods
      ports:
        - port: 8080
          protocol: TCP

---
# 3. Allow egress only to specific services (data sovereignty)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: restrict-llm-egress
  namespace: ml-platform
spec:
  podSelector:
    matchLabels:
      app: llm-inference              # restrict LLM pods
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: vector-store       # can reach vector store
    - ports:
        - port: 443                   # DNS over HTTPS allowed
        - port: 53
          protocol: UDP               # DNS allowed
    # Everything else: DENIED (no internet, no other pods)

---
# 4. Allow access to external service by IP block
spec:
  egress:
    - to:
        - ipBlock:
            cidr: 10.0.5.10/32        # specific private endpoint IP
      ports:
        - port: 5432                  # PostgreSQL
```

### NetworkPolicy Debugging

```bash
# NetworkPolicy doesn't work? Verify CNI supports it:
# Flannel alone: NO NetworkPolicy support (need Calico on top)
# Calico, Cilium, OVN-K: YES

# Test connectivity
kubectl exec -it debug-pod -n ml-platform -- nc -zv inference-api 8080
# "Connection refused" = port wrong or app not listening
# "Connection timed out" = NetworkPolicy blocking

# Cilium: visualise policy decisions
cilium monitor --type drop  # shows dropped packets with reason

# OVN-K (OpenShift): check OVN flow tables
kubectl exec -n ovn-kubernetes ovnkube-node-XXX -- ovn-nbctl show
```

---

## 4. Ingress Deep Dive

### Ingress Architecture

```
Client Request
       │
┌──────▼──────────────────────────────────────────────────────┐
│  Ingress Controller (NGINX, HAProxy, Traefik, AWS ALB, etc.)│
│  - Watches Ingress resources via API                         │
│  - Reconfigures itself when Ingress changes                  │
│  - Handles TLS termination                                   │
│  - Exposes as Service type=LoadBalancer                      │
└──────┬──────────────────────────────────────────────────────┘
       │ routes based on host + path rules
       │
┌──────▼──────────────────────────────────────────────────────┐
│  Ingress Resource (defines routing rules)                   │
│  apiVersion: networking.k8s.io/v1                           │
│  kind: Ingress                                              │
│                                                             │
│  rules:                                                     │
│    - host: inference.company.com                            │
│      http:                                                  │
│        paths:                                               │
│          - path: /predict                                   │
│            backend: inference-service:8080                  │
│          - path: /health                                    │
│            backend: inference-service:8080                  │
│    - host: mlflow.company.com                               │
│      http:                                                  │
│        paths:                                               │
│          - path: /                                          │
│            backend: mlflow-service:5000                     │
└─────────────────────────────────────────────────────────────┘
```

```yaml
# Full Ingress with TLS (cert-manager annotation)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: inference-ingress
  namespace: ml-platform
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: vault-pki-issuer
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"    # long for LLM streaming
    nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
    nginx.ingress.kubernetes.io/configuration-snippet: |
      add_header X-Frame-Options DENY;
      add_header X-Content-Type-Options nosniff;
spec:
  tls:
    - hosts:
        - inference.company.com
      secretName: inference-tls         # cert-manager creates this
  rules:
    - host: inference.company.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: inference-service
                port:
                  number: 8080
```

---

## 5. DNS Troubleshooting

```bash
# Common DNS issues in K8s:

# 1. Check CoreDNS is running
kubectl get pods -n kube-system -l k8s-app=kube-dns

# 2. Test DNS resolution from a pod
kubectl run debug --image=busybox --rm -it --restart=Never -- nslookup inference-service.ml-platform.svc.cluster.local

# 3. Check pod's /etc/resolv.conf
kubectl exec -it <pod> -- cat /etc/resolv.conf
# Should show: nameserver 10.96.0.10 (ClusterIP of kube-dns service)
# search: ml-platform.svc.cluster.local svc.cluster.local cluster.local

# 4. CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50

# 5. DNS loop fix (common in certain environments)
# CoreDNS forwarding to itself — check Corefile:
kubectl get configmap coredns -n kube-system -o yaml
# forward . /etc/resolv.conf should NOT point to the pod's own IP

# 6. ndots problem: short names doing extra DNS lookups
# Use FQDN with trailing dot to bypass search:
curl http://inference-service.ml-platform.svc.cluster.local./predict
```

---

## 6. Pod-to-Pod Traffic Flow (Cross-Node)

### With VXLAN Overlay (Flannel/Weave)

```
Pod A (10.244.1.5) on Node 1 → Pod B (10.244.2.7) on Node 2

1. Pod A sends packet: src=10.244.1.5 dst=10.244.2.7
2. Kernel: route for 10.244.2.0/24 → vxlan0 interface (flannel)
3. Flannel encapsulates: outer src=192.168.1.10 (Node1) dst=192.168.1.20 (Node2) port=4789 (VXLAN)
4. Physical network routes 192.168.1.10 → 192.168.1.20
5. Node 2 decapsulates: inner packet dst=10.244.2.7
6. Kernel route: 10.244.2.0/24 → cbr0 bridge
7. Bridge forwards to Pod B

Overhead: 50 bytes per packet (VXLAN header)
Use case: cloud environments where BGP not available
```

### With BGP (Calico)

```
No encapsulation — Calico programs BGP routes on each node
Node 1 advertises: 10.244.1.0/24 via 192.168.1.10
Node 2 advertises: 10.244.2.0/24 via 192.168.1.20

Pod A → Pod B:
1. Pod A sends: src=10.244.1.5 dst=10.244.2.7
2. Kernel route: 10.244.2.0/24 via 192.168.1.20 (from BGP)
3. Packet sent directly, no encapsulation overhead
4. Node 2 receives, routes to Pod B

Benefit: wire-speed performance, same as regular routing
Requirement: all nodes must be BGP peers (or use BGP peer with top-of-rack switch)
```

---

## 7. Advanced Topics

### Endpoint Slices (Replace Endpoints)

```
Classic Endpoints: one object per Service, lists ALL pod IPs
  Problem: Service with 1000 pods → 1000-entry Endpoints object
  Update: any pod churn → full Endpoints object rewritten → API server load

EndpointSlice (K8s 1.21+ default):
  Multiple slices per Service, each max 100 endpoints
  Only affected slices updated on pod churn
  Dramatically reduces API server and kube-proxy load for large services
```

### ExternalDNS — Automatic DNS Records

```
ExternalDNS watches Services and Ingresses
Creates DNS records in Route53/Azure DNS/CloudFlare automatically

# Annotate a LoadBalancer Service:
annotations:
  external-dns.alpha.kubernetes.io/hostname: inference.company.com

ExternalDNS creates: inference.company.com → <LB IP>
When pod scales: no action needed, LB handles it
When Service deleted: ExternalDNS deletes the DNS record
```

---

## 8. Interview Questions

**Q: A pod can reach services in its own namespace but not in another namespace. What do you check?**

1. **NetworkPolicy**: most likely cause. Check if the target namespace has a NetworkPolicy that restricts ingress:
   ```bash
   kubectl get networkpolicies -n target-namespace
   kubectl describe networkpolicy <name> -n target-namespace
   ```
2. **DNS**: verify the short name resolves. Use FQDN: `service.namespace.svc.cluster.local`.
3. **Service exists**: `kubectl get svc -n target-namespace` — is the service actually there?
4. **Endpoints**: `kubectl get endpoints -n target-namespace` — are pods behind the service?
5. **RBAC**: if using `kubectl exec` to test, your kubectl user needs access to that namespace. The pod's service account is different — networking issues are about network, not RBAC.

**Q: Explain how a LoadBalancer Service creates an external IP on Azure (AKS).**

When you create a Service with `type: LoadBalancer` on AKS:
1. The kube-controller-manager calls the Azure cloud provider.
2. Azure cloud provider creates an Azure Load Balancer and Public IP (or internal IP if `service.beta.kubernetes.io/azure-load-balancer-internal: "true"`).
3. The LB has backend rules pointing to the NodePort on every worker node.
4. Azure updates the Service's `status.loadBalancer.ingress[0].ip` with the public IP.
5. External DNS can now watch this and create `myservice.company.com → public IP`.

Traffic path: `client → Azure LB (public IP) → Node (NodePort) → kube-proxy → pod`.

For AKS with Azure CNI: can use `externalTrafficPolicy: Local` — traffic only goes to nodes that have the target pod. This preserves source IP (not SNATted) and avoids extra hop.

**Q: What is the difference between Ingress and Gateway API?**

**Ingress** (stable, original): Simple routing — host + path → Service. Limited: can't express TCP routing, weighted splits, header-based routing without custom annotations (vendor-specific, not portable).

**Gateway API** (newer standard, now GA): Role-based model:
- `GatewayClass`: defines the controller (nginx, Istio, etc.)
- `Gateway`: infrastructure — ports, protocols, TLS
- `HTTPRoute` / `TCPRoute` / `GRPCRoute`: traffic rules (portable, no annotations needed)

```yaml
# Gateway API HTTPRoute (portable, expressive)
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
spec:
  rules:
    - matches:
        - headers:
            - name: "X-User-Tier"
              value: "premium"
      backendRefs:
        - name: inference-premium-svc
          weight: 100
    - backendRefs:
        - name: inference-standard-svc
          weight: 100
```

Istio supports Gateway API natively. OpenShift Routes are a separate OpenShift-specific construct (similar to Ingress but with more TLS options).

**Q: How does Cilium's eBPF networking differ from iptables-based CNIs?**

iptables (kube-proxy + traditional CNIs):
- Every Service creates O(N) iptables rules (one per endpoint)
- Rules evaluated sequentially — O(N) lookup per packet
- Modifying iptables requires locking (can block traffic briefly at large scale)
- Limited observability — only raw iptables counters

Cilium eBPF:
- BPF programs attached to kernel network hooks (XDP, TC)
- Hash-based lookup O(1) per packet regardless of Service count
- Bypasses iptables entirely
- Hubble: L7 observability (HTTP paths, DNS queries, gRPC) with no application changes
- Network policies enforced at the BPF level — 10x faster than iptables

Real numbers (Cilium benchmark):
- 10K Services: iptables 10ms connection setup vs Cilium 0.5ms
- 1K NetworkPolicy changes: iptables blocks traffic during update vs Cilium lock-free

On OpenShift 4.14+: Cilium is available as an alternative to OVN-Kubernetes via the `NetworkType: Cilium` configuration.
