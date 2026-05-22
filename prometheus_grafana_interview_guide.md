# Prometheus & Grafana Interview Guide

**Target Role:** Senior/Principal Platform Engineer / SRE  
**Resume Anchor:** "Prometheus, Grafana" in observability skills; KEDA with Prometheus triggers at Voya; Dynatrace + Prometheus co-existing

---

## Architecture Overview

```
Prometheus Ecosystem:
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  Prometheus Server                                           │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │  │
│  │  │  Retrieval   │  │  TSDB        │  │  HTTP API        │  │  │
│  │  │  (scrape     │  │  (Time Series│  │  (query,         │  │  │
│  │  │   loop)      │  │   Database)  │  │   rules,         │  │  │
│  │  │              │  │  on-disk     │  │   targets)       │  │  │
│  │  └──────────────┘  └──────────────┘  └──────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────┘  │
│         │ scrape (pull model)              │ query                 │
│  ┌──────▼──────────────────────────┐       │                       │
│  │  Targets (expose /metrics)      │  ┌────▼──────┐               │
│  │  - Node Exporter (OS metrics)   │  │ Grafana   │               │
│  │  - kube-state-metrics (K8s)     │  │ (dashboards│               │
│  │  - DCGM Exporter (GPU)          │  │  alerts)  │               │
│  │  - App metrics (SDK)            │  └───────────┘               │
│  │  - KEDA (ScaledObject metrics)  │                               │
│  └─────────────────────────────────┘  ┌────────────┐              │
│                                        │ Alertmanager│              │
│                                        │ (route,     │              │
│                                        │  deduplicate│              │
│                                        │  → PD/Slack)│              │
│                                        └────────────┘              │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 1. Prometheus Data Model

### Time Series Structure

```
metric_name{label1="value1", label2="value2"} <float64_value> [<timestamp_ms>]

Examples:
  http_requests_total{method="POST", status="200", service="inference-api"} 1342
  container_memory_usage_bytes{pod="kserve-pod-abc", namespace="ml-platform"} 524288000
  DCGM_FI_DEV_GPU_UTIL{gpu="0", node="gpu-worker-0"} 87.3

Cardinality warning:
  Each unique label combination = one time series
  http_requests_total{user_id="..."} → millions of users = millions of series → OOM
  NEVER use high-cardinality values (user IDs, request IDs) as labels
```

### Metric Types

```
Counter:    Always increasing value (reset to 0 on restart)
            http_requests_total, errors_total, bytes_sent_total
            Use rate() to get per-second rate

Gauge:      Value that goes up and down
            memory_usage_bytes, active_connections, queue_depth, temperature
            Use directly or with avg/max/min

Histogram:  Samples observations into configurable buckets + sum + count
            request_duration_seconds_bucket{le="0.5"} 1234   (requests ≤ 500ms)
            request_duration_seconds_bucket{le="1.0"} 1456
            request_duration_seconds_bucket{le="+Inf"} 1500
            Use histogram_quantile() for percentiles

Summary:    Pre-calculated quantiles client-side (less flexible than histogram)
            request_duration_seconds{quantile="0.95"} 0.48
            Avoid: no cross-instance aggregation, fixed quantiles
```

---

## 2. PromQL — The Query Language

### Basic Selectors

```promql
# Instant vector: current value for matching series
http_requests_total

# Label matching
http_requests_total{status="200"}
http_requests_total{status!="200"}            # not equal
http_requests_total{status=~"5.."}            # regex: 5xx errors
http_requests_total{status!~"2.."}            # not 2xx

# Range vector: values over a time window [5m]
http_requests_total[5m]                       # used with rate(), increase()
```

### Rate Functions

```promql
# rate(): per-second rate, handles counter resets, use over >= 4× scrape interval
rate(http_requests_total[5m])

# irate(): instant rate (last 2 samples), good for spiky metrics
irate(http_requests_total[2m])

# increase(): total increase over time window (rate × duration)
increase(http_requests_total[1h])

# Example: requests per second for 5xx errors
rate(http_requests_total{status=~"5.."}[5m])
```

### Aggregation Operators

```promql
# sum across all instances
sum(rate(http_requests_total[5m]))

# sum by service (keep service label, drop all others)
sum by (service) (rate(http_requests_total[5m]))

# sum without instance (drop instance label, keep all others)
sum without (instance, pod) (rate(http_requests_total[5m]))

# Average CPU across all nodes
avg(node_cpu_usage_seconds_total)

# Top 5 pods by memory usage
topk(5, container_memory_usage_bytes{container!=""})

# Count of running pods per namespace
count by (namespace) (kube_pod_status_phase{phase="Running"})
```

### Percentile Queries (Histogram)

```promql
# p95 latency from histogram (most important for SLO monitoring)
histogram_quantile(0.95,
  sum by (le, service) (
    rate(http_request_duration_seconds_bucket[5m])
  )
)

# p99 inference latency
histogram_quantile(0.99,
  sum by (le) (
    rate(kserve_request_duration_seconds_bucket{service="churn-predictor"}[5m])
  )
)

# Note: must use rate() on _bucket metric before histogram_quantile
# Must include `le` label in the aggregation
```

### Practical SLO Queries

```promql
# Error rate (fraction of 5xx responses)
sum(rate(http_requests_total{status=~"5.."}[5m]))
/
sum(rate(http_requests_total[5m]))

# Availability (percentage of successful requests)
100 * (
  1 - (
    sum(rate(http_requests_total{status=~"5.."}[5m]))
    /
    sum(rate(http_requests_total[5m]))
  )
)

# Error budget burn rate (how fast consuming the budget)
# SLO target = 99.5%, error budget = 0.5%
(
  sum(rate(http_requests_total{status=~"5.."}[1h]))
  /
  sum(rate(http_requests_total[1h]))
) / 0.005    # divide by budget rate = burn rate multiplier

# GPU memory utilisation percentage
100 * (
  DCGM_FI_DEV_FB_USED
  /
  (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)
)

# KEDA trigger: inference queue depth per service
sum by (service) (kserve_request_queue_depth)
```

### Recording Rules (Pre-compute Expensive Queries)

```yaml
# prometheus-rules.yaml
groups:
  - name: slo_recording_rules
    interval: 60s
    rules:
      # Pre-compute error rate (used in multiple dashboards/alerts)
      - record: job:http_request_error_rate:rate5m
        expr: |
          sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
          /
          sum by (job) (rate(http_requests_total[5m]))

      # Pre-compute p95 latency
      - record: job:http_request_duration_p95:rate5m
        expr: |
          histogram_quantile(0.95,
            sum by (le, job) (rate(http_request_duration_seconds_bucket[5m]))
          )

      # GPU utilisation average per node
      - record: node:gpu_utilisation:avg
        expr: avg by (node) (DCGM_FI_DEV_GPU_UTIL)
```

---

## 3. Alerting

### Alert Rule Structure

```yaml
groups:
  - name: inference_alerts
    rules:

      # High error rate alert
      - alert: InferenceHighErrorRate
        expr: |
          sum(rate(http_requests_total{status=~"5..", job="inference-api"}[5m]))
          /
          sum(rate(http_requests_total{job="inference-api"}[5m]))
          > 0.01
        for: 5m                    # must be true for 5min before firing
        labels:
          severity: critical
          team: platform
        annotations:
          summary: "Inference API error rate {{ $value | humanizePercentage }}"
          description: "Service {{ $labels.service }} 5xx rate above 1% for 5 minutes"
          runbook: "https://wiki.company.com/runbooks/inference-errors"

      # SLO burn rate alert (fast burn)
      - alert: SLOFastBurnRate
        expr: |
          (
            sum(rate(http_requests_total{status=~"5.."}[1h]))
            / sum(rate(http_requests_total[1h]))
          ) / 0.005 > 14.4         # 14.4 = consumes budget in 5hrs (14.4×0.5%×720h=budget)
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "SLO error budget burning at {{ $value | humanize }}× rate"

      # GPU memory pressure
      - alert: GPUMemoryHigh
        expr: |
          100 * (
            DCGM_FI_DEV_FB_USED /
            (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)
          ) > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "GPU {{ $labels.gpu }} on {{ $labels.Hostname }} at {{ $value | humanize }}% memory"

      # Pod crash looping
      - alert: PodCrashLooping
        expr: |
          increase(kube_pod_container_status_restarts_total[15m]) > 3
        labels:
          severity: warning
        annotations:
          summary: "Pod {{ $labels.pod }} in {{ $labels.namespace }} is crash looping"
```

### Alertmanager Routing

```yaml
# alertmanager.yaml
global:
  slack_api_url: "https://hooks.slack.com/services/..."
  pagerduty_url: "https://events.pagerduty.com/v2/enqueue"

route:
  receiver: default-slack
  group_by: [alertname, namespace, severity]
  group_wait: 30s           # wait 30s for more alerts before sending grouped notification
  group_interval: 5m        # wait 5m before sending new notification for the same group
  repeat_interval: 4h       # re-notify every 4h if still firing

  routes:
    # Critical alerts → PagerDuty (wake someone up)
    - match:
        severity: critical
      receiver: pagerduty-platform
      continue: true          # also send to default-slack

    # GPU alerts → GPU team Slack channel
    - match:
        team: gpu
      receiver: slack-gpu-team

receivers:
  - name: default-slack
    slack_configs:
      - channel: "#platform-alerts"
        title: "{{ .GroupLabels.alertname }}"
        text: "{{ range .Alerts }}{{ .Annotations.description }}\n{{ end }}"

  - name: pagerduty-platform
    pagerduty_configs:
      - routing_key: "your-pagerduty-service-key"
        description: "{{ .GroupLabels.alertname }}: {{ .CommonAnnotations.summary }}"

inhibit_rules:
  # Don't alert on individual pods if the cluster is down
  - source_match:
      alertname: ClusterDown
    target_match_re:
      alertname: Pod.*
    equal: [cluster]
```

---

## 4. Kubernetes Monitoring Stack

### kube-state-metrics vs cAdvisor vs Node Exporter

```
What each component exposes:

cAdvisor (built into kubelet):
  - Container-level: CPU/memory/network/disk per container
  - Metrics: container_cpu_usage_seconds_total, container_memory_usage_bytes
  - Source: /metrics/cadvisor on kubelet port 10250

kube-state-metrics:
  - Kubernetes object state (not resource usage)
  - Metrics: kube_pod_status_phase, kube_deployment_replicas, kube_node_status_condition
  - Source: watches the K8s API

Node Exporter (DaemonSet):
  - Host-level: CPU, memory, disk, network, filesystem per NODE
  - Metrics: node_cpu_seconds_total, node_memory_MemAvailable_bytes
  - Source: /proc and /sys on the node

DCGM Exporter (DaemonSet on GPU nodes):
  - GPU metrics: utilisation, memory, temperature, power
  - Source: NVIDIA DCGM agent
```

### ServiceMonitor (Prometheus Operator)

```yaml
# Prometheus Operator discovers scrape targets via ServiceMonitor CRDs
# No need to edit prometheus.yaml directly

apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: inference-api-monitor
  namespace: ml-platform
  labels:
    app: inference-api                # must match Prometheus selector
spec:
  selector:
    matchLabels:
      app: inference-api             # selects Services with this label
  endpoints:
    - port: metrics                  # named port on the Service
      interval: 15s
      path: /metrics
      relabelings:
        # Add namespace label to all metrics from this target
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
  namespaceSelector:
    matchNames:
      - ml-platform
```

---

## 5. Grafana Deep Dive

### Dashboard Architecture

```
Grafana Dashboard:
┌─────────────────────────────────────────────────────────────────┐
│  Dashboard (JSON model, version-controlled)                     │
│  ├── Variables (template variables for filtering)               │
│  │   $namespace, $pod, $service → dropdown selectors            │
│  │                                                              │
│  ├── Row: "Overview"                                            │
│  │   ├── Stat Panel: Total RPS                                  │
│  │   ├── Stat Panel: Error Rate (threshold: 0→green, 1%→red)   │
│  │   └── Time Series: Request Rate by Service                   │
│  │                                                              │
│  ├── Row: "SLO Status"                                          │
│  │   ├── Gauge: Error Budget Remaining (%)                      │
│  │   └── Time Series: p95/p99 Latency                          │
│  │                                                              │
│  └── Row: "GPU Infrastructure"                                  │
│      ├── Heatmap: GPU utilisation across all nodes              │
│      └── Time Series: GPU Memory per pod                        │
└─────────────────────────────────────────────────────────────────┘
```

### Dashboard as Code (Grafonnet / Terraform)

```hcl
# Terraform: Grafana dashboard from JSON
resource "grafana_dashboard" "inference_platform" {
  config_json = file("${path.module}/dashboards/inference_platform.json")
  folder      = grafana_folder.platform.id
  overwrite   = true
}

# Best practice: store dashboard JSON in Git
# Use grafana-dashboard-provider ConfigMap in Kubernetes:
apiVersion: v1
kind: ConfigMap
metadata:
  name: inference-dashboards
  namespace: monitoring
  labels:
    grafana_dashboard: "1"     # Grafana sidecar picks up labeled ConfigMaps
data:
  inference-platform.json: |
    { "title": "ML Inference Platform", "panels": [...] }
```

### Key Panel Types

```
Stat Panel:     Single value, colour thresholds
                Good for: current error rate, RPS, active connections

Time Series:    Line chart over time
                Good for: latency trends, request rate, GPU utilisation

Gauge:          Circular fill from min to max with thresholds
                Good for: error budget remaining, disk usage

Heatmap:        Distribution over time
                Good for: request latency distribution (histogram)

Table:          Tabular data with transformations
                Good for: top-K pods by memory, alert status

Logs Panel:     Loki log stream
                Good for: last N error log lines
```

---

## 6. Prometheus on Kubernetes — Operational Concerns

### Storage Sizing

```
Prometheus storage estimate:
  bytes_per_sample ≈ 1.5–2 bytes (after compression)
  time_series × samples_per_day × retention_days × bytes_per_sample

Example:
  10,000 time series × 5760 samples/day (15s scrape) × 15 days × 2 bytes
  = 10,000 × 5,760 × 15 × 2 = 1,728,000,000 bytes ≈ 1.7 GB

Storage rule of thumb: 2 bytes × scrape_rate × retention_days
For large clusters (100K series): 15-30 GB for 15-day retention
```

```yaml
# PVC for Prometheus (use StorageClass with fast IOPS — SSD)
spec:
  volumeClaimTemplates:
    - metadata:
        name: prometheus-db
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: managed-premium    # Azure Premium SSD
        resources:
          requests:
            storage: 50Gi
```

### Federation vs Thanos vs VictoriaMetrics

```
Single Prometheus:    Up to ~1M active series, 15-day retention
                      Good for: team-level, single cluster

Federation:           Parent scrapes /federate endpoint from children
                      Aggregated view only (lossy — not all metrics)

Thanos:               Sidecar uploads TSDB blocks to object storage (S3/Blob)
                      Global query layer across all Prometheus instances
                      Long-term retention (years) at low cost
                      Good for: multi-cluster, long retention

VictoriaMetrics:      Drop-in Prometheus replacement, 10x more efficient
                      Remote Write target from Prometheus
                      Good for: cost reduction, very high cardinality
```

---

## 7. Interview Questions

**Q: Explain the difference between rate() and irate() in PromQL. When do you use each?**

A: Both calculate per-second rate of change of a counter, but differently:

`rate(metric[5m])`: uses all data points in the 5-minute window. Computes average per-second rate. Smooths out spikes. Required window: at least 4× scrape interval (if scraping every 15s, use `[1m]` minimum, `[5m]` recommended).

`irate(metric[2m])`: uses only the *last two data points* in the window (instant rate). Much more responsive to spikes. Can be noisy. Good for alerting on sudden spikes; poor for dashboards.

**Rule of thumb**: use `rate()` for dashboards and long-term trend analysis. Use `irate()` when you need to catch sudden traffic spikes in real-time.

```promql
# Smoothed 5-min rate (dashboard)
rate(http_requests_total[5m])

# Instant rate for spike alerting
irate(http_requests_total[2m]) > 1000
```

**Q: How do you avoid high cardinality in Prometheus?**

A: High cardinality = many unique label value combinations = many time series = Prometheus OOM.

Worst offenders: user IDs, request IDs, IP addresses, UUIDs as labels.

Prevention:
1. **Code review**: reject metrics that include user_id, order_id, trace_id as labels.
2. **Relabeling**: drop high-cardinality labels at the Prometheus scrape level before they enter the TSDB:
   ```yaml
   relabelings:
     - action: labeldrop
       regex: pod_template_hash  # drop auto-generated label
   ```
3. **Cardinality monitoring**: track `prometheus_tsdb_head_series` — alert if > 500K.
4. **Recording rules**: if you need detail, compute aggregations and record the result. Query the recording rule (low cardinality) instead of the raw metric (high cardinality).
5. **Logs for details**: user-level detail belongs in logs (with trace_id), not metrics. Metrics aggregate, logs detail.

**Q: Your Prometheus is consuming 20GB RAM. How do you diagnose and fix it?**

A: Diagnose:
```bash
# Check cardinality
curl http://prometheus:9090/api/v1/status/tsdb | jq '.data.headStats'
# headSeriesCount: current active series
# chunkCount: total chunks

# Find top metrics by cardinality
curl http://prometheus:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:20]'
# Identifies which metrics have the most series

# Cardinality by label
curl http://prometheus:9090/api/v1/status/tsdb | jq '.data.labelValueCountByLabelName'
```

Fix (in order of impact):
1. **Drop high-cardinality metrics**: if one metric has 500K series and you never query it, add a `metric_relabel_config` to drop it.
2. **Reduce retention**: if storing 90 days but only need 15, the TSDB grows proportionally.
3. **Reduce scrape frequency**: 15s → 30s for non-critical targets halves sample count.
4. **Use recording rules**: replace expensive repeated queries with pre-computed results.
5. **Migrate to Thanos or VictoriaMetrics**: Thanos ships blocks to object storage; VM uses less RAM per series.

**Q: How does KEDA use Prometheus as a trigger?**

A: KEDA's `ScaledObject` can use PromQL as the scaling trigger:

```yaml
triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus.monitoring:9090
      metricName: inference_queue_depth
      query: |
        sum(kserve_request_queue_depth{service="churn-predictor"})
      threshold: "5"    # scale up if queue depth > 5
      activationThreshold: "1"  # activate (scale from 0) if > 1
```

KEDA's external metrics adapter exposes the PromQL result as a Kubernetes custom metric. The HPA evaluates the metric against `threshold` and scales the deployment.

Use case at Voya: inference pods scale based on the request queue depth (not CPU — GPU pods are compute-bound, not CPU-bound). When queue > 5, KEDA adds another replica. When queue drops to 0, KEDA scales to `minReplicaCount=2`.

**Q: How do you set up multi-cluster monitoring with a single Grafana?**

A: Three approaches:

1. **Thanos Query**: each cluster's Prometheus has a Thanos sidecar. Thanos Query Hub federates across all. Grafana uses Thanos as a single datasource.

2. **Prometheus Remote Write → Central Prometheus**: each cluster's Prometheus writes metrics to a central Prometheus (or VictoriaMetrics). Central instance is the single Grafana datasource. Add `cluster` label during remote write to distinguish sources.

3. **Multiple datasources in Grafana**: add each cluster's Prometheus as a separate datasource in Grafana. Use Grafana's `$datasource` template variable to switch clusters in dashboards.

At Voya with OpenShift: used Thanos (OpenShift ships with Thanos built into the monitoring stack). Grafana connected to Thanos Query endpoint. Added `cluster=aro-prod` label at remote write level. Single Grafana dashboard shows all clusters with cluster filter dropdown.
