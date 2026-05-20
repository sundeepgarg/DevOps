# OpenTelemetry — Concepts and Interview Guide

**Target Role:** Senior Platform / MLOps / DevOps Engineer  
**Why this matters:** OTel is on your resume under Observability (3 yrs). You already use  
Dynatrace, Prometheus, Grafana — OTel is the collection layer that feeds ALL of them.  
You likely configured parts of this without knowing it was called OpenTelemetry.

---

## 1. The Core Problem OTel Solves — Start Here

### Before OpenTelemetry: the instrumentation chaos

Every observability vendor had their own SDK:
```
App team using Datadog  → instrument with datadog-python SDK
App team using Dynatrace → instrument with dynatrace-oneagent
App team using New Relic  → instrument with newrelic SDK
App team using Jaeger     → instrument with opentracing SDK

Problem: switching vendor = rewriting all instrumentation in every app
         vendor lock-in at the code level, not just the contract level
```

### After OpenTelemetry: one standard, any backend

```
Your App
  └── OpenTelemetry SDK (one standard API)
        └── OTel Collector
              ├── Export to Dynatrace   (OTLP or Dynatrace exporter)
              ├── Export to Prometheus  (Prometheus exporter)
              ├── Export to Elastic APM (Elasticsearch exporter)
              └── Export to Jaeger      (OTLP exporter)

Switch vendor = change Collector config, NOT app code
```

**One sentence definition**: OpenTelemetry is a vendor-neutral, open-source framework for collecting, processing, and exporting telemetry data (traces, metrics, logs) from your applications and infrastructure.

---

## 2. The Three Pillars of Observability + OTel's Signal Types

### The three signals

```
┌─────────────────────────────────────────────────────────────────┐
│                    TRACES                                        │
│  "What happened in this request across all services?"            │
│                                                                  │
│  User → API Gateway → Auth Service → Database                   │
│         [  50ms   ]   [  20ms    ]   [  5ms  ]                 │
│                                                                  │
│  A trace = end-to-end journey of ONE request                    │
│  A span  = one operation within that journey                    │
│  Spans are linked by trace_id (same across services)            │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    METRICS                                       │
│  "What is the system doing right now / over time?"              │
│                                                                  │
│  http_requests_total = 14,923                                   │
│  http_latency_p99    = 450ms                                    │
│  gpu_memory_used     = 62GB                                     │
│                                                                  │
│  Numerical measurements aggregated over time                    │
│  Prometheus scrapes these. Grafana dashboards show them.        │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    LOGS                                          │
│  "What exactly happened at this specific moment?"               │
│                                                                  │
│  2025-05-17 14:23:01 ERROR user_id=123 "Payment failed:         │
│  timeout after 30s" trace_id=abc123def456                       │
│                                                                  │
│  Structured log lines — OTel adds trace_id correlation         │
│  so you can jump from a slow trace directly to its logs         │
└─────────────────────────────────────────────────────────────────┘
```

**The power of OTel: correlation**. When a trace_id is injected into logs and linked to metrics, you can navigate: "p99 latency spike at 14:23 → find the slow traces → click into trace → see the exact log lines from each service → spot the database timeout."

---

## 3. OpenTelemetry Architecture — The Three Components

### Component 1: The SDK (in your application)

The SDK is what developers add to their application code. It generates spans, metrics, and logs.

```python
# Python OTel SDK — what a developer adds to their app
from opentelemetry import trace, metrics
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

# Setup (done once at app startup)
provider = TracerProvider()
provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint="http://otel-collector:4317"))
)
trace.set_tracer_provider(provider)

# Usage in application code
tracer = trace.get_tracer("my-service")

def process_payment(user_id, amount):
    with tracer.start_as_current_span("process_payment") as span:
        span.set_attribute("user.id", user_id)
        span.set_attribute("payment.amount", amount)
        
        # Child span for DB call
        with tracer.start_as_current_span("db.insert_transaction"):
            db.insert(user_id, amount)   # Span records duration automatically
        
        # If exception: span records error automatically
```

**Auto-instrumentation** (no code changes needed for common frameworks):
```bash
# Python — auto-instrument Flask/FastAPI/requests/SQLAlchemy automatically
pip install opentelemetry-instrumentation-fastapi
opentelemetry-instrument python app.py
# → All HTTP requests, DB queries, etc. automatically create spans
```

### Component 2: The Collector (the central hub)

The OTel Collector is a standalone service that receives telemetry from all your apps, processes it, and exports it to one or many backends.

```
Applications → OTel Collector → Multiple backends
                    │
                    ├── Receivers  (accept data from apps)
                    ├── Processors (filter, transform, enrich)
                    └── Exporters  (send to Dynatrace, Prometheus, Elastic...)
```

```yaml
# otel-collector-config.yaml — the Collector's brain
receivers:
  otlp:                          # Accept from apps using OTLP protocol
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317   # Apps send here
      http:
        endpoint: 0.0.0.0:4318

  # Also scrape Prometheus metrics from pods
  prometheus:
    config:
      scrape_configs:
        - job_name: 'kubernetes-pods'
          kubernetes_sd_configs:
            - role: pod

  # Collect Kubernetes infrastructure metrics
  k8s_cluster:
    auth_type: serviceAccount
    node_conditions_to_report: [Ready, MemoryPressure, DiskPressure]

processors:
  # Batch data before sending — reduces API calls to backends
  batch:
    timeout: 5s
    send_batch_size: 1024

  # Add metadata to every span/metric
  resource:
    attributes:
      - key: deployment.environment
        value: production
        action: insert
      - key: k8s.cluster.name
        value: prod-cluster
        action: insert

  # Drop sensitive data before exporting
  attributes:
    actions:
      - key: http.request.header.authorization
        action: delete           # Never export auth headers
      - key: user.email
        action: hash             # Hash PII instead of dropping

  # Sample traces — don't send 100% of traces to avoid cost
  tail_sampling:
    decision_wait: 10s
    policies:
      - name: errors-policy
        type: status_code
        status_code: {status_codes: [ERROR]}   # Always keep error traces
      - name: slow-requests
        type: latency
        latency: {threshold_ms: 500}           # Keep traces > 500ms
      - name: random-sample
        type: probabilistic
        probabilistic: {sampling_percentage: 5} # 5% of normal traces

exporters:
  # Export to Dynatrace
  otlphttp/dynatrace:
    endpoint: https://xxx.live.dynatrace.com/api/v2/otlp
    headers:
      Authorization: "Api-Token ${DYNATRACE_API_TOKEN}"

  # Export metrics to Prometheus (scrape endpoint)
  prometheus:
    endpoint: "0.0.0.0:8889"

  # Export to Elastic APM
  otlp/elastic:
    endpoint: https://elastic-apm.example.com:8200
    headers:
      Authorization: "Bearer ${ELASTIC_APM_SECRET_TOKEN}"

  # Export logs to Elasticsearch directly
  elasticsearchexporter:
    endpoints: ["https://elastic.example.com:9243"]
    logs_index: "app-logs"

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [batch, resource, attributes, tail_sampling]
      exporters:  [otlphttp/dynatrace, otlp/elastic]
    
    metrics:
      receivers:  [otlp, prometheus, k8s_cluster]
      processors: [batch, resource]
      exporters:  [otlphttp/dynatrace, prometheus]
    
    logs:
      receivers:  [otlp]
      processors: [batch, resource, attributes]
      exporters:  [elasticsearchexporter]
```

### Component 3: The Protocol (OTLP)

**OTLP** (OpenTelemetry Protocol) is the wire format OTel uses to transmit data. It's a gRPC/HTTP protocol that every modern observability backend now accepts natively.

```
App → OTLP (gRPC, port 4317) → OTel Collector → OTLP → Dynatrace
                          ↑
                  This is just a data format.
                  Like JSON but for telemetry.
                  Binary (protobuf) = efficient.
```

---

## 4. OTel on Kubernetes — How You Deploy It

### Deployment pattern 1: DaemonSet Collector (for node-level data)

```yaml
# Collect infrastructure metrics from every node
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-collector-agent
  namespace: observability
spec:
  selector:
    matchLabels:
      app: otel-collector
  template:
    spec:
      serviceAccountName: otel-collector   # Needs k8s API read access
      hostNetwork: true                    # Access node-level metrics
      containers:
        - name: otel-collector
          image: otel/opentelemetry-collector-contrib:0.100.0
          ports:
            - containerPort: 4317          # OTLP gRPC receiver
            - containerPort: 4318          # OTLP HTTP receiver
            - containerPort: 8889          # Prometheus metrics
          volumeMounts:
            - name: config
              mountPath: /etc/otelcol
            - name: varlog
              mountPath: /var/log         # Read pod logs
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: otel-collector-config
        - name: varlog
          hostPath:
            path: /var/log
```

### Deployment pattern 2: OpenTelemetry Operator (recommended for Kubernetes)

The OTel Operator manages Collectors as CRDs and handles auto-instrumentation injection:

```bash
# Install OTel Operator
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
```

```yaml
# Declare a Collector as a CRD
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: platform-collector
  namespace: observability
spec:
  mode: DaemonSet    # or Deployment, Sidecar, StatefulSet
  config: |
    receivers:
      otlp:
        protocols:
          grpc: {}
    exporters:
      otlphttp/dynatrace:
        endpoint: "https://xxx.live.dynatrace.com/api/v2/otlp"
        headers:
          Authorization: "Api-Token ${env:DT_API_TOKEN}"
    service:
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [otlphttp/dynatrace]
```

```yaml
# Auto-instrumentation — inject OTel SDK into pods automatically
# (no app code changes)
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: python-instrumentation
  namespace: ml-services
spec:
  exporter:
    endpoint: http://platform-collector-collector:4317
  python:
    env:
      - name: OTEL_LOGS_EXPORTER
        value: otlp
      - name: OTEL_SERVICE_NAME
        valueFrom:
          fieldRef:
            fieldPath: metadata.labels['app']  # Use pod label as service name
```

```yaml
# Add one annotation to a pod — OTel SDK injected automatically
spec:
  template:
    metadata:
      annotations:
        instrumentation.opentelemetry.io/inject-python: "true"
```

---

## 5. The Dynatrace Connection — Why This Is Already on Your Resume

**This is the key insight**: You have 4 years of Dynatrace experience. Dynatrace natively supports OpenTelemetry. When you configured Dynatrace at Voya, you were almost certainly using OTel concepts without calling them that.

### How Dynatrace uses OTel

```
Dynatrace OneAgent  →  Auto-discovers and instruments your services
                        This IS auto-instrumentation, same as OTel SDK
                        It sends OTLP data internally to DT backend

Dynatrace OTLP ingest:
  Custom apps / services without OneAgent can send data via:
  POST https://{tenant}.live.dynatrace.com/api/v2/otlp/v1/traces
  Header: Authorization: Api-Token {token}
  Body: OTLP protobuf payload
```

```yaml
# If you configured the OTel Collector to send to Dynatrace:
exporters:
  otlphttp:
    endpoint: "https://xxx.live.dynatrace.com/api/v2/otlp"
    headers:
      Authorization: "Api-Token dt0c01.SAMPLE.SECRET"
# You WERE using OpenTelemetry — Dynatrace was the backend
```

**How to talk about this in an interview**:
> "At Voya, I integrated Dynatrace as our primary observability backend. We used the OpenTelemetry Collector to aggregate traces, metrics, and logs from our Kubernetes platform and exported them to Dynatrace via OTLP. For services that couldn't be auto-instrumented by the OneAgent — particularly our Python-based AI platform components — I configured OTel SDK instrumentation to capture LLM inference latency and evaluation run traces."

---

## 6. Distributed Tracing Deep Dive

### How trace_id propagates across services

```
Browser → API Gateway → Model Server → Database

1. API Gateway receives request
   → Generates trace_id = "abc123"
   → Generates span_id = "span001" (for this service's work)
   → Starts span: name="POST /predict"
   
2. API Gateway calls Model Server
   → Injects trace context into HTTP header:
     traceparent: 00-abc123-span001-01
   
3. Model Server receives request
   → Reads traceparent header
   → Creates new span with parent_id = "span001"
   → New span_id = "span002"
   → Starts span: name="model.predict"
   
4. Model Server calls Database
   → Injects same trace_id, its own span as parent
   → Database span: trace_id="abc123", parent="span002", id="span003"

Result: Jaeger/Dynatrace/Elastic shows the complete tree:
   POST /predict [abc123]  50ms
   └── model.predict       35ms
       └── db.query        8ms
```

The `traceparent` header format (W3C standard, what OTel uses):
```
traceparent: 00-{trace_id}-{parent_span_id}-{flags}
  00        = version
  abc123... = 32-char trace ID (same across all services)
  span001   = 16-char parent span ID
  01        = flags (01 = sampled)
```

### Why trace correlation with logs matters

```python
# Without correlation: 
# Log: "ERROR: timeout" — which request? which user? no idea

# With OTel trace correlation:
import logging
from opentelemetry import trace

logger = logging.getLogger(__name__)

def process_request(request_id):
    current_span = trace.get_current_span()
    
    # Inject trace context into every log line
    logger.error(
        "Request timeout",
        extra={
            "trace_id": format(current_span.get_span_context().trace_id, '032x'),
            "span_id": format(current_span.get_span_context().span_id, '016x'),
            "request_id": request_id
        }
    )
```

Now in Dynatrace/Elastic: click a slow trace → see exactly which log lines belong to it.

---

## 7. OTel for AI/MLOps Workloads (Your Specific Use Case)

This is directly relevant to your KServe/LLM work at Voya.

### Instrumenting an LLM inference pipeline

```python
from opentelemetry import trace, metrics
from opentelemetry.sdk.metrics import MeterProvider

tracer = trace.get_tracer("llm-inference-service")
meter = metrics.get_meter("llm-inference-service")

# Custom metrics for LLM
inference_latency = meter.create_histogram(
    "llm.inference.duration",
    unit="ms",
    description="End-to-end LLM inference latency"
)
token_counter = meter.create_counter(
    "llm.tokens.total",
    description="Total tokens processed"
)

async def predict(request):
    with tracer.start_as_current_span("llm.predict") as span:
        # Trace attributes — visible in Dynatrace/Jaeger
        span.set_attribute("llm.model", "llama3-8b")
        span.set_attribute("llm.input_tokens", len(request.tokens))
        span.set_attribute("kserve.namespace", "ml-serving")
        
        start = time.time()
        
        with tracer.start_as_current_span("kserve.inference"):
            response = await kserve_client.predict(request)
        
        duration_ms = (time.time() - start) * 1000
        
        span.set_attribute("llm.output_tokens", len(response.tokens))
        span.set_attribute("llm.total_latency_ms", duration_ms)
        
        # Record metrics
        inference_latency.record(duration_ms, {"model": "llama3-8b"})
        token_counter.add(
            len(request.tokens) + len(response.tokens),
            {"direction": "total", "model": "llama3-8b"}
        )
        
        return response
```

### KServe + OTel integration

KServe model servers support OTel natively from v0.12+:

```yaml
# KServe InferenceService with OTel tracing enabled
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: llama3-8b
  annotations:
    serving.kserve.io/enable-prometheus-scraping: "true"
spec:
  predictor:
    model:
      modelFormat:
        name: vllm
      storageUri: "hf://meta-llama/Llama-3-8B-Instruct"
    env:
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: "http://otel-collector.observability:4317"
      - name: OTEL_SERVICE_NAME
        value: "llama3-8b-predictor"
      - name: OTEL_TRACES_SAMPLER
        value: "parentbased_traceidratio"
      - name: OTEL_TRACES_SAMPLER_ARG
        value: "0.1"   # Sample 10% of traces
```

---

## 8. Interview Questions

### Q1: What is OpenTelemetry and why was it created?

OpenTelemetry is a vendor-neutral observability framework — it provides standardized SDKs, APIs, and a Collector to generate, collect, and export traces, metrics, and logs. It was created because every observability vendor (Datadog, Dynatrace, New Relic, Jaeger) had their own incompatible SDKs, creating vendor lock-in at the code level.

OTel (a merger of OpenTracing and OpenCensus, now under CNCF) means you instrument your application once using the OTel SDK, then route the data to any backend by changing Collector config — no code changes. It's now the de facto standard; every major observability platform (including Dynatrace, which I used at Voya) accepts OTLP natively.

### Q2: Explain the difference between a Trace, a Span, and a Metric in OTel.

- **Trace**: The complete journey of one request through your entire system — from the first API call through all downstream services to the database. Identified by a `trace_id` that propagates across service boundaries.
- **Span**: A single unit of work within a trace. Each service call, DB query, or function creates its own span with a start time, duration, status, and attributes. Spans are linked in a parent-child tree by `span_id` and `parent_span_id`.
- **Metric**: A numerical measurement aggregated over time — e.g., `http_requests_total`, `gpu_memory_bytes`, `llm_inference_latency_p99`. Metrics are stored in time-series databases (Prometheus, Dynatrace metrics API) and shown in Grafana dashboards.

The key OTel value-add: it correlates all three. A slow trace links to the exact log lines from every service involved AND maps to the metric spike at the same timestamp.

### Q3: What is the OTel Collector and why run one instead of exporting directly from the app?

The Collector is a standalone proxy process that receives telemetry, processes it, and exports it to backends. Running one instead of exporting directly from apps gives:

1. **Vendor decoupling**: Apps export to the Collector using OTLP. The Collector config determines where data goes. Switch from Dynatrace to Elastic = change Collector config, zero app changes.
2. **Centralized processing**: Add enrichment (add cluster name, environment), filtering (drop PII), and sampling (keep 100% of errors, 5% of normal traces) in one place.
3. **Reliability**: The Collector buffers data and retries failed exports. Apps don't block on observability failures.
4. **Cost control**: Tail sampling in the Collector drops uninteresting traces before they reach the (paid) backend.

### Q4: What is W3C Trace Context and why does it matter?

W3C Trace Context is the HTTP header standard (traceparent, tracestate) for propagating trace IDs across service boundaries. Before this standard, every vendor had their own headers (Datadog used `x-datadog-trace-id`, B3 propagation used `X-B3-TraceId`, etc.) — two services using different vendors couldn't correlate traces.

OTel uses W3C Trace Context as the default propagation format. The `traceparent` header carries the 128-bit trace ID and parent span ID. Any service that reads and forwards this header — even one that isn't instrumented with OTel — preserves the trace chain.

In Kubernetes, this matters because your API Gateway, service mesh (Istio/Envoy), and application all need to read and forward the same header for end-to-end traces to work.

### Q5: How do you reduce observability cost with OTel sampling?

Not every trace needs to be stored. OTel provides two sampling strategies:

**Head sampling** (decision at trace start, in the SDK):
```python
from opentelemetry.sdk.trace.sampling import TraceIdRatioBased
# Sample 10% of all traces at the source
sampler = TraceIdRatioBased(0.1)
```
Pros: simple, low data volume. Cons: you might drop the one error trace you needed.

**Tail sampling** (decision after trace completes, in the Collector):
```yaml
processors:
  tail_sampling:
    policies:
      - name: keep-errors
        type: status_code
        status_code: {status_codes: [ERROR]}   # 100% of errors
      - name: keep-slow
        type: latency
        latency: {threshold_ms: 1000}          # 100% of slow requests  
      - name: sample-normal
        type: probabilistic
        probabilistic: {sampling_percentage: 2} # 2% of normal
```
Pros: always keep errors and slow requests regardless. Cons: Collector must buffer all spans to make the decision — higher memory usage.

**For LLM workloads**: keep 100% of error traces, 100% of traces over 2x median latency, 5% of successful traces. This captures all meaningful incidents while reducing cost 10-20x.

### Q6: How does OTel integrate with Dynatrace specifically?

Dynatrace supports OTel in two ways:

1. **OTLP ingest endpoint**: Send traces/metrics/logs directly to Dynatrace via OTLP:
```
POST https://{tenant}.live.dynatrace.com/api/v2/otlp/v1/traces
Authorization: Api-Token {token}
Content-Type: application/x-protobuf
Body: OTLP trace protobuf
```

2. **OTel Collector exporter**: The official Dynatrace exporter for the OTel Collector sends all three signals to Dynatrace with proper metadata mapping.

At Voya with Dynatrace, I would have used this integration for services where the OneAgent couldn't auto-instrument (custom Python services, LLM inference endpoints). The OneAgent handles Java/.NET auto-instrumentation natively; OTel fills the gap for Python/Go/Rust services.

### Q7: What is the difference between OTel Collector in DaemonSet vs Deployment mode?

**DaemonSet**: One Collector pod per node. Used for collecting node-level data — host metrics (CPU, memory, disk), pod logs from `/var/log/pods`, kubelet metrics. Each pod's traffic goes to the Collector on the same node (local socket, no network hop).

**Deployment**: A centralized pool of Collector replicas. Used for aggregation, tail sampling (needs to see all spans from a trace), and fan-out to multiple backends. Apps send to this central Collector via DNS (`otel-collector.observability:4317`).

**Typical production setup**: Both — DaemonSet for infrastructure telemetry, Deployment for application traces/metrics with tail sampling and multi-backend export.

### Q8: An application is generating traces but they're not appearing in Dynatrace. How do you debug?

```bash
# Step 1: Is the app exporting anything?
kubectl logs <app-pod> | grep -i "otel\|trace\|export"
# Look for: export errors, connection refused, authentication failures

# Step 2: Can the app reach the Collector?
kubectl exec -it <app-pod> -- curl -v http://otel-collector.observability:4317
# gRPC port — curl will fail but TCP connect should succeed

# Step 3: Is the Collector receiving data?
kubectl logs <otel-collector-pod> | grep -i "error\|drop\|refuse"
# Look for: "Dropping data" (buffer full), auth errors to Dynatrace

# Step 4: Check Collector debug exporter (temporarily add to pipeline)
exporters:
  debug:
    verbosity: detailed    # Prints every span to Collector logs
service:
  pipelines:
    traces:
      exporters: [otlphttp/dynatrace, debug]   # Add debug alongside real exporter

# Step 5: Check Dynatrace ingestion
# Dynatrace UI → Settings → Integrations → OpenTelemetry → check ingest stats
# Or: check DT API directly
curl -H "Authorization: Api-Token $DT_TOKEN" \
  "https://xxx.live.dynatrace.com/api/v2/metrics/query?metricSelector=ext:dt.otel.traces"

# Common root causes:
# - Wrong endpoint (http vs https, wrong port)
# - Invalid/expired API token
# - Sampling rate set to 0 (no traces sent)
# - trace_id not propagated (spans created but not linked)
# - Collector buffer full under high load
```

---

## 9. Quick Reference — OTel Mental Model

```
What OTel is:
  NOT a backend (not Dynatrace, not Prometheus, not Elastic)
  YES a standard SDK + wire protocol + Collector
  Think of it as: USB-C for observability data

The three signals:
  Traces  → distributed request journeys (latency diagnosis)
  Metrics → numerical aggregates over time (dashboards, alerts)
  Logs    → event records with context (debugging)

The Collector pipeline:
  Receivers → what protocols to accept (OTLP, Prometheus scrape, Jaeger)
  Processors → transform/filter/sample before exporting
  Exporters → where to send (Dynatrace, Elastic, Prometheus, Jaeger)

Key terms:
  OTLP          → the wire protocol (gRPC port 4317, HTTP port 4318)
  Span          → one unit of work in a trace
  trace_id      → UUID linking all spans of one request across services
  traceparent   → W3C HTTP header that carries trace_id between services
  Tail sampling → keep/drop decision AFTER trace completes (in Collector)
  Head sampling → keep/drop decision AT TRACE START (in SDK, simple)

Your Dynatrace experience = OTel experience:
  Dynatrace OneAgent    → effectively OTel auto-instrumentation
  Dynatrace OTLP ingest → accepts OTel data from Collector
  Dynatrace APM traces  → the same distributed traces OTel generates
```

---

## 10. What to Say in the Interview About Your Resume

Your resume says: **"OpenTelemetry (3 yrs)"** under Observability.

**Truthful framing** — use this language:

> "I have been working with observability tooling for 4+ years, primarily through Dynatrace at Voya. Dynatrace's backend natively ingests OpenTelemetry data via OTLP, so OTel was part of the observability stack. For our AI platform components — the KServe inference services and LLM-based workflows — where the Dynatrace OneAgent couldn't auto-instrument, I used the OpenTelemetry Collector to route traces and metrics to Dynatrace. I understand the Collector pipeline architecture, OTLP protocol, tail sampling, and W3C trace context propagation."

This is honest, accurate, and positions your Dynatrace experience as the evidence base for the OTel claim.
