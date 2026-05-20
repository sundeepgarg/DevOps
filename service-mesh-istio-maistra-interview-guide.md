# Service Mesh — Istio & Maistra Interview Guide

**Target Role:** Senior Platform / DevOps / MLOps Engineer  
**Your background:** Istio / Maistra (4 yrs), Service Mesh 3 on OpenShift at Voya —  
multi-cluster east-west gateway, mTLS zero-trust architecture

> Note: The Kubernetes Architect guide (kubernetes_architect_interview_guide.md) covers  
> Q5 (why use a mesh), Q6 (sidecar vs ambient), Q7 (sidecar boot ordering).  
> This guide goes deeper: internals, Maistra specifics, traffic management, multi-cluster,  
> security policies, and production failure scenarios.

---

## 1. Why Service Mesh Exists — The Real Motivation

### What Kubernetes alone cannot do

Kubernetes handles:
- Pod scheduling and lifecycle
- Service discovery (DNS → ClusterIP → Pod IPs)
- Basic L4 load balancing (round-robin)
- Basic network isolation (NetworkPolicy)

Kubernetes does NOT handle:
- **Mutual TLS** between services (zero-trust identity)
- **L7 traffic control** (route 10% to v2, circuit break, retry)
- **Distributed tracing** (trace_id propagation across service calls)
- **Fine-grained access control** (Service A can call `/read` but not `/write` on Service B)
- **Observability** of service-to-service traffic without app code changes

A service mesh adds all of these at the **infrastructure level** — application developers write their code normally, the mesh handles encryption, routing, and observability transparently.

### The sidecar proxy model — how it works

```
Without mesh:                    With mesh (Istio sidecar):

[Pod A]                          [Pod A]
  App Container                    App Container (port 8080)
  → sends plain HTTP                 ↓ (iptables rules intercept ALL traffic)
  → no encryption                  Envoy Proxy (sidecar)
  → no trace context                 ↓ mTLS to other Envoy
                                     → trace context injected
                                     → retries, circuit breaking
                                     → metrics recorded

[Pod B]                          [Pod B]
  App Container                    Envoy Proxy → App Container
  ← receives plain HTTP              ← mTLS from Pod A's Envoy
```

**iptables interception** — how Envoy captures all traffic without app changes:
```
Pod init container (istio-init) runs:
  iptables -t nat -A PREROUTING -p tcp -j REDIRECT --to-port 15001
  → All inbound TCP redirected to Envoy port 15001

  iptables -t nat -A OUTPUT -p tcp -j REDIRECT --to-port 15001  
  → All outbound TCP also redirected to Envoy
  
App thinks it's calling port 8080 directly.
Actually: App → iptables → Envoy (15001) → mTLS → remote Envoy → remote App
```

---

## 2. Istio Architecture — Control Plane and Data Plane

### The two planes

```
CONTROL PLANE (istiod — one per cluster)
  ├── Pilot      — service discovery, traffic rules → pushes config to Envoy sidecars
  ├── Citadel    — certificate authority, issues workload identity certs (SPIFFE/X.509)
  └── Galley     — config validation and distribution
  
  (In Istio 1.5+, all merged into single binary: istiod)

DATA PLANE (Envoy sidecar in every pod)
  ├── Receives xDS config from istiod
  ├── Enforces traffic rules (routing, retries, circuit breaking)
  ├── Enforces mTLS (terminates inbound, originates outbound)
  └── Emits telemetry (metrics to Prometheus, traces to Jaeger/Zipkin)
```

### xDS — how istiod pushes config to Envoy

xDS is a family of discovery APIs that Envoy polls/subscribes to:

```
xDS APIs:
  CDS — Cluster Discovery Service    → "what upstream services exist"
  EDS — Endpoint Discovery Service   → "what IPs serve each cluster"
  LDS — Listener Discovery Service   → "what ports to listen on"
  RDS — Route Discovery Service      → "how to route requests"
  SDS — Secret Discovery Service     → "TLS certificates"

Flow:
  1. New pod starts with Envoy sidecar
  2. Envoy connects to istiod and says "give me my config"
  3. istiod pushes CDS/EDS/LDS/RDS/SDS — Envoy knows the full mesh topology
  4. When you apply a VirtualService YAML:
     kubectl apply -f vs.yaml
     → Kubernetes API server stores it
     → istiod watches API server, detects change
     → istiod computes new RDS config
     → istiod pushes updated RDS to relevant Envoy sidecars
     → Traffic routing changes within seconds, zero downtime
```

### Envoy sidecar ports — what each does

```
Port   Purpose
15001  Outbound traffic capture (iptables redirects app outbound here)
15006  Inbound traffic capture (iptables redirects inbound here)
15008  Inbound HBONE (HTTP-based overlay, used by Ambient mesh)
15020  Merged Prometheus metrics (app + Envoy metrics combined)
15021  Health check endpoint (used by Kubernetes readiness probe)
15090  Prometheus metrics (Envoy's own metrics)
```

---

## 3. Istio CRDs — The Full Set Explained

### VirtualService — traffic routing rules

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: model-serving
  namespace: ml-serving
spec:
  hosts:
    - model-serving-svc          # Which service this applies to
  http:
    # Rule 1: Canary — 10% to v2
    - match:
        - headers:
            x-canary:
              exact: "true"      # Specific header triggers canary
      route:
        - destination:
            host: model-serving-svc
            subset: v2
    
    # Rule 2: A/B test — split by weight
    - route:
        - destination:
            host: model-serving-svc
            subset: v1
          weight: 90
        - destination:
            host: model-serving-svc
            subset: v2
          weight: 10
    
    # Rule 3: Retry configuration
    retries:
      attempts: 3
      perTryTimeout: 10s
      retryOn: "5xx,connect-failure,reset"
    
    # Rule 4: Timeout
    timeout: 30s
    
    # Rule 5: Fault injection for chaos testing
    fault:
      delay:
        percentage:
          value: 5.0             # Inject 500ms delay for 5% of requests
        fixedDelay: 500ms
```

### DestinationRule — connection pool and load balancing

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: model-serving
  namespace: ml-serving
spec:
  host: model-serving-svc
  
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100      # Max TCP connections per host
      http:
        h2UpgradePolicy: UPGRADE  # Upgrade to HTTP/2 where possible
        http1MaxPendingRequests: 50
        http2MaxRequests: 1000
    
    loadBalancer:
      simple: LEAST_REQUEST      # Route to pod with fewest active requests
      # Other options: ROUND_ROBIN, RANDOM, PASSTHROUGH
    
    # Circuit breaker — outlier detection
    outlierDetection:
      consecutive5xxErrors: 5    # After 5 errors, eject pod from pool
      interval: 10s              # Check every 10s
      baseEjectionTime: 30s      # Eject for 30s minimum
      maxEjectionPercent: 50     # Never eject more than 50% of pods
  
  # Subsets for canary (referenced by VirtualService)
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
      trafficPolicy:
        connectionPool:
          http:
            http2MaxRequests: 200  # v2 can handle more requests
```

### PeerAuthentication — mTLS enforcement

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: enforce-mtls
  namespace: ml-serving       # Scope: one namespace
spec:
  mtls:
    mode: STRICT              # ALL traffic must be mTLS — plaintext rejected

---
# Cluster-wide enforcement
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: cluster-mtls
  namespace: istio-system     # istio-system scope = cluster-wide
spec:
  mtls:
    mode: STRICT

---
# Exception for one service (health check endpoint — probes send plaintext)
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: allow-plaintext-health
  namespace: ml-serving
spec:
  selector:
    matchLabels:
      app: model-serving
  mtls:
    mode: STRICT
  portLevelMtls:
    8080:
      mode: PERMISSIVE       # Allow plaintext on port 8080 only (health probe)
```

### AuthorizationPolicy — L7 access control

```yaml
# Only allow model-serving to call /predict on the inference service
# Deny all other traffic
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: inference-access
  namespace: ml-serving
spec:
  selector:
    matchLabels:
      app: llm-inference
  action: ALLOW
  rules:
    - from:
        - source:
            principals:                        # Service identity (SPIFFE URI)
              - "cluster.local/ns/api-gateway/sa/api-gateway-sa"
      to:
        - operation:
            methods: ["POST"]
            paths: ["/v1/completions", "/v1/chat/completions"]
    - from:
        - source:
            namespaces: ["monitoring"]         # Allow Prometheus scraping
      to:
        - operation:
            ports: ["15020"]                   # Metrics port only
```

```yaml
# Default deny — nothing gets in unless explicitly allowed
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: ml-serving
spec:
  {}    # Empty spec = deny all ingress to this namespace
```

### Gateway — ingress from outside the mesh

```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: platform-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway        # The ingress gateway pod
  servers:
    - port:
        number: 443
        name: https
        protocol: HTTPS
      tls:
        mode: SIMPLE             # TLS termination at gateway
        credentialName: platform-tls-cert  # Kubernetes Secret with TLS cert
      hosts:
        - "api.platform.example.com"
    - port:
        number: 80
        name: http
        protocol: HTTP
      tls:
        httpsRedirect: true      # Redirect all HTTP to HTTPS
      hosts:
        - "api.platform.example.com"
```

---

## 4. mTLS Deep Dive — SPIFFE and Workload Identity

### How Istio identity works (SPIFFE)

SPIFFE (Secure Production Identity Framework For Everyone) gives every workload a cryptographic identity — not username/password, but an X.509 certificate:

```
SPIFFE ID format:
  spiffe://<trust-domain>/ns/<namespace>/sa/<serviceaccount>

Example:
  spiffe://cluster.local/ns/ml-serving/sa/inference-sa
  
This identity is in the X.509 certificate that Envoy presents during mTLS handshake.
AuthorizationPolicy uses these identities (principals) for access control.
```

### Certificate lifecycle

```
1. Pod starts
2. istio-agent (inside sidecar) generates a private key + CSR
3. istio-agent sends CSR to istiod (Citadel component)
4. istiod signs the cert using its root CA
5. Signed cert returned to istio-agent → stored in memory (never written to disk)
6. Envoy uses this cert for all mTLS connections
7. Cert expires every 24 hours → auto-rotated by istiod
   (short-lived certs = even if stolen, useless after 24h)

Certificate inspection:
kubectl exec -it <pod> -c istio-proxy -- \
  openssl s_client -connect <service>:8080 2>/dev/null | openssl x509 -noout -text
# Shows: Subject Alternative Name = SPIFFE URI
```

### mTLS modes explained

```
PERMISSIVE: Accept both mTLS and plaintext
  Use during migration — old clients (no sidecar) still work
  Risk: man-in-middle attacks still possible from non-mesh clients

STRICT: mTLS only — reject plaintext
  Use in production — zero-trust enforced
  Risk: breaks clients without Envoy sidecar (external monitoring tools, 
        legacy apps not in mesh)

DISABLE: No mTLS (plaintext only)
  Use: specific services that cannot use TLS (some DBs, legacy)
```

**The migration path** from existing cluster:
```
Phase 1: Install Istio in PERMISSIVE mode cluster-wide
Phase 2: Inject sidecars into namespaces one by one
Phase 3: Set STRICT on individual namespaces as they're fully migrated
Phase 4: Set STRICT cluster-wide in istio-system
```

---

## 5. Maistra — Red Hat OpenShift Service Mesh

### What Maistra is

Maistra is Red Hat's **OpenShift-specific distribution of Istio**. It is bundled as:
- **Red Hat OpenShift Service Mesh 2.x** — based on Istio 1.12-1.16
- **Red Hat OpenShift Service Mesh 3.x** — based on Istio 1.20+ (what you used at Voya)

Key differences from upstream Istio:

| Feature | Upstream Istio | Maistra / OSSM |
|---|---|---|
| Installation | Helm / istioctl | Operator-based (ServiceMeshControlPlane CRD) |
| Namespace management | Global by default | Opt-in via ServiceMeshMember / ServiceMeshMemberRoll |
| Multi-tenancy | Not native | First-class — multiple control planes per cluster |
| OpenShift integration | Manual | Built-in (Routes, SCC, OpenShift OAuth) |
| Kiali | Separate install | Bundled with OSSM |
| Jaeger / Tempo | Separate install | Bundled |

### ServiceMeshControlPlane — the OSSM installation CRD

```yaml
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: basic
  namespace: istio-system
spec:
  version: v2.5                    # OSSM version
  
  addons:
    kiali:
      enabled: true
    prometheus:
      enabled: true
    jaeger:
      install:
        storage:
          type: Memory             # or Elasticsearch for production
  
  proxy:
    runtime:
      container:
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 128Mi
    
  security:
    dataPlane:
      mtls: true                   # Enable mTLS cluster-wide
    controlPlane:
      mtls: true
  
  tracing:
    sampling: 100                  # 100% sampling (adjust for production)
    type: Jaeger
  
  # Multi-cluster east-west gateway config
  gateways:
    egress:
      enabled: true
    ingress:
      enabled: true
    additionalIngress:
      eastwestgateway:
        enabled: true
        routerMode: sni-dnat       # SNI-based routing for cross-cluster mTLS
        service:
          metadata:
            labels:
              topology.istio.io/network: network1
          spec:
            type: LoadBalancer
            ports:
              - port: 15021
                name: status-port
              - port: 15443
                name: tls
              - port: 15012
                name: tls-istiod
              - port: 15017
                name: tls-webhook
```

### ServiceMeshMemberRoll — namespace enrollment

A key Maistra difference: namespaces must explicitly join the mesh:

```yaml
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: istio-system
spec:
  members:
    - ml-serving
    - api-gateway
    - eval-runners
    - platform-infra
# Namespaces NOT in this list are outside the mesh — no sidecar injection
```

Or per-namespace opt-in (OSSM 2.1+):
```yaml
apiVersion: maistra.io/v1
kind: ServiceMeshMember
metadata:
  name: default
  namespace: ml-serving    # Each namespace opts itself in
spec:
  controlPlaneRef:
    name: basic
    namespace: istio-system
```

---

## 6. Multi-Cluster Service Mesh — East-West Gateway

### What the east-west gateway is

In a single-cluster mesh, services talk directly pod-to-pod via Envoy sidecars. In multi-cluster, pods in Cluster A cannot reach pods in Cluster B directly (different VPCs/networks).

The **east-west gateway** is a dedicated Istio gateway that handles **cross-cluster service-to-service traffic**:

```
Cluster A                          Cluster B
  [Service A pod]                    [Service B pod]
    ↓ Envoy sidecar                    ↑ Envoy sidecar
    → east-west-gateway-A    ←→    east-west-gateway-B
       (LoadBalancer IP)              (LoadBalancer IP)
       
Traffic flow:
  Service A → Envoy → (SNI routing) → east-west-gw-A → TLS tunnel → east-west-gw-B → Envoy → Service B

The SNI (Server Name Indication) in the TLS ClientHello carries the destination service identity.
east-west-gw-B reads the SNI and routes to the correct local service — no decryption needed.
```

### Two multi-cluster models

**Model 1: Primary-Remote (one control plane)**
```
Cluster A (Primary):              Cluster B (Remote):
  istiod runs here                  No istiod
  Manages both clusters             Envoy sidecars configured by Cluster A istiod
  
Good for: simple setup, one team manages both clusters
Bad for: control plane in Cluster A going down = Cluster B loses config updates
```

**Model 2: Multi-Primary (separate control planes)**
```
Cluster A:                        Cluster B:
  istiod-A (trust domain A)         istiod-B (trust domain B)
  Manages Cluster A Envoys           Manages Cluster B Envoys
  
Shared: same root CA (so certs are trusted cross-cluster)
Communication: via east-west gateways, SNI-DNAT routing

Good for: resilience, separate teams, different OpenShift clusters
Bad for: more complex setup, need shared root CA
```

### At Voya — what you configured (multi-cluster OSSM east-west)

```yaml
# ServiceEntry — tell Cluster A's mesh about a service in Cluster B
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: cluster-b-ml-serving
  namespace: istio-system
spec:
  hosts:
    - ml-serving.ml-serving.svc.cluster.local   # How Cluster A's services refer to it
  location: MESH_INTERNAL
  ports:
    - number: 8080
      name: http
      protocol: HTTP
  resolution: STATIC
  endpoints:
    - address: 20.x.x.x    # East-west gateway LoadBalancer IP of Cluster B
      labels:
        security.istio.io/tlsMode: istio  # Tell Envoy to use mTLS
      ports:
        tls: 15443          # East-west gateway TLS port
```

```yaml
# DestinationRule for cross-cluster traffic — use TLS to east-west gateway
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: cluster-b-tls
  namespace: istio-system
spec:
  host: "*.svc.cluster.local"
  trafficPolicy:
    tls:
      mode: ISTIO_MUTUAL     # Use Istio-managed mTLS certificates
```

---

## 7. Observability with Istio — Kiali, Jaeger, Prometheus

### What you get for free with Istio

Without any app code changes, every pod with an Envoy sidecar automatically emits:

**Prometheus metrics (per service):**
```
istio_requests_total{
  source_app="api-gateway",
  destination_app="model-serving",
  response_code="200",
  reporter="source"
} = 14923

istio_request_duration_milliseconds_bucket{
  destination_app="model-serving",
  le="500"
} = 14820   # 14820/14923 = 99.3% under 500ms

# Key golden signals automatically available:
# - Rate (istio_requests_total)
# - Errors (response_code="5xx" / total)
# - Duration (istio_request_duration_milliseconds)
# Saturation: from resource metrics
```

**Distributed traces (Jaeger/Zipkin):**
- Every HTTP request gets a trace_id injected by Envoy
- Propagated to all downstream services automatically
- BUT: apps must forward the headers (`x-request-id`, `x-b3-traceid`, `x-b3-spanid`, `x-b3-sampled`)

```python
# App MUST forward these headers to downstream calls
# Envoy handles creation, but apps need to pass them along
PROPAGATION_HEADERS = [
    "x-request-id", "x-b3-traceid", "x-b3-spanid",
    "x-b3-parentspanid", "x-b3-sampled", "x-b3-flags",
    "x-ot-span-context",
    "traceparent",    # W3C standard (newer Istio)
    "tracestate"
]

@app.route("/predict")
async def predict(request):
    headers = {h: request.headers[h] for h in PROPAGATION_HEADERS if h in request.headers}
    response = await upstream_client.call(url, headers=headers)
```

### Kiali — the mesh observability UI

Kiali reads Istio configuration and Prometheus metrics to give:
- **Service graph**: live traffic topology with latency and error rates on edges
- **Config validation**: detects misconfigured VirtualServices, missing DestinationRules
- **Traffic shifting**: can modify VirtualService weights from UI (useful for demos)
- **Workload health**: per-deployment traffic success rate

Key Kiali use case for interviews: "I used Kiali to validate that mTLS was actually enforced — Kiali shows a padlock icon on each service edge when traffic is mTLS-encrypted. After enabling STRICT mode, I verified every service-to-service call showed the padlock."

---

## 8. Traffic Management Patterns

### Circuit breaking — preventing cascade failures

```
Normal:           Service A → Service B → DB
DB goes slow:     Service A → Service B → [DB slow - 5s timeout each call]
Without CB:       Service A queues up 100 requests to Service B → all hang → OOM
With CB:          After 5 consecutive failures, Service B removed from load balancer
                  Service A gets fast-fail (500) instead of hanging → can degrade gracefully
```

```yaml
# DestinationRule circuit breaker config
outlierDetection:
  consecutive5xxErrors: 5         # 5 5xx errors → eject endpoint
  consecutiveGatewayErrors: 3     # 3 gateway errors → eject earlier
  interval: 30s                   # Evaluation window
  baseEjectionTime: 30s           # First ejection: 30s
  # Subsequent ejections: 30s × ejection_count (exponential backoff)
  maxEjectionPercent: 100         # Allow ejecting all endpoints (fail-fast)
  minHealthPercent: 0             # Don't disable circuit breaker
```

### Retry with backoff

```yaml
# VirtualService retry policy
retries:
  attempts: 3
  perTryTimeout: 5s               # Each attempt gets 5s
  retryOn: "5xx,reset,connect-failure,retriable-4xx"
  retryRemoteLocalities: true     # Try a different zone on retry
```

**Important**: retries multiply traffic during failures. If all 3 replicas are down:
- Original request → fail
- Retry 1 → fail  
- Retry 2 → fail
= 3x traffic during outage. Combine with circuit breaker to avoid thundering herd.

### Fault injection — chaos engineering built in

```yaml
# Inject a 5-second delay for 10% of requests to test timeout handling
http:
  - fault:
      delay:
        percentage:
          value: 10.0
        fixedDelay: 5s
    route:
      - destination:
          host: model-serving-svc
```

This lets you test "does my API gateway return a proper 503 when the model server is slow?" without actually making the model server slow — Envoy injects the delay transparently.

---

## 9. Common Production Failures and Debugging

### Failure 1: "Connection refused" after enabling STRICT mTLS

**Symptom**: Service A worked yesterday, gets `connection refused` after PeerAuthentication STRICT applied.

```bash
# Diagnose: check if a service is outside the mesh (no sidecar)
kubectl get pods -n my-namespace -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].name}{"\n"}{end}'
# If you don't see "istio-proxy" in container list → no sidecar → plaintext client

# Check actual mTLS status with istioctl
istioctl authn tls-check <pod>/<service>.namespace.svc.cluster.local
# Shows: TLS_CONFLICT if one side is STRICT, other side has no sidecar

# Fix options:
# 1. Inject sidecar into the client service (add namespace label)
kubectl label namespace my-namespace istio-injection=enabled

# 2. Temporarily allow PERMISSIVE on the server
# (to let the client migrate)
```

### Failure 2: 503 "no healthy upstream" from Envoy

**Symptom**: Requests getting 503 with `upstream connect error or disconnect/reset before headers. reset reason: connection termination`

```bash
# Step 1: Check Envoy cluster health
kubectl exec -it <pod> -c istio-proxy -- \
  curl -s http://localhost:15000/clusters | grep "<service-name>"
# Look for: cx_connect_fail, cx_active=0 (circuit breaker open?)

# Step 2: Check Envoy logs
kubectl logs <pod> -c istio-proxy --since=5m | grep -i "upstream\|reset\|503"

# Step 3: Verify DestinationRule subsets match pod labels
kubectl describe destinationrule <name> -n <namespace>
# If subsets reference labels that don't exist on pods → no endpoints in subset

# Step 4: Check endpoint health
istioctl proxy-config endpoint <pod>.namespace | grep <service>
# Look for: HEALTHY vs UNHEALTHY, zone info

# Common cause: VirtualService references a subset not defined in DestinationRule
# ALWAYS create DestinationRule BEFORE VirtualService that references its subsets
```

### Failure 3: High latency introduced by mesh

**Symptom**: P99 latency increased after Istio enabled.

Istio adds ~1ms of latency per hop (Envoy processing). If you see much more:

```bash
# Check Envoy CPU throttling
kubectl top pod -l app=my-service -n my-namespace --containers
# If istio-proxy container is at CPU limit → increase Envoy CPU request

# Check Envoy stats
kubectl exec -it <pod> -c istio-proxy -- \
  curl -s http://localhost:15000/stats | grep "upstream_rq_time"
# Compare active request duration vs expected

# Check if mTLS handshake is slow (first request to a new service)
# TLS session resumption: Envoy caches sessions — first call to a new pod is slower
# Workaround: increase minReplicas to avoid cold-start penalty

# Check Envoy sidecar resource limits — often too low by default
kubectl get smcp basic -n istio-system -o yaml | grep -A5 "container:"
# Recommended minimum: 200m CPU, 256Mi memory per sidecar
```

### Failure 4: Envoy sidecar not injected

```bash
# Check namespace label
kubectl get namespace ml-serving --show-labels
# Required: istio-injection=enabled (upstream Istio)
#           maistra.io/member-of=istio-system (OSSM/Maistra)

# Check pod annotation override
kubectl get pod <pod> -o yaml | grep -A2 "sidecar.istio.io/inject"
# If "false" — injection disabled at pod level, overrides namespace label

# Verify MutatingWebhookConfiguration is active
kubectl get mutatingwebhookconfigurations | grep istio
kubectl describe mutatingwebhookconfiguration istio-sidecar-injector
# Check namespaceSelector matches your namespace labels
```

---

## 10. Ambient Mesh — The Future (Sidecarless Istio)

### Why ambient mesh was created

Sidecar model problems at scale:
- 5000 pods = 5000 Envoy sidecars = significant memory overhead (~50MB each = 250GB total)
- Sidecar restarts required to update Envoy version = rolling restarts across all pods
- Sidecar boot ordering issues (Envoy vs app race conditions)
- Sidecar increases pod startup time

### Ambient mesh architecture

```
Sidecar mesh:
  Every pod has its own Envoy (L4 + L7)

Ambient mesh:
  Layer 1 — ztunnel (per node, DaemonSet)
    Handles L4: mTLS, SPIFFE identity, basic telemetry
    Lightweight (20MB), one per node instead of one per pod
    
  Layer 2 — Waypoint proxy (per namespace or service account)
    Handles L7: VirtualService routing, AuthorizationPolicy L7 rules
    Only deployed when L7 features are needed
    One per namespace (not per pod)
```

```
Ambient mesh traffic flow:
  Pod A → ztunnel-node-A (mTLS via HBONE tunnel)
        → ztunnel-node-B (on destination node)
        → [waypoint if L7 policy needed]
        → Pod B

HBONE = HTTP-Based Overlay Network Encapsulation
  Uses HTTP/2 CONNECT tunnel to carry mTLS traffic between ztunnels
```

**Ambient mesh in OpenShift**: OSSM 3.x supports ambient mesh. For your Voya work, OSSM 3.x (which you used) is the version that introduced ambient mesh support.

---

## 11. Interview Questions — Senior Level

### Q1: At Voya you configured Maistra Service Mesh 3 with multi-cluster east-west gateway. Walk me through exactly how cross-cluster service calls work.

**Answer:**

In our OpenShift multi-cluster setup, we had two clusters — a primary in one region and a secondary. Both clusters had OSSM 3 installed with separate istiod instances sharing a common root CA (so their workload certificates are mutually trusted).

Each cluster has an east-west gateway — a dedicated Istio ingress gateway exposed as a LoadBalancer service on port 15443. This gateway is configured with `SNI-DNAT` routing, meaning it reads the Server Name Indication in the TLS ClientHello and routes to the correct local service without decrypting the payload.

When Service A in Cluster A calls Service B in Cluster B:
1. Envoy sidecar on Service A resolves Service B's DNS — this returns the east-west gateway IP of Cluster B (configured via ServiceEntry)
2. Envoy initiates an mTLS connection using Service A's SPIFFE certificate, with the SNI set to `outbound_.8080_._.service-b.namespace.svc.cluster.local`
3. Traffic transits to Cluster B's east-west gateway over the external LoadBalancer IP
4. Cluster B's east-west gateway reads the SNI, matches it to a local service, and forwards traffic to Service B's Envoy sidecar
5. Service B's Envoy validates the mTLS certificate from Cluster A — both trust the same root CA — and allows the connection

The result is end-to-end mTLS between services in different clusters, with traffic routing, retries, and circuit breaking applied by both Envoy sidecars.

---

### Q2: What is the difference between PeerAuthentication and AuthorizationPolicy? Can you use both?

Both relate to security but operate at different levels:

**PeerAuthentication** — answers "HOW can you connect to me?":
- Controls whether traffic must be mTLS (STRICT), may be plaintext (PERMISSIVE), or must be plaintext (DISABLE)
- Applied at the transport layer (L4) — doesn't look at HTTP methods or paths
- Set per namespace or per workload with label selectors

**AuthorizationPolicy** — answers "WHO is allowed to call WHAT on me?":
- Controls which service identities (SPIFFE URIs) can call which endpoints
- Works at L7 — can allow/deny based on HTTP method, path, headers, JWT claims
- Requires the connection to already be established (relies on PeerAuthentication for the TLS)

Yes, you always use both:
```
PeerAuthentication STRICT → ensures the connection is mTLS (verifies identity exists)
AuthorizationPolicy       → uses that verified identity to allow/deny specific operations

Without PeerAuthentication STRICT: AuthorizationPolicy's source.principals check is meaningless
(anyone can claim any identity without mutual TLS verification)
```

---

### Q3: A new team wants to add their namespace to the mesh at Voya (OSSM). Walk them through the onboarding process.

```bash
# Step 1: Add namespace to ServiceMeshMemberRoll
kubectl edit smmr default -n istio-system
# Add the new namespace to spec.members

# OR (OSSM 2.1+ preferred): team self-registers
kubectl apply -f - <<EOF
apiVersion: maistra.io/v1
kind: ServiceMeshMember
metadata:
  name: default
  namespace: new-team-namespace
spec:
  controlPlaneRef:
    name: basic
    namespace: istio-system
EOF

# Step 2: Enable sidecar injection on namespace
# Upstream Istio:
kubectl label namespace new-team-namespace istio-injection=enabled
# OSSM applies this automatically when namespace joins mesh

# Step 3: Restart pods to inject sidecars
kubectl rollout restart deployment -n new-team-namespace

# Step 4: Verify injection
kubectl get pods -n new-team-namespace -o jsonpath='{range .items[*]}{.metadata.name}: {range .spec.containers[*]}{.name} {end}{"\n"}{end}'
# Should see "istio-proxy" alongside app container

# Step 5: Start in PERMISSIVE mTLS (allow old clients to still connect)
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: permissive
  namespace: new-team-namespace
spec:
  mtls:
    mode: PERMISSIVE
EOF

# Step 6: Validate everything works, then switch to STRICT
kubectl patch peerauthentication permissive -n new-team-namespace \
  --type=merge -p '{"spec":{"mtls":{"mode":"STRICT"}}}'

# Step 7: Apply default deny AuthorizationPolicy
kubectl apply -f default-deny.yaml -n new-team-namespace

# Step 8: Team adds explicit AuthorizationPolicies for their service-to-service calls
```

---

### Q4: Your service is getting 503 errors from Envoy after a VirtualService was applied. How do you debug it?

```bash
# Step 1: Check if the VirtualService has a valid DestinationRule for its subsets
istioctl analyze -n my-namespace
# Common output: "VirtualService references subset 'v2' which is not defined in DestinationRule"

# Step 2: Check Envoy's view of the upstream cluster
istioctl proxy-config cluster <pod>.my-namespace --fqdn my-service.my-namespace.svc.cluster.local
# Look for subsets — if v2 subnet shows no endpoints → pods don't have matching labels

# Step 3: Verify pod labels match subset selector
kubectl get pods -n my-namespace --show-labels | grep "version=v2"
# If empty → DestinationRule subset selector doesn't match any pods

# Step 4: Check Envoy listener config
istioctl proxy-config listener <pod>.my-namespace
# Verify the port is listed

# Step 5: Check route rules
istioctl proxy-config route <pod>.my-namespace --name 8080
# Shows the actual routing table Envoy is using

# Step 6: Enable Envoy access logs temporarily
kubectl -n istio-system patch configmap istio --type=merge \
  -p '{"data":{"mesh":"accessLogFile: /dev/stdout"}}'
kubectl logs <pod> -c istio-proxy | tail -20
# Shows detailed request/response with upstream cluster name

# Root cause in 90% of cases:
# - Subset in VirtualService not defined in DestinationRule
# - DestinationRule subset labels don't match any pod labels
# - DestinationRule not created before VirtualService (ordering matters)
```

---

### Q5: How does Istio implement circuit breaking and how is it different from application-level circuit breaking?

**Application-level circuit breaking** (e.g., Hystrix, Resilience4j):
- Implemented in application code
- Works for any protocol (HTTP, gRPC, message queues)
- Has access to business context (can decide based on response content, not just status code)
- Requires every team to implement it consistently — hard to enforce

**Istio Envoy circuit breaking** (outlierDetection in DestinationRule):
- Implemented in the sidecar proxy — zero application code changes
- Works by ejecting endpoints from the load balancer pool when they fail health criteria
- Based on: consecutive 5xx errors, response time (with active health check), gateway errors
- Automatic exponential backoff (ejection time doubles per ejection)
- Applied consistently to ALL services in the mesh — no team-by-team implementation

The key difference: Istio tracks per-endpoint health (per pod IP), not per service. If one of 5 pods is misbehaving, Istio ejects just that pod while the other 4 continue serving. Application-level circuit breakers typically trip on the whole service.

Limitation of Istio circuit breaking: the `maxEjectionPercent` setting. Default is 10% — if 50% of pods are unhealthy, only 10% get ejected and requests still route to the sick pods. Set `maxEjectionPercent: 100` for aggressive isolation.

---

### Q6: Explain how Istio's AuthorizationPolicy uses SPIFFE identities for zero-trust access control.

SPIFFE (Secure Production Identity Framework For Everyone) provides cryptographic workload identities. When Envoy establishes mTLS, it presents an X.509 certificate where the Subject Alternative Name contains the SPIFFE URI:

```
spiffe://cluster.local/ns/api-gateway/sa/api-gateway-serviceaccount
```

This identity is verified cryptographically — it's signed by istiod's CA. You can't fake it.

AuthorizationPolicy's `source.principals` field accepts these SPIFFE URIs:

```yaml
rules:
  - from:
      - source:
          principals:
            - "cluster.local/ns/api-gateway/sa/api-gateway-sa"
    to:
      - operation:
          methods: ["POST"]
          paths: ["/v1/predictions"]
```

This says: only the service with the exact SPIFFE identity `api-gateway-sa` in namespace `api-gateway` can POST to `/v1/predictions`. Any other caller — even within the cluster, even if they know the service URL — is rejected with 403.

This is zero-trust: trust is based on cryptographic identity, not network location. Even if an attacker compromises a pod inside the cluster, they cannot call the model inference API unless they have the api-gateway service account credentials — which requires a separate Kubernetes RBAC escalation.

---

### Q7: What is SNI-DNAT routing used in east-west gateways and how does it preserve end-to-end mTLS?

SNI-DNAT (Server Name Indication — Destination Network Address Translation) is the routing mechanism used by east-west gateways in multi-cluster Istio.

Problem: When traffic exits one cluster and enters another, how does the destination gateway know which local service to forward to, without decrypting the mTLS tunnel?

Solution: The source Envoy encodes the destination service identity in the TLS SNI field of the ClientHello (the handshake message sent before any encryption). The east-west gateway reads the SNI (it's unencrypted in the handshake), performs DNAT to the correct local service IP, and passes the already-established mTLS session through unchanged.

```
Envoy in Cluster A:
  SNI = "outbound_.8080_._.ml-serving.ml-serving.svc.cluster.local"
  ↓ TLS ClientHello (SNI visible, payload encrypted)
  
East-west gateway Cluster B:
  Reads SNI → matches ServiceEntry → DNAT to pod IP 10.x.x.x:8080
  Does NOT decrypt the mTLS tunnel
  ↓ Passes encrypted traffic
  
Envoy sidecar in Cluster B:
  Receives mTLS connection
  Validates certificate from Cluster A (same root CA)
  Forwards to local app container
```

The mTLS session is end-to-end — from source Envoy to destination Envoy. The east-west gateway is just a router that reads the SNI label. This preserves zero-trust: the gateway never has access to the plaintext data.

---

### Q8: How does Istio observability compare to what you get with Dynatrace?

Istio's built-in observability:
- **Metrics**: Envoy emits 4 golden signals (rate, errors, duration, saturation) for every service automatically → Prometheus
- **Traces**: Distributed traces generated by Envoy, exported to Jaeger/Zipkin → requires apps to forward propagation headers
- **Kiali**: Topology visualization, config validation, traffic shifting UI

Dynatrace with OneAgent:
- **Automatic baselining**: Dynatrace uses AI (Davis) to learn normal patterns and auto-alert on anomalies — Prometheus requires manual threshold-based alerts
- **Code-level visibility**: Dynatrace traces down to individual Java method calls, DB queries, code paths — Istio traces only service-to-service boundaries
- **Full-stack correlation**: Dynatrace links network, host, process, service, and user session into one view — Istio is only the service mesh layer
- **No header propagation required**: Dynatrace OneAgent handles trace context injection inside the process — Istio requires app code to forward headers

**How they complement each other**: At Voya, I used both — Istio for mesh-level traffic control and mTLS enforcement, Dynatrace for application performance management and AI-driven alerting. The Dynatrace OTel endpoint consumed the distributed traces that Istio/OTel generated, giving us a single pane of glass.

---

## 12. Quick Reference

```
Core Istio CRDs:
  VirtualService    → traffic routing (canary %, retries, timeouts, fault injection)
  DestinationRule   → connection pool, load balancing, circuit breaking, subsets
  Gateway           → ingress/egress from outside the mesh
  PeerAuthentication → mTLS mode (STRICT/PERMISSIVE/DISABLE) per namespace/workload
  AuthorizationPolicy → L7 RBAC: who can call what endpoint (SPIFFE-based)
  ServiceEntry      → register external services or cross-cluster services into the mesh

Maistra vs upstream Istio:
  Installation: Operator (ServiceMeshControlPlane) vs Helm/istioctl
  Namespaces: opt-in (ServiceMeshMemberRoll) vs opt-in (label)
  Multi-tenancy: multiple control planes natively supported
  OpenShift: built-in Routes, SCC, OAuth integration

mTLS modes:
  STRICT      → production, rejects plaintext, zero-trust enforced
  PERMISSIVE  → migration, accepts both mTLS and plaintext
  DISABLE     → legacy services that can't use TLS

Multi-cluster east-west:
  SNI-DNAT routing → gateway routes by reading SNI without decrypting
  SPIFFE identities → same root CA across clusters enables cross-cluster trust
  ServiceEntry → tells local mesh about remote cluster's services

Debug commands:
  istioctl analyze -n <ns>                         → config validation
  istioctl proxy-config cluster <pod>              → upstream cluster view
  istioctl proxy-config route <pod>                → routing table
  istioctl authn tls-check <pod>/<svc>             → mTLS status
  kubectl logs <pod> -c istio-proxy                → Envoy access logs
  curl localhost:15000/stats                       → Envoy internal stats
  curl localhost:15000/clusters                    → cluster health
```
