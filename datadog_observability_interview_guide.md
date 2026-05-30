# Datadog Observability Interview Guide

**Target Role:** Principal Platform Engineer / SRE Lead / DevOps Architect
**Why Datadog:** Most commonly used commercial observability platform in enterprises.
  Customers replaced Prometheus+Grafana or Dynatrace with Datadog for unified metrics + logs + traces + security.

---

## 1. Datadog Architecture

### Core Components

```
Datadog Platform (SaaS — app.datadoghq.com)
├── Metrics Pipeline          — time-series store, 15-month retention
├── Log Management            — index / archive / live tail logs
├── APM + Distributed Tracing — flame graphs, service maps, trace search
├── Infrastructure            — host map, containers, processes
├── Synthetics                — uptime monitoring, browser tests, API tests
├── RUM (Real User Monitoring)— frontend performance, session replay
├── NPM (Network Performance) — service-to-service traffic, DNS
├── Security (CSPM/SIEM)      — cloud config posture, threat detection
└── Dashboards + Monitors     — alerting, SLOs, notebooks

Data Collection Layer:
├── Datadog Agent             — installed on hosts / K8s nodes
│   ├── DogStatsD server      — receives custom metrics from apps (UDP 8125)
│   ├── Log collector         — tails log files, Docker/K8s log streams
│   ├── Process agent         — collects process-level metrics
│   ├── Trace agent           — receives APM traces from apps (TCP 8126)
│   └── System probe          — kernel-level for NPM (eBPF)
│
├── Integrations (600+)       — pull metrics from AWS, Azure, K8s, DBs
├── API                       — push custom metrics via HTTP
└── Serverless forwarder      — Lambda extension for serverless metrics/logs
```

### Datadog Agent Deployment on Kubernetes

```yaml
# datadog-values.yaml (Helm chart)
datadog:
  apiKey: <DD_API_KEY>
  clusterName: prod-eks-cluster     # tags all data with cluster name

  # Enable features
  logs:
    enabled: true
    containerCollectAll: true       # collect logs from all containers
  apm:
    portEnabled: true               # trace agent listens on port 8126
  processAgent:
    enabled: true
    processCollection: true         # show individual processes
  networkMonitoring:
    enabled: true                   # NPM — service-to-service traffic

  # Tags applied to all data from this agent
  tags:
    - env:production
    - team:platform
    - region:us-east-1

agents:
  tolerations:
    - operator: Exists              # deploy on every node including taints

clusterAgent:
  enabled: true                     # single cluster agent for K8s metrics
  replicas: 2                       # HA cluster agent
```

---

## 2. Metrics

### Metric Types

| Type | What it does | Example |
|---|---|---|
| **Gauge** | Point-in-time value | CPU usage, memory used, queue depth |
| **Counter** | Cumulative count, always increasing | Total requests served, errors |
| **Rate** | Counter normalised per second | Requests/sec (computed from counter) |
| **Histogram** | Distribution of values | Request latency — p50/p75/p95/p99 |
| **Distribution** | Global percentiles (not per-agent) | Latency p99 across all hosts accurately |
| **Set** | Count of unique values | Unique users per minute |

**Distribution vs Histogram:**
- Histogram: percentiles computed per agent, then aggregated → inaccurate for p99 across fleet
- Distribution: raw values shipped, percentiles computed server-side → accurate p99 globally
- Use Distribution for latency SLOs. Use Histogram only for simple aggregations.

### Custom Metrics — DogStatsD

```python
# Python — send custom metrics to Datadog Agent
from datadog import initialize, statsd

initialize(statsd_host='localhost', statsd_port=8125)

# Gauge — current value
statsd.gauge('model.queue.depth', queue.size(), tags=['model:fraud-v2', 'env:prod'])

# Counter — increment on event
statsd.increment('inference.request.total', tags=['model:fraud-v2', 'status:success'])

# Histogram — track latency distribution
statsd.histogram('inference.latency.ms', elapsed_ms, tags=['model:fraud-v2'])

# Service check — UP/DOWN status
statsd.service_check('model.health', statsd.OK, tags=['model:fraud-v2'])
```

### Tagging Strategy (critical for interview)

Tags are the foundation of Datadog. Everything — metrics, logs, traces — should share common tags for correlation.

**Reserved tags:**
```
env:      — environment (production, staging, development)
service:  — service name (payment-api, fraud-detector)
version:  — deployment version (1.2.3) — enables deployment tracking
host:     — hostname (auto-added by agent)
```

**Kubernetes auto-tags (Cluster Agent adds these automatically):**
```
kube_cluster_name, kube_namespace, kube_deployment,
kube_pod_name, kube_container_name, kube_node
```

**Tag cardinality** — know this for interviews:
- Low cardinality: `env:prod`, `region:us-east` — safe, few unique values
- High cardinality: `user_id:12345`, `request_id:uuid` — dangerous, millions of unique tag values = cost explosion
- Rule: never tag with unique IDs. Put them in log fields or trace attributes instead.

---

## 3. Log Management

### Log Collection from Kubernetes

Datadog agent auto-collects container stdout/stderr. Configure per-container via annotations:

```yaml
# Pod annotation — tell Datadog how to parse this container's logs
annotations:
  ad.datadoghq.com/api.logs: |
    [{
      "source": "python",
      "service": "payment-api",
      "log_processing_rules": [{
        "type": "multi_line",
        "name": "stack_trace",
        "pattern": "Traceback|ERROR|WARN"
      }]
    }]
```

### Log Pipelines

Logs are processed through pipelines before indexing:

```
Raw log → Intake → Pipeline (parse + enrich) → Index / Archive

Pipeline stages:
1. Grok Parser    — extract fields from unstructured text
2. Remapper       — remap field names to standard (e.g., http.status_code)
3. Arithmetic     — compute new fields (latency in seconds from milliseconds)
4. Category       — add category tag based on field value
5. Filter         — drop noisy logs before indexing (saves cost)
```

**Grok parser example:**
```
# Parse: "2024-01-15 14:32:01 ERROR PaymentService - Connection timeout after 5000ms"
Pattern: %{TIMESTAMP_ISO8601:timestamp} %{LOGLEVEL:level} %{WORD:service} - %{GREEDYDATA:message}
```

### Log Indexes vs Archives

```
All logs ingested
    │
    ├──▶ Indexes (fast search, expensive)
    │      - Retention: 3, 7, 15, 30 days
    │      - Filters: index only ERROR + WARN logs (exclude DEBUG/INFO)
    │      - Cost: ~$1.27/million log events indexed
    │
    └──▶ Archives (cold storage, cheap)
           - Retention: unlimited (your S3/Azure Blob bucket)
           - Cost: storage cost only (~$0.023/GB in S3)
           - Use: compliance, rehydrate for investigation
           - Rehydrate: pull from archive back into Datadog for search
```

**Cost optimisation — Exclusion Filters:**
```
Index: payment-api-errors
Filter: source:payment-api AND status:error
Exclude: level:debug OR level:info

Result: 80% of logs go to cheap archive, only errors to expensive index
```

---

## 4. APM — Application Performance Monitoring

### Distributed Tracing

Datadog APM auto-instruments apps (zero code change) or manual instrumentation:

```python
# Manual Python instrumentation
from ddtrace import tracer, patch_all
patch_all()  # auto-instruments requests, sqlalchemy, redis, etc.

@tracer.wrap(service="payment-api", resource="process_payment")
def process_payment(order_id, amount):
    with tracer.trace("db.query", service="postgres") as span:
        span.set_tag("order.id", order_id)
        span.set_tag("payment.amount", amount)
        result = db.execute(query)
    return result
```

**Trace anatomy:**
```
Trace (single request end-to-end)
└── Span: payment-api /POST /checkout    (100ms total)
    ├── Span: redis GET session           (2ms)
    ├── Span: postgres SELECT order       (8ms)
    ├── Span: fraud-detector /predict     (45ms)
    │   └── Span: model inference         (40ms)
    └── Span: postgres INSERT transaction (12ms)
```

### Service Map

Datadog automatically builds a service dependency map from trace data:

```
payment-api ──▶ fraud-detector
           ──▶ postgres (db)
           ──▶ redis (cache)
           ──▶ notification-service
                └──▶ sendgrid (external)
```

Shows: request volume, error rate, latency between each service. No manual configuration — derived from traces.

### APM → Log Correlation

Set trace_id and span_id in logs for direct log-to-trace linking:

```python
import logging
from ddtrace import tracer

FORMAT = '%(asctime)s %(levelname)s [%(dd.service)s] [%(dd.trace_id)s %(dd.span_id)s] %(message)s'
logging.basicConfig(format=FORMAT)
```

Now in Datadog: click a trace span → "View related logs" → exact log lines from that request.

---

## 5. Infrastructure Monitoring

### Host Map and Container Map

Host Map — visualise every host/node:
- Colour by metric (CPU, memory, disk) → instantly see which nodes are hot
- Group by tag (env, region, team) → spot per-region issues

Container Map — same for containers:
- Group by kube_deployment or kube_namespace
- Spot which deployments have high CPU or OOM

### Live Process Monitoring

```
Datadog Process page shows:
  - Every running process on every host (pid, user, CPU, memory, command)
  - Filter by name, host, container, tag
  - See process restarts, exits in real-time
  - Correlate with metrics/traces at same timestamp
```

### Kubernetes State Metrics

Cluster Agent collects Kubernetes state automatically:

```
Pod states:          Running / Pending / Failed per namespace
Deployment status:   Desired vs Ready replicas
HPA status:          Current replicas, min/max, scaling events
Node conditions:     Ready, MemoryPressure, DiskPressure, PIDPressure
Persistent Volumes:  Bound / Unbound PVCs
```

---

## 6. Monitors and Alerting

### Monitor Types

| Type | Use case | Example |
|---|---|---|
| **Metric** | Threshold on any metric | Alert if CPU > 85% for 5 min |
| **Log** | Alert on log pattern | Alert if ERROR count > 50/min |
| **APM** | Alert on trace metrics | Alert if p99 latency > 500ms |
| **Composite** | Combine multiple monitors with AND/OR | Alert if CPU > 80% AND memory > 90% |
| **Anomaly** | ML-based deviation from baseline | Alert if traffic drops 50% below normal |
| **Forecast** | Predict future resource exhaustion | Alert if disk will fill in < 48 hours |
| **Outlier** | Detect hosts behaving differently | Alert if one pod has 10x error rate vs others |
| **SLO** | Track burn rate | Alert if error budget consumed too fast |

### Writing a Good Monitor (interview Q)

```python
# Example: Alert on high error rate for payment API
Monitor type: APM
Query: sum(last_5m):sum:trace.flask.request.errors{service:payment-api,env:prod}.as_rate() > 5

Message:
@pagerduty-platform-team
Payment API error rate is {{value}} errors/sec (threshold: 5/sec).
Service: {{service.name}}
Environment: {{env}}
Runbook: https://wiki.company.com/runbooks/payment-api-errors

Alert thresholds:
  ALERT: > 5 errors/sec   (page on-call)
  WARN:  > 2 errors/sec   (Slack notification only)
  Recovery: < 1 error/sec for 10 minutes

Notification channels:
  @pagerduty-payment-team  (alert)
  @slack-platform-alerts   (warn)
```

### Monitor Best Practices

```
1. No-data alerts:     Set "Notify if data is missing for X minutes"
                       — catches agent failures, not just metric thresholds

2. Evaluation window:  Use at least 5 minutes to avoid flapping
                       Short windows (1 min) → alert fires and recovers repeatedly

3. Multi-alert:        Scope monitors per host/service using template variables
                       {{host.name}} fires a separate alert per host

4. Downtime schedules: Suppress alerts during maintenance windows
                       az webapp deploy → suppress monitors for 15 min

5. Alert fatigue:      If > 30% of alerts are low-value → they get ignored
                       Review: are these actionable? Can they be warnings instead?
```

---

## 7. SLOs in Datadog

### Two SLO Types

**Monitor-based SLO:**
```
SLO: Payment API availability ≥ 99.9% over 30 days
Backing monitor: Payment API health check monitor
Good event: monitor in OK state
Bad event:  monitor in ALERT state

Datadog calculates: (time in OK) / (total time) × 100
Error budget: 0.1% of 30 days = 43.2 minutes
```

**Metric-based SLO:**
```
SLO: 99.5% of checkout requests complete in < 500ms over 30 days
Good events:  sum:trace.flask.request.hits{resource:POST_checkout,http.status_code:2xx,duration:<500ms}
Total events: sum:trace.flask.request.hits{resource:POST_checkout}

More precise than monitor-based — uses actual request counts
```

### Burn Rate Alerts on SLO

```
Burn rate = how fast you're consuming error budget

Normal consumption rate = 1x (use budget evenly over 30 days)
5x burn rate = budget consumed 5x faster than normal
  → at this rate, 30-day budget gone in 6 days

Datadog SLO burn rate alerts:
  Fast burn: > 14.4x for 1 hour  → page immediately (will exhaust budget in 2 days)
  Slow burn: > 6x for 6 hours    → urgent Slack (budget at risk this week)
```

---

## 8. Dashboards

### Dashboard Best Practices

**The RED method (Request-oriented services):**
```
- Rate:    requests/second
- Errors:  error rate (%)
- Duration: p50 / p95 / p99 latency
```

**The USE method (Infrastructure resources):**
```
- Utilisation: CPU %, memory %, disk %
- Saturation:  queue depth, load average, throttled requests
- Errors:      disk errors, network errors, OOM events
```

**Standard top-level dashboard structure:**
```
Row 1: Service Health (RED) — traffic, errors, latency
Row 2: Infrastructure (USE) — CPU, memory, pods running/pending
Row 3: Business metrics     — orders/min, revenue/min, active users
Row 4: Dependencies         — downstream service errors, DB query latency
Row 5: Recent deployments   — version rollout events overlay on metrics
```

### Template Variables

```
# Dashboard template variables allow filtering without code changes
$env    = prod | staging | dev
$region = us-east-1 | eu-west-1
$service = payment-api | fraud-detector | notification-service

Widget query:
avg:kubernetes.cpu.usage{env:$env, kube_namespace:$service}
```

---

## 9. Datadog Integrations

### AWS Integration

```bash
# CloudFormation stack creates IAM role for Datadog to pull AWS metrics
# Metrics pulled: EC2, RDS, EKS, Lambda, ALB, SQS, ElastiCache, S3

aws cloudformation create-stack \
  --stack-name datadog-integration \
  --template-url https://datadog-cloudformation-template.s3.amazonaws.com/aws/main.yaml \
  --parameters ParameterKey=DatadogApiKey,ParameterValue=$DD_API_KEY \
  --capabilities CAPABILITY_IAM
```

Metrics collected without Agent:
- EC2: CPU, network, status checks
- RDS: connections, IOPS, query latency
- Lambda: invocations, errors, duration, cold starts
- SQS: queue depth, age of oldest message
- ALB: request count, error rate, target response time

### Kubernetes Integration

```yaml
# datadog-operator.yaml — Kubernetes Operator approach (production-grade)
apiVersion: datadoghq.com/v2alpha1
kind: DatadogAgent
metadata:
  name: datadog
spec:
  global:
    clusterName: prod-cluster
    credentials:
      apiSecret:
        secretName: datadog-secret
        keyName: api-key
  features:
    apm:
      enabled: true
    logCollection:
      enabled: true
      containerCollectAll: true
    liveProcesses:
      enabled: true
    networkMonitoring:
      enabled: true
    admissionController:
      enabled: true    # auto-inject APM env vars into pods
```

**Admission Controller** — auto-injects Datadog APM into pods:
```yaml
# Add label to namespace — all new pods get DD_AGENT_HOST + DD_TRACE_AGENT_PORT injected
kubectl label namespace payments admission.datadoghq.com/enabled=true
```

No need to add env vars manually to every Deployment spec.

---

## 10. Datadog for ML / AI Workloads (LLM Observability)

Datadog has built LLM observability features — relevant for your AI platform work.

### LLM Observability

```python
from ddtrace.llmobs import LLMObs

LLMObs.enable(ml_app="fraud-rag-assistant", agentless_enabled=True)

# Trace an LLM call
with LLMObs.llm(model_name="gpt-4o", model_provider="openai", name="fraud_analysis") as span:
    response = openai_client.chat.completions.create(
        model="gpt-4o",
        messages=[{"role": "user", "content": prompt}]
    )
    LLMObs.annotate(
        span,
        input_data=prompt,
        output_data=response.choices[0].message.content,
        metadata={"temperature": 0.2, "fraud_score": score}
    )
```

Tracks automatically: token usage, cost per call, latency, model name, prompt/response.

### ML Model Monitoring

```python
# Send model prediction metrics to Datadog
statsd.histogram(
    'model.prediction.latency',
    inference_ms,
    tags=['model:fraud-v3', 'env:prod', 'version:3.1.2']
)
statsd.gauge(
    'model.prediction.confidence',
    confidence_score,
    tags=['model:fraud-v3', 'env:prod']
)
statsd.increment(
    'model.prediction.total',
    tags=['model:fraud-v3', 'env:prod', f'result:{prediction}']
)
```

Monitor: confidence score distribution, prediction latency SLO, error rate.

---

## 11. Datadog vs Dynatrace vs Prometheus+Grafana

This is asked in almost every observability interview.

### Comparison

| Factor | Datadog | Dynatrace | Prometheus + Grafana |
|---|---|---|---|
| **Type** | Commercial SaaS | Commercial SaaS | Open source, self-hosted |
| **Setup complexity** | Low — agent install, done | Medium — Operator + DynaKube CRD | High — Prometheus, Alertmanager, Grafana, Loki, Tempo all separate |
| **Auto-discovery** | Good — Kubernetes annotations | Excellent — OneAgent auto-instruments everything without config | Manual — scrape configs, service monitors |
| **APM** | Excellent — distributed tracing, service map, profiling | Excellent — PurePath tracing, Davis AI causation | Manual — Jaeger or Zipkin separate, no auto-service map |
| **AI/ML features** | Good — anomaly detection, forecasting | Excellent — Davis AI, causal root-cause, problem cards | None built-in |
| **Log management** | Built-in — index, archive, search, pipelines | Built-in — Grail data lake | Loki (separate component) |
| **Cost model** | Per host + per feature ($15-23/host/month + log/trace costs) | Per host (all features included in licence) | Infrastructure cost only (your VMs/storage) |
| **Cost at scale** | Can get expensive — log ingestion + custom metrics pricing | Expensive licence but predictable | Cheapest at scale — only infra cost |
| **Integrations** | 600+ — best ecosystem | 500+ | 200+ exporters |
| **On-prem support** | Datadog Agent on-prem, SaaS backend | Full on-prem (Managed) or SaaS | Fully self-hosted |
| **Security / CSPM** | Built-in (Cloud Security) | Built-in (KSPM, runtime) | Separate tools needed |
| **Kubernetes UX** | Excellent — container map, live containers, K8s events | Excellent — Kubernetes dashboard, Davis analysis | Good but requires multiple tools |
| **OpenTelemetry** | Full support — OTLP ingestion | Full support | Native — Prometheus is OTel backend |
| **Synthetics** | Excellent — uptime, browser, API tests | Built-in | Separate (Blackbox Exporter for simple) |

### When Customers Choose Each

**Datadog:**
- Startups to mid-size companies who want fast time-to-value
- Teams who value developer experience (easy setup, great UI)
- AWS/Azure/GCP native workloads — deep cloud integrations
- When you need logs + metrics + traces + synthetics in one tool

**Dynatrace:**
- Enterprises with complex Java/.NET monoliths (OneAgent auto-instruments everything)
- When you need AI-driven root-cause analysis (Davis AI is genuinely good)
- Regulated industries (finance, healthcare) — strong compliance features
- Voya uses Dynatrace — financial services, complex OpenShift platform

**Prometheus + Grafana:**
- Kubernetes-first teams who want full control
- Cost-sensitive at large scale (no per-host licensing)
- When you already have expertise in the OSS stack
- Works well WITH Datadog/Dynatrace for custom metrics (many companies run both)

### The Honest Answer for Interviews

*"The right choice depends on team maturity, scale, and budget. Datadog is faster to value — 30-minute setup, excellent UI, and 600+ integrations out of the box. Dynatrace has a stronger AI story and auto-instrumentation. Prometheus gives you full control and lowest cost at scale but requires significant operational investment. At Voya I operated Dynatrace at enterprise scale on OpenShift. I've worked with Prometheus+Grafana for Kubernetes metrics and understand the Datadog model well through architecture work."*

---

## 12. Common Datadog Interview Questions

### Q: How does Datadog Agent communicate with the platform?

```
Agent → HTTPS (443) → intake.datadoghq.com
All data outbound-only. No inbound connections required.
Agent buffers data locally if connectivity lost → sends when restored.
```

### Q: How do you reduce Datadog costs?

```
1. Log exclusion filters    — only index ERROR/WARN, archive DEBUG/INFO
2. Metric sampling          — custom metrics are expensive; use tags wisely
3. Log-to-metrics           — convert log patterns to metrics (cheaper than indexing logs)
4. Reduce cardinality       — high-cardinality tags create many unique metric series
5. Archive + rehydrate      — move old logs to S3, only rehydrate when investigating
6. Usage dashboard          — Datadog has built-in usage metrics (datadog.estimated_usage.*)
```

**Log-to-metric example:**
```
Convert logs with "ERROR" to a metric:
  Name: payment.error.count
  Filter: source:payment-api status:error
  Group by: service, env

This metric costs $0.05/custom metric/month vs $1.27/million logs indexed
```

### Q: How do you correlate a Datadog alert to a specific deployment?

```
1. Deployment events in Datadog:
   Use ddtrace or DD API to send deployment events:
   dog event post "Deployment payment-api v2.1.0" "Deployed to production" --tags version:2.1.0,env:prod

2. Version tag on all telemetry:
   DD_VERSION=2.1.0 set on pods → all metrics, logs, traces tagged with version

3. Deployment tracking dashboard:
   Overlay "version changed" events on error rate graph
   → visually see if error rate increased after deployment
```

### Q: What is Datadog APM sampling?

By default Datadog does NOT send every trace (too expensive, too noisy). It uses:

- **Head-based sampling** — decision made at first span (before trace completes)
  - Fast but may miss tail latency anomalies
- **Tail-based sampling (Intelligent Retention Filter)** — Datadog keeps 100% of error traces and slow traces
  - Ensures important traces aren't dropped even at high volume
- **Custom sampling rules** — keep 100% of traces for specific services/resources

```python
from ddtrace import tracer

tracer.configure(
    sampler=DatadogSampler(
        rules=[
            SamplingRule(sample_rate=1.0, service="payment-api"),   # 100% for payments
            SamplingRule(sample_rate=0.1, service="static-content"), # 10% for static
        ],
        default_sample_rate=0.1  # 10% for everything else
    )
)
```

### Q: Explain the difference between a metric, log, and trace. When do you use each?

```
Metric: aggregated numeric data over time
  → "What is happening?" at scale
  → CPU is 85%, error rate is 2%, request rate is 1200/sec
  → Cheap to store, fast to query, no context

Log: discrete event record with full context
  → "What exactly happened at this moment?"
  → Error message, stack trace, request parameters, user ID
  → Expensive to store and index, rich context

Trace: linked spans showing one request's journey through services
  → "Why is this request slow or failing?"
  → Distributed context, which service took how long, which DB query ran
  → Moderate cost, essential for debugging microservices

Workflow:
  Alert fires on metric (p99 > 500ms)
  → Open dashboard: which service, which endpoint?
  → Drill into traces: find slow traces, see which span is slow
  → Click log correlation: see exact log lines from those requests
  → Root cause: DB query missing index
```

---

## Quick Reference

| Concept | Answer |
|---|---|
| Datadog Agent | Runs on host/node — collects metrics, logs, traces, processes |
| DogStatsD | UDP port 8125 — receives custom metrics from apps |
| Trace Agent | TCP port 8126 — receives APM traces from instrumented apps |
| Cluster Agent | Single pod per cluster — aggregates K8s state metrics, reduces API server load |
| Tag cardinality | Unique values per tag key — high cardinality = cost explosion |
| Distribution metric | Server-side percentiles — more accurate p99 across fleet than Histogram |
| Log index | Fast searchable log store — expensive, keep only error/warn |
| Log archive | Cold storage (S3) — cheap, rehydrate when needed |
| Composite monitor | AND/OR logic across multiple monitors |
| Anomaly monitor | ML baseline — alerts on deviation, not fixed threshold |
| SLO burn rate | How fast error budget is being consumed vs normal rate |
| Admission Controller | Auto-injects DD APM env vars into pods — no manual Deployment changes |
| Tail-based sampling | Keep 100% of error + slow traces even at high volume |
