# Dynatrace Observability Interview Guide

**Target Role:** Principal Platform Engineer / SRE / MLOps Engineer  
**Background:** Dynatrace at Voya India — full-stack observability, SLO alerting, MCP server integration, LLM observability

---

## 1. Dynatrace Architecture

### Core Components

```
Dynatrace Platform Architecture:
├── Dynatrace Tenant (SaaS)           — your environment at *.live.dynatrace.com
│   ├── GRAIL (data lake)             — stores all metrics, logs, traces, events
│   ├── Davis AI engine               — causal AI, dependency topology, problem detection
│   └── API / DQL engine              — query interface for all signals
│
├── OneAgent (on each host/node)      — deployed as DaemonSet on Kubernetes
│   ├── Auto-instrumentation          — JVM, .NET, Node.js, Python, Go
│   ├── Infrastructure monitoring     — CPU, memory, disk, network per process
│   └── Application monitoring        — traces, spans, errors per service
│
└── Dynatrace Operator (on K8s)       — manages OneAgent DaemonSet via DynaKube CRD
    └── ActiveGate                    — routing gateway between OneAgent and tenant
        ├── Cluster ActiveGate        — one per cluster, routes OneAgent data
        └── Environment ActiveGate   — optional, for network-isolated environments
```

### OneAgent Deployment Modes on Kubernetes

| Mode | OneAgent Location | Use Case |
|------|------------------|----------|
| `classicFullStack` | DaemonSet on every node | Full host + container + APM monitoring |
| `cloudNativeFullStack` | DaemonSet + per-pod instrumentation | Better isolation; inject via init-container |
| `applicationMonitoring` | No DaemonSet; inject per namespace | OpenShift with strict SCCs |
| `hostMonitoring` | DaemonSet, infrastructure only | Infrastructure metrics only (no APM) |

```yaml
# DynaKube CR for cloudNativeFullStack
apiVersion: dynatrace.com/v1beta1
kind: DynaKube
metadata:
  name: dynakube
  namespace: dynatrace
spec:
  apiUrl: https://abc12345.live.dynatrace.com/api
  tokens: dynakube-token         # Secret with paasToken + apiToken
  cloudNativeFullStack:
    tolerations:                 # Allow on master/infra nodes too
      - key: node-role.kubernetes.io/master
        operator: Exists
        effect: NoSchedule
  namespaceSelector:             # Only monitor these namespaces
    matchLabels:
      dynatrace: enabled
```

---

## 2. OneAgent on Kubernetes/OpenShift

### OpenShift-Specific Requirements

```bash
# 1. Install Dynatrace Operator via OperatorHub
# 2. Create the tokens secret
oc create secret generic dynakube-token \
  --from-literal=apiToken=<API_TOKEN> \
  --from-literal=paasToken=<PAAS_TOKEN> \
  -n dynatrace

# 3. OneAgent needs elevated SCC on OpenShift
oc adm policy add-scc-to-user privileged \
  -z dynatrace-dynakube-oneagent -n dynatrace
# classicFullStack needs host access for kernel-level monitoring
```

**`classicFullStack` vs `cloudNativeFullStack` on OpenShift**:
- `classicFullStack` runs as privileged, uses kernel module — more complete data, requires `privileged` SCC.
- `cloudNativeFullStack` uses init-container injection per pod — works with `restricted` SCC, less disruptive.
- At Voya: `cloudNativeFullStack` chosen for prod to avoid `privileged` SCC on worker nodes.

---

## 3. Davis AI

### How Davis AI Works (Not Just Correlation)

```
Traditional monitoring: "High CPU + High Error Rate = problem" (correlation)
Davis AI: "High CPU on database → slow queries → high error rate in API" (causation)
```

Davis AI builds a **Smartscape** — a real-time dependency topology:
```
Process Group → Service → Application → User Session → Business Event
      ↕              ↕
   Host          Database
```

When a metric anomaly is detected:
1. Davis identifies the affected entity (e.g., `inference-service` on `worker-node-3`)
2. Traverses the dependency graph to find root cause (e.g., `ODF CephFS slow I/O on worker-node-3`)
3. Baselines normal behaviour per entity (not static thresholds) — reduces false positives
4. Opens a **Problem card** grouping all related alerts into a single actionable item

### Reading a Davis Problem Card

```
Problem: Service degradation detected
Severity: Error  |  Duration: 14m  |  Impact: 847 users

Root Cause (Davis suggestion):
  ● inference-service (CPU saturation >90%)
      ↕ calls
  ● model-loader-service (response time +300%)
      ↕ reads from
  ● ODF CephFS PV (I/O wait >500ms)

Events timeline:
  10:23 ODF I/O wait spikes
  10:24 model-loader response time degrades
  10:25 inference-service CPU rises, error rate starts
  10:27 Problem opened

Impacted entities: 3 services, 2 hosts, 1 database
```

**Interview point**: Davis "opened one problem card" not 20 separate alerts. This reduces alert fatigue dramatically. At Voya, we went from 40+ alerts per incident to 1-3 problem cards.

---

## 4. SLO Management in Dynatrace

### Creating SLOs in Dynatrace

```bash
# Create SLO via Dynatrace API
curl -X POST "https://abc12345.live.dynatrace.com/api/v2/slo" \
  -H "Authorization: Api-Token $DT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Inference Endpoint Availability",
    "description": "p95 of inference requests succeed",
    "evaluationType": "AGGREGATE",
    "metricExpression": "100 * (builtin:service.errors.server.successCount:splitBy() / builtin:service.requestCount.server:splitBy())",
    "target": 99.5,
    "warning": 99.8,
    "timeframeStart": "-1M",
    "timeframeEnd": "now",
    "filter": "type(\"SERVICE\"),entityName(\"inference-service\")"
  }'
```

### SLO-Driven Alerting

```
SLO: 99.5% availability over 30 days
Error budget: 0.5% × 30 × 24 × 60 = 216 minutes

Dynatrace burn rate alerts:
  Fast burn (1h window): error rate > 5× budget rate → SEV1
  Slow burn (6h window): error rate > 2× budget rate → SEV2
```

Dynatrace SLO dashboard widget shows:
- Current SLO status (green/yellow/red)
- Error budget remaining (%)
- Burn rate trend
- Estimated time to budget exhaustion

---

## 5. DQL (Dynatrace Query Language)

DQL is the query language for Dynatrace GRAIL. Think: SQL for observability data.

### Basic DQL Patterns

```dql
// Fetch failed traces for inference service in last 1 hour
fetch spans
| filter service.name == "inference-service"
| filter status == "error"
| summarize count(), avg(duration), max(duration)

// Service latency percentiles (p50, p95, p99)
fetch spans
| filter service.name == "inference-service"
| summarize p50(duration), p95(duration), p99(duration) by bin(timestamp, 5m)
| makeTimeseries p50=avg(p50), p95=avg(p95), p99=avg(p99)

// Log analysis: find OOM kills
fetch logs
| filter kubernetes.namespace.name == "ml-platform"
| filter content contains "OOMKilled"
| summarize count() by kubernetes.pod.name, bin(timestamp, 1h)
| sort count desc

// Metric query: GPU utilisation per node
fetch metrics "ext:nvidia.gpu.utilization"
| filter kubernetes.node.name == "gpu-worker-0"
| summarize avg(value), max(value) by bin(timestamp, 5m)
| makeTimeseries avg=avg(avg), max=avg(max)
```

### Davis SQL (for calculated metrics)

```dql
// Custom calculated metric: request success rate
fetch spans
| filter service.name == "inference-service"
| summarize
    total = count(),
    success = countIf(http.response.status_code < 500)
| fields success_rate = success / total * 100
```

---

## 6. Dynatrace + OpenTelemetry

### Why Dynatrace Natively Supports OTLP

Dynatrace GRAIL accepts OTLP (OpenTelemetry Protocol) directly:
- gRPC endpoint: `https://<tenant>.live.dynatrace.com/api/v2/otlp` (port 4317 internally)
- HTTP endpoint: `https://<tenant>.live.dynatrace.com/api/v2/otlp/v1/traces`

This means: if your application is instrumented with OpenTelemetry SDKs, you can export directly to Dynatrace without a separate Jaeger or Tempo.

```yaml
# OTel Collector exporter config → Dynatrace
exporters:
  otlphttp/dynatrace:
    endpoint: "https://abc12345.live.dynatrace.com/api/v2/otlp"
    headers:
      Authorization: "Api-Token ${DT_API_TOKEN}"
    tls:
      insecure: false

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch, resource]
      exporters: [otlphttp/dynatrace]
    metrics:
      receivers: [otlp, prometheus]
      exporters: [otlphttp/dynatrace]
    logs:
      receivers: [otlp]
      exporters: [otlphttp/dynatrace]
```

### Attribute Enrichment

OTel spans sent to Dynatrace are enriched with Dynatrace's Smartscape context:
- `dt.entity.service` — mapped to a Dynatrace service entity
- `k8s.pod.name`, `k8s.namespace.name` — mapped to Kubernetes monitoring data
- Merges OTel trace with full-stack data (CPU, memory, I/O from OneAgent)

**Interview talking point**: "My OTel experience at Voya is via Dynatrace. Dynatrace natively ingests OTLP, so every span from our Python/Java services automatically appears in Dynatrace traces, enriched with host and Kubernetes context. I don't need to run a separate Jaeger deployment."

---

## 7. Dynatrace for LLM Observability

### Custom Spans for RAG Pipeline

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

tracer = trace.get_tracer("rag-inference-pipeline")

def run_rag_pipeline(query: str) -> dict:
    with tracer.start_as_current_span("rag.pipeline") as pipeline_span:
        pipeline_span.set_attribute("query.length", len(query))
        pipeline_span.set_attribute("query.tokens", count_tokens(query))

        with tracer.start_as_current_span("rag.retrieval") as retrieval_span:
            docs = retrieve_chunks(query, n_results=4)
            retrieval_span.set_attribute("retrieval.n_results", len(docs))
            retrieval_span.set_attribute("retrieval.top_score", docs[0]["distance"])

        with tracer.start_as_current_span("rag.llm_inference") as llm_span:
            start = time.time()
            answer = llm.invoke(build_prompt(query, docs))
            ttft = time.time() - start
            llm_span.set_attribute("llm.model", "llama3.2:3b")
            llm_span.set_attribute("llm.ttft_ms", ttft * 1000)
            llm_span.set_attribute("llm.output_tokens", count_tokens(answer))
            llm_span.set_attribute("llm.input_tokens", count_tokens(query) + sum(len(d["text"]) for d in docs) // 4)

        return {"answer": answer, "sources": [d["source"] for d in docs]}
```

In Dynatrace:
- These spans appear under the service `rag-inference-pipeline`
- Davis can detect anomalies: "LLM TTFT increased 3x in last 30 minutes"
- DQL query: `fetch spans | filter span.name == "rag.llm_inference" | summarize p95(llm.ttft_ms) by bin(timestamp, 5m)`

---

## 8. Dynatrace MCP Integration (Voya Project)

### What the Voya MCP Server Does

At Voya, I built an MCP (Model Context Protocol) server on OpenShift that:
1. Exposes Dynatrace API as structured tools (list problems, query metrics, get traces)
2. Exposes Kubernetes API as tools (list pods, describe nodes, get events)
3. An LLM (via the MCP client) calls these tools to answer operational questions in natural language

Example interaction:
```
User: "Why is the inference endpoint slow right now?"
LLM → calls tool: get_dynatrace_problems(service="inference-service", since="30m")
     → calls tool: get_kubernetes_pods(namespace="ml-platform", label="app=inference")
     → calls tool: get_prometheus_metrics(query="histogram_quantile(0.95, ...)")
LLM → synthesises: "Inference pod count dropped to 1 (KEDA ScaledObject paused). 
      Davis detected CPU saturation. Recommend: check KEDA trigger metrics."
```

### MCP Server Architecture on OpenShift

```
┌─────────────────────────────────────────────────────────┐
│ OpenShift Cluster                                       │
│                                                         │
│  ┌──────────────────┐         ┌─────────────────────┐  │
│  │   MCP Server Pod │◄───────►│ Dynatrace API       │  │
│  │  (FastAPI/Python)│         │ (REST/GraphQL)       │  │
│  │                  │         └─────────────────────┘  │
│  │  Tools exposed:  │         ┌─────────────────────┐  │
│  │  - get_problems  │◄───────►│ Kubernetes API      │  │
│  │  - query_dql     │         │ (in-cluster)        │  │
│  │  - get_traces    │         └─────────────────────┘  │
│  │  - list_pods     │                                   │
│  └──────────────────┘                                   │
│          ▲                                              │
│          │ MCP Protocol (SSE/JSON-RPC)                  │
│  ┌──────────────────┐                                   │
│  │  LLM Client      │ (Claude/GPT via API or local)    │
│  │  (Claude Desktop │                                   │
│  │   or custom UI)  │                                   │
│  └──────────────────┘                                   │
└─────────────────────────────────────────────────────────┘
```

---

## 9. Cost Optimisation

### DPS (Dynatrace Platform Subscription) Model

Dynatrace moved from host-unit pricing to **DPS** (Dynatrace Platform Subscription):
- One pool of credits consumed by all signals (metrics, logs, traces, sessions)
- No separate SKU for APM vs infrastructure vs log analytics

Cost levers:
```
Logs: highest cost per GB
  Optimisation: log ingest filter — only send ERROR and WARN logs, not DEBUG
  DQL: fetch logs | filter level == "ERROR" or level == "WARN"

Traces: configurable sampling
  Optimisation: tail sampling — keep 100% errors, 5% normal traces
  Dynatrace adaptive sampling: automatically reduces trace volume for healthy services

Metrics: keep default metrics, disable unused custom metrics
  Check: Settings → Metric consumption → identify high-cardinality custom metrics

Sessions (RUM): set sample rate for real-user monitoring
```

### Data Retention Tiers

| Tier | Default Retention | Cost |
|------|------------------|------|
| Metrics | 5 years | Low |
| Traces | 10 days | High |
| Logs | 35 days | Highest |
| Events | 3 years | Low |

Optimisation: keep hot data (7 days) in GRAIL; archive older data to object storage (Dynatrace's "Grail long-term storage" or export to S3 via Business Analytics).

---

## 10. Alerting and Automation

### Alerting Profiles

```
Alerting Profile: "ML Platform - Critical"
  Severity filter: Error, Performance
  Problem filters:
    - Service: inference-service
    - Host: nodes labelled gpu=true
  Alert threshold: notify if problem open > 5 minutes
  Notification: PagerDuty → on-call rotation

Alerting Profile: "ML Platform - Warning"
  Severity filter: Warning
  Notification: Slack #platform-alerts
  Delay: 30 minutes (suppress noisy warning alerts for 30 min)
```

### Webhook → PagerDuty Integration

```bash
# Configure Dynatrace → PagerDuty webhook
# Settings → Integrations → Problem notifications → PagerDuty
# Provide PagerDuty Service Integration Key
# Custom payload (optional):
{
  "routing_key": "{PAGERDUTY_ROUTING_KEY}",
  "event_action": "trigger",
  "payload": {
    "summary": "{ProblemTitle}",
    "severity": "critical",
    "source": "Dynatrace",
    "custom_details": {
      "problem_url": "{ProblemURL}",
      "impacted_entity": "{ImpactedEntity}",
      "root_cause": "{RootCause}"
    }
  }
}
```

---

## 11. Scenario-Based Interview Questions

**Q: Davis AI opened a problem card. Walk me through how you read it and trace the root cause.**

1. Open the problem card. Note: "Root Cause" (Davis's causal suggestion), severity, impacted entities, and the timeline.
2. Read the timeline: Davis shows events in causal order (not chronological noise). The first event in the timeline is usually the root cause.
3. Click the root cause entity (e.g., `ODF CephFS slow I/O`) → opens the entity detail page showing historical baselines vs current performance.
4. Look at the Smartscape: what services depend on the root cause entity? Does the dependency chain match what Davis suggested?
5. Open traces: filter traces from the problem's time window → look for spans with high duration that trace back to the root cause.
6. Run a DQL query to confirm:
   ```dql
   fetch spans
   | filter service.name == "inference-service"
   | filter timestamp >= "<problem start time>"
   | summarize p99(duration) by bin(timestamp, 1m)
   ```
7. Confirm the timeline: I/O spike at T+0 → model load latency at T+1 → inference service errors at T+2.
8. Document the causal chain in the post-mortem and create the action item (add ODF I/O alert).

**Q: Your OTel spans are visible in Jaeger but not in Dynatrace. What do you check?**

1. **Exporter config**: verify the OTel Collector config has a `otlphttp/dynatrace` exporter pointing to the correct tenant URL (`https://<tenant>.live.dynatrace.com/api/v2/otlp`).
2. **API token permissions**: the Dynatrace API token must have the scope `openTelemetryTrace.ingest` (and `metrics.ingest` for metrics). Check Settings → API tokens in the Dynatrace UI.
3. **Collector pipeline**: verify the pipeline in `config.yaml` routes traces to the Dynatrace exporter, not only to Jaeger:
   ```yaml
   service:
     pipelines:
       traces:
         exporters: [otlp/jaeger, otlphttp/dynatrace]  # both
   ```
4. **Collector logs**: `kubectl logs -n observability deployment/otel-collector | grep -i error`. Look for `401 Unauthorized` (wrong token) or `404 Not Found` (wrong endpoint URL).
5. **Service name mapping**: Dynatrace creates services based on `service.name` attribute. If the attribute is missing or too generic, Dynatrace may not create a distinct service entity.
6. **Tenant active gate routing**: if using a private cluster, the Cluster ActiveGate must be configured to proxy OTLP ingest. Check ActiveGate connectivity status in the Dynatrace UI.

**Q: LLM inference endpoint p95 latency spiked to 8s from the normal 500ms. Walk through your Dynatrace investigation.**

1. **Problem card check**: Davis may already have opened a problem card. If so, read the root cause suggestion (start here, not from scratch).
2. **Service dashboard**: open the `inference-service` in Dynatrace. Look at the response time chart — when did it spike?
3. **Distributed traces**: filter traces by `response_time > 2s` in the problem window. Open a slow trace.
4. **Trace breakdown**: look for which span accounts for most of the time:
   - `rag.retrieval` taking 7s → ChromaDB/vector store problem
   - `rag.llm_inference` taking 7s → LLM throughput saturated (GPU queue full)
   - `model_load` taking 7s → model being loaded from disk on a cold pod (scale-up event)
5. **Kubernetes events**: in Dynatrace's Kubernetes page, look for events in `ml-platform` namespace. HPA/KEDA scale events? OOM events? Node pressure?
6. **Correlate with infrastructure**: if `rag.llm_inference` is slow, check GPU utilisation metric. If GPU is at 100%, the queue is full.
7. **Action**: if GPU queue full → KEDA should scale. If KEDA isn't scaling → check ScaledObject trigger metrics (this was the 3am incident scenario).

**Q: How did you build the MCP server at Voya, and what problems did it solve?**

Context: Platform team was getting 20+ ad-hoc requests per week from developers asking "why is my pod crashing?", "what's the error rate on my service?", "which nodes are under pressure?". Each took 5-15 minutes of platform engineer time.

Solution: MCP (Model Context Protocol) server that exposes Dynatrace and Kubernetes APIs as structured tools. An LLM client (Claude Desktop) can call these tools to answer operational questions autonomously.

Implementation:
1. Python FastAPI server deployed on OpenShift with an `IngressRoute`.
2. Dynatrace tools: `get_problems(since, severity)`, `query_dql(query)`, `get_traces(service, since)`.
3. Kubernetes tools: `list_pods(namespace, label_selector)`, `describe_node(node_name)`, `get_events(namespace)`.
4. Security: MCP server uses a service account with minimal RBAC (read-only on pods/events/nodes). Dynatrace API token with read-only scopes stored in Vault, injected via ESO.
5. Authentication: the MCP endpoint requires a JWT token from Azure AD (only authorised users can use the LLM interface).

Impact: developers can ask "why is my pod crashing?" and the LLM calls `list_pods`, `get_events`, and `get_traces` to give a specific answer in 30 seconds. Platform engineer time on ad-hoc queries dropped by ~70%.

**Q: How do you configure Dynatrace SLO alerting to avoid both missing real incidents and alert fatigue?**

Single-threshold alerting causes alert fatigue. Better: multi-window burn rate alerts.

```
Fast burn window (1h): 
  If error rate > 5× budget rate → you'll exhaust the monthly budget in <5 hours → SEV1 page now
  
Slow burn window (6h):
  If error rate > 2× budget rate → you'll exhaust budget in ~60 hours → SEV2 Slack notification

Budget depletion alert:
  If budget remaining < 25% → Slack warning to team → reliability sprint consideration
  If budget remaining < 5% → SEV2 page → feature freeze
```

In Dynatrace:
1. Create the SLO with `target: 99.5`, `warning: 99.8`.
2. Create a `Custom event for alerting` that queries the SLO burn rate metric:
   ```
   Metric: ext:slo.burn_rate_1h  (custom metric tracking burn rate)
   Condition: > 5.0 for 5 minutes
   Severity: Error → PagerDuty
   ```
3. Create a second alert for slow burn (6h window, threshold 2.0, Slack only).

This means: you only get paged when the burn rate is high enough to threaten the SLA, not for every transient error spike.
