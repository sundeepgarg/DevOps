# ELK Stack Interview Guide

**Covers:** Elasticsearch, Logstash, Kibana, Beats, EFK stack, OpenSearch, architecture,
data flow, and interview Q&A.

---

## 1. What is the ELK Stack?

```
ELK = Elasticsearch + Logstash + Kibana

E — Elasticsearch:  Search and analytics engine. Stores, indexes, queries data.
L — Logstash:       Data pipeline. Collects, transforms, enriches, forwards data.
K — Kibana:         Visualisation layer. Dashboards, search UI, alerting.

Together: ingest logs/metrics from anywhere → parse and enrich → store searchably → visualise

Modern variants:
  EFK Stack:   Elasticsearch + Fluentd/Filebeat + Kibana (Logstash replaced)
  OpenSearch:  AWS fork of Elasticsearch (after Elastic changed licence in 2021)
  Elastic Stack: Official name (Elastic added Beats, APM, security features)
```

### Why ELK Exists

```
The problem before ELK:
  100 servers each write logs to /var/log/app.log
  When error occurs: SSH into each server, grep through files
  "Find all 500 errors in the last 10 minutes across all servers"
  → hours of work, often impossible

With ELK:
  All logs shipped to Elasticsearch in real-time
  Kibana search: response_status:500 AND @timestamp:[now-10m TO now]
  → results in seconds, across ALL servers, with graphs

Key capabilities:
  Full-text search:      grep at petabyte scale in milliseconds
  Structured search:     query by field (status_code=500, user_id=123)
  Aggregations:          count, sum, avg, percentile, date histogram
  Visualisation:         time-series graphs, pie charts, geo maps
  Alerting:              notify when query threshold exceeded
```

---

## 2. Elasticsearch — Deep Dive

### Core Concepts

```
Document:   The unit of data. JSON object stored in Elasticsearch.
            Like a row in a database table.
            Example:
            {
              "@timestamp": "2024-01-15T14:32:01Z",
              "level": "ERROR",
              "service": "payment-api",
              "message": "Connection timeout after 5000ms",
              "pod": "payment-api-abc123",
              "namespace": "production",
              "http_status": 500
            }

Index:      Collection of documents with similar structure.
            Like a database table (but schema-flexible).
            Each index has a name: logs-2024.01.15, metrics-2024.01

Mapping:    Schema definition for an index.
            Defines field types: keyword, text, integer, date, boolean, geo_point
            Auto-created on first document (dynamic mapping)
            Better to define explicitly (avoid type conflicts)

Field types:
  text:     full-text searchable, tokenised, analysed
            "Payment timeout error" → tokens: [payment, timeout, error]
            Use for: log messages, descriptions you want to search by words

  keyword:  exact-match only, not tokenised
            "payment-api" stays as "payment-api"
            Use for: status codes, service names, IDs, enums
            Enables: aggregations, sorting, filtering

  date:     ISO 8601 or epoch, enables time-range queries
  integer/float: numeric, enables range queries and aggregations
  boolean:  true/false
  geo_point: latitude/longitude — enables geo distance queries
```

### Inverted Index — Why ES is Fast

```
How traditional databases search (slow for full-text):
  SELECT * FROM logs WHERE message LIKE '%timeout%'
  → scan every row, check every message → O(n) scan

Elasticsearch inverted index:
  Normal index (forward):  document → words
    Doc 1: "connection timeout error"
    Doc 2: "timeout after 5000ms"
    Doc 3: "payment success"

  Inverted index:          word → documents
    "connection" → [Doc 1]
    "timeout"    → [Doc 1, Doc 2]   ← looking up "timeout" = instant
    "error"      → [Doc 1]
    "payment"    → [Doc 3]
    "success"    → [Doc 3]

  Search "timeout":
    → Look up "timeout" in inverted index → [Doc 1, Doc 2]
    → Return those documents
    → O(1) lookup regardless of how many documents exist!

  Search "payment timeout":
    → "payment" → [Doc 3]
    → "timeout" → [Doc 1, Doc 2]
    → Intersection or union depending on operator
    → AND: no match; OR: [Doc 1, Doc 2, Doc 3]

Text Analysis pipeline (before storing):
  Input text:   "Connection Timeout Error: 5000ms exceeded!"
  Tokenise:     ["Connection", "Timeout", "Error", "5000ms", "exceeded"]
  Lowercase:    ["connection", "timeout", "error", "5000ms", "exceeded"]
  Remove stops: ["connection", "timeout", "error", "5000ms", "exceeded"]
  Stem:         ["connect", "timeout", "error", "5000ms", "exceed"]
  Store in inverted index
```

### Elasticsearch Cluster Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Elasticsearch Cluster                                 │
│                                                                          │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐                  │
│  │   Node 1    │   │   Node 2    │   │   Node 3    │                  │
│  │  Master ★   │   │   Data      │   │   Data      │                  │
│  │  Data       │   │   Ingest    │   │   Ingest    │                  │
│  │             │   │             │   │             │                  │
│  │ Shard P0    │   │ Shard P1    │   │ Shard P2    │  ← Primary shards│
│  │ Shard R1    │   │ Shard R2    │   │ Shard R0    │  ← Replica shards│
│  │ Shard R2    │   │ Shard R0    │   │ Shard R1    │                  │
│  └─────────────┘   └─────────────┘   └─────────────┘                  │
└─────────────────────────────────────────────────────────────────────────┘

Master node:   Manages cluster state (which nodes exist, which shards where)
               Performs index creation/deletion, node add/remove
               Should NOT do heavy data work (dedicate master nodes in prod)

Data node:     Stores shards, executes search/aggregation queries
               Most nodes are data nodes

Ingest node:   Pre-processes documents before indexing (like a mini-Logstash)
               Runs ingest pipelines (grok, date, convert, enrich)
               Offloads transformation from data nodes

Coordinating node: Routes requests to correct shards, merges results
                   Every node acts as coordinating node by default
```

### Shards and Replicas

```
Index: logs-2024.01 (10 million documents)
         │
         ├── Primary Shard 0  (Node 1) → documents 1-2M
         ├── Primary Shard 1  (Node 2) → documents 2M-4M
         ├── Primary Shard 2  (Node 3) → documents 4M-6M
         ├── Primary Shard 3  (Node 1) → documents 6M-8M
         ├── Primary Shard 4  (Node 2) → documents 8M-10M
         │
         ├── Replica Shard 0  (Node 2) → copy of Primary 0
         ├── Replica Shard 1  (Node 3) → copy of Primary 1
         ├── Replica Shard 2  (Node 1) → copy of Primary 2
         ├── Replica Shard 3  (Node 2) → copy of Primary 3
         └── Replica Shard 4  (Node 3) → copy of Primary 4

Rules:
  Primary and its replica are NEVER on the same node (HA)
  Read: can serve from primary OR replica (read scalability)
  Write: goes to primary → primary replicates to replica

Shard sizing:
  Too few shards: large shards → slow queries, can't parallelise
  Too many shards: overhead per shard → slow cluster
  Recommended: 10-50GB per shard for logs
  Typical index: 5 primary shards → 5 nodes can query in parallel

Replicas:
  0 replicas: no HA (lose node = lose data for that shard)
  1 replica:  can survive 1 node failure (standard production)
  2 replicas: can survive 2 node failures simultaneously

Cannot reduce number of primary shards after index creation.
Plan shards at index creation time (or use rollover + aliases).
```

### Index Lifecycle Management (ILM)

```
Logs grow indefinitely → manage automatically with ILM policies

Phases:
  Hot:     Active indexing + querying. Fast SSD nodes. Rollover when > 50GB or 30 days.
  Warm:    No new writes. Still queried. Can move to cheaper HDD nodes. Force merge.
  Cold:    Infrequent queries. Frozen / searchable snapshot. Very cheap storage.
  Frozen:  Fully on object storage (S3/Azure Blob). Query on demand (slow).
  Delete:  Remove entirely.

Timeline example (90-day retention):
  Days 0-7:    Hot phase — today's logs, fast SSD, full replicas
  Days 7-30:   Warm phase — recent history, slower storage, searchable
  Days 30-90:  Cold phase — compliance archive, S3-backed searchable snapshots
  Day 90:      Delete

ILM policy (Kibana Dev Tools):
PUT _ilm/policy/logs-policy
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": { "max_size": "50GB", "max_age": "7d" },
          "set_priority": { "priority": 100 }
        }
      },
      "warm": {
        "min_age": "7d",
        "actions": {
          "shrink": { "number_of_shards": 1 },
          "forcemerge": { "max_num_segments": 1 },
          "set_priority": { "priority": 50 }
        }
      },
      "delete": {
        "min_age": "90d",
        "actions": { "delete": {} }
      }
    }
  }
}
```

---

## 3. Logstash — Data Pipeline

### Architecture

```
Input → Queue → Filter → Output

Input:    WHERE does data come from?
          Beats (Filebeat, Metricbeat), Kafka, TCP/UDP syslog, S3, JDBC, HTTP

Queue:    Internal buffer (in-memory or persistent)
          Decouples input from filter/output
          Persistent queue: survives Logstash restart (important for production)

Filter:   Transform, parse, enrich data
          grok:     parse unstructured text with patterns
          date:     parse timestamp strings to @timestamp
          mutate:   rename, convert, remove fields
          geoip:    add geolocation from IP address
          dns:      resolve hostnames
          fingerprint: generate unique ID from fields
          drop:     discard matching events (reduce noise/cost)

Output:   WHERE does data go?
          Elasticsearch (primary), Kafka, S3, stdout (debugging)
```

### Logstash Pipeline Configuration

```ruby
# /etc/logstash/conf.d/nginx-logs.conf

input {
  beats {
    port => 5044          # receive from Filebeat
    ssl => true
    ssl_certificate => "/etc/ssl/certs/logstash.crt"
    ssl_key => "/etc/ssl/private/logstash.key"
  }

  # Also receive syslog
  udp {
    port => 5140
    codec => "plain"
    type => "syslog"
  }
}

filter {
  # Parse Nginx access log format
  if [fields][log_type] == "nginx" {
    grok {
      match => {
        "message" => '%{IPORHOST:client_ip} - %{DATA:user} \[%{HTTPDATE:timestamp}\] "%{WORD:method} %{URIPATHPARAM:request} HTTP/%{NUMBER:http_version}" %{NUMBER:response_code:int} %{NUMBER:bytes_sent:int} "%{DATA:referrer}" "%{DATA:user_agent}"'
      }
      tag_on_failure => ["_grokparsefailure"]  # tag failed parses
    }

    # Parse the timestamp into @timestamp
    date {
      match => ["timestamp", "dd/MMM/yyyy:HH:mm:ss Z"]
      target => "@timestamp"
      remove_field => "timestamp"              # clean up original field
    }

    # Add geo location from client IP
    geoip {
      source => "client_ip"
      target => "geoip"
      fields => ["city_name", "country_name", "latitude", "longitude"]
    }

    # Convert response code to integer for range queries
    mutate {
      convert => { "response_code" => "integer" }
      convert => { "bytes_sent" => "integer" }
      # Rename for clarity
      rename => { "client_ip" => "source.ip" }
      # Add custom fields
      add_field => {
        "environment" => "%{[fields][env]}"
        "[@metadata][index_prefix]" => "nginx-logs"
      }
    }

    # Drop health check requests (reduce noise)
    if [request] =~ "/health" {
      drop {}
    }

    # Classify slow requests
    if [request_time] and [request_time] > 2 {
      mutate { add_tag => ["slow_request"] }
    }
  }

  # Parse JSON application logs
  if [fields][log_type] == "application" {
    json {
      source => "message"
      target => "app"          # parsed JSON → app.* fields
    }
    # Promote important nested fields
    mutate {
      copy => { "[app][level]" => "log.level" }
      copy => { "[app][trace_id]" => "trace.id" }
    }
  }

  # Always: remove noisy fields
  mutate {
    remove_field => ["agent", "ecs", "input", "host.name"]
  }
}

output {
  if "_grokparsefailure" in [tags] {
    # Send parse failures to a separate index for debugging
    elasticsearch {
      hosts => ["https://elasticsearch:9200"]
      index => "logstash-parse-failures-%{+YYYY.MM.dd}"
      user => "logstash_writer"
      password => "${LOGSTASH_PASSWORD}"
    }
  } else {
    elasticsearch {
      hosts => ["https://elasticsearch:9200"]
      index => "%{[@metadata][index_prefix]}-%{+YYYY.MM.dd}"
      # Template for ILM
      ilm_enabled => true
      ilm_rollover_alias => "nginx-logs"
      ilm_policy => "logs-policy"
      # Credentials
      user => "logstash_writer"
      password => "${LOGSTASH_PASSWORD}"
      # Performance
      action => "index"
      pipeline => "add-cluster-metadata"   # ingest pipeline in ES
    }
  }

  # Mirror to stdout for debugging (remove in production)
  # stdout { codec => rubydebug }
}
```

### Grok Patterns

```
Grok = regex with named capture groups + built-in pattern library

Syntax: %{PATTERN_NAME:field_name:data_type}

Built-in patterns:
  %{IP}           → matches IP addresses
  %{NUMBER}       → matches numbers
  %{WORD}         → matches word characters [a-zA-Z0-9_]
  %{DATA}         → matches any character (non-greedy)
  %{GREEDYDATA}   → matches everything to end of line
  %{HTTPDATE}     → 15/Jan/2024:14:32:01 +0000
  %{IPORHOST}     → IP or hostname
  %{URIPATHPARAM} → /path?query=string
  %{LOGLEVEL}     → DEBUG|INFO|WARN|ERROR|FATAL
  %{TIMESTAMP_ISO8601} → 2024-01-15T14:32:01.000Z

Example — parse application log:
  Input: "2024-01-15 14:32:01 ERROR PaymentService - Connection timeout after 5000ms"
  
  Pattern: "%{TIMESTAMP_ISO8601:timestamp} %{LOGLEVEL:level} %{WORD:service} - %{GREEDYDATA:message}"
  
  Result:
    timestamp: "2024-01-15 14:32:01"
    level:     "ERROR"
    service:   "PaymentService"
    message:   "Connection timeout after 5000ms"

Test grok patterns: https://grokdebug.io (paste log line, test pattern)
```

---

## 4. Beats — Lightweight Data Shippers

```
Beats = single-purpose Go agents installed on hosts/containers.
Much lighter than Logstash (< 50MB RAM vs 500MB+).
Ship data directly to Elasticsearch or via Logstash for processing.

Filebeat:      Tails log files and forwards to Elasticsearch/Logstash
               Auto-detects: nginx, apache, syslog, docker, Kubernetes
               Handles: multiline logs (stack traces), log rotation

Metricbeat:    System and service metrics (CPU, memory, disk, network)
               Module-based: nginx module, MySQL module, Kubernetes module
               Replaces: collectd, statsd for basic metrics

Packetbeat:    Network packet analyser (HTTP, DNS, MySQL, Redis traffic)
               Zero-code visibility into service communication

Auditbeat:     Sends Linux audit framework data to Elasticsearch
               File integrity monitoring, user activity

Heartbeat:     Uptime monitoring (ping HTTP/TCP/ICMP endpoints)
               Powers Kibana Uptime app

Filebeat vs Logstash:
  Filebeat:   lightweight shipper, limited parsing, use for shipping
  Logstash:   heavy processing, complex transformations, use for parsing
  Common pattern: Filebeat ships → Logstash parses → Elasticsearch stores
```

### Filebeat Configuration

```yaml
# filebeat.yml — on every Kubernetes node (DaemonSet)
filebeat.autodiscover:
  providers:
    - type: kubernetes
      node: ${NODE_NAME}
      hints.enabled: true        # read config from pod annotations
      hints.default_config:
        type: container
        paths:
          - /var/log/containers/*${data.kubernetes.container.id}.log
      templates:
        - condition:
            equals:
              kubernetes.namespace: production
          config:
            - type: container
              paths:
                - /var/log/containers/*${data.kubernetes.container.id}.log
              json.keys_under_root: true   # parse JSON logs automatically
              json.add_error_key: true

processors:
  - add_kubernetes_metadata:    # add pod name, namespace, labels to every event
      host: ${NODE_NAME}
      matchers:
        - logs_path:
            logs_path: "/var/log/containers/"
  - drop_fields:
      fields: ["agent.ephemeral_id", "ecs.version"]

output.logstash:
  hosts: ["logstash:5044"]
  ssl.enabled: true
  ssl.certificate_authorities: ["/etc/ssl/certs/ca.crt"]
  # Backpressure: if Logstash is slow, Filebeat queues in registry
  # No log loss even during Logstash restarts
```

---

## 5. Full ELK Data Flow

```
Kubernetes Cluster
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                           │
│  App Pod (payment-api)      App Pod (fraud-service)    ... 200 pods      │
│  stdout → /var/log/         stdout → /var/log/                           │
│               │                          │                               │
│          ┌────▼──────────────────────────▼────────────────────────────┐ │
│          │            Filebeat DaemonSet (1 per node)                  │ │
│          │  tail log files → add k8s metadata → send to Logstash      │ │
│          └──────────────────────────────────────────────────────────-─┘ │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              │ TCP 5044 (beats protocol)
                              ▼
┌────────────────────────────────────────────┐
│          Logstash Cluster (3 nodes)         │
│  Input → Queue → Filter (grok/date/geoip)  │
│  → Enrich → Route to correct index         │
└────────────────────────┬───────────────────┘
                         │ HTTPS 9200
                         ▼
┌────────────────────────────────────────────────────────────────┐
│           Elasticsearch Cluster (3+ nodes)                      │
│                                                                  │
│  Index: logs-production-2024.01.15                              │
│    Shard 0 (Node 1)  Shard 1 (Node 2)  Shard 2 (Node 3)        │
│    Replica 0 (Node 2) Replica 1 (Node 3) Replica 2 (Node 1)    │
│                                                                  │
│  ILM: Hot → Warm (7d) → Delete (90d)                           │
└────────────────────────────────────────────────────────────────┘
                         │
                         │ HTTP 5601
                         ▼
┌──────────────────────────────────────────────────┐
│              Kibana                               │
│  Discover:    search logs in real-time            │
│  Dashboards:  error rate graphs, geo maps         │
│  Alerts:      notify when error rate > threshold  │
│  APM:         application performance tracing     │
│  SIEM:        security event analysis             │
└──────────────────────────────────────────────────┘
```

---

## 6. Kibana — Complete Deep Dive

### 6.1 What Kibana Is

```
Kibana = the browser-based UI layer of the Elastic Stack.

Connects to Elasticsearch over HTTP (port 9200) and provides:
  Discover:      Search and explore raw log/event data
  Dashboards:    Build visual analytics from ES aggregations
  Lens:          Drag-and-drop visualisation builder
  Maps:          Geo-visualisation on world maps
  Alerting:      Rules that fire when query thresholds are breached
  APM:           Application performance monitoring (traces, services)
  Observability: Unified Logs + Metrics + APM + Uptime
  Security/SIEM: Threat detection, timeline investigation
  ML:            Anomaly detection, forecasting
  Dev Tools:     Console to run raw Elasticsearch queries
  Stack Mgmt:    Index patterns, ILM, snapshots, users, roles
  Spaces:        Multi-tenancy — separate dashboards per team

Architecture:
  Browser → Kibana server (port 5601) → Elasticsearch (port 9200)
  Kibana itself is stateless — all data lives in Elasticsearch
  Kibana config, dashboards, saved searches stored in .kibana index in ES
```

### 6.2 Data Views (Index Patterns)

```
Before you can use Discover or build dashboards, Kibana needs to know
WHICH indices to query. This is configured as a Data View (formerly Index Pattern).

Create a Data View:
  Stack Management → Data Views → Create data view
  Name:        logs-*                    ← wildcard matches logs-2024.01.15, logs-2024.01.16...
  Timestamp:   @timestamp               ← time field for time-range filtering
  Save → now available in Discover, Lens, Dashboards

Multiple Data Views:
  logs-*               → application logs
  metrics-*            → infrastructure metrics
  apm-*                → APM traces
  .alerts-*            → Kibana alert events

Mapping refresh:
  If you add new fields to ES, Kibana doesn't see them immediately.
  Stack Mgmt → Data Views → select → Refresh field list
```

### 6.3 Discover — Log Search and Exploration

```
Discover is your primary tool for ad-hoc log investigation.

Layout:
  Time filter (top right): Last 15 min, Last 24h, custom range
  Search bar:              KQL or Lucene query
  Field list (left):       All fields in the index, with quick filters
  Document table:          Matching log lines, expandable
  Histogram (top):         Event count over time (click to zoom into time range)
```

**KQL — Kibana Query Language:**

```
Basic field match (exact, case-insensitive):
  level: "ERROR"
  service.name: "payment-api"
  kubernetes.namespace: "production"

Numeric comparison:
  http.response.status_code: 500
  http.response.status_code >= 500
  response_time_ms > 2000

Range:
  http.response.status_code >= 500 AND http.response.status_code < 600
  @timestamp >= "2024-01-15T14:00:00" AND @timestamp <= "2024-01-15T15:00:00"

Full-text search (searches all text fields):
  "connection timeout"
  "NullPointerException"

Wildcard:
  service.name: "payment*"       ← starts with payment
  message: "*timeout*"           ← contains timeout

Field exists:
  trace.id: *                    ← field has any value
  NOT error.stack_trace: *       ← field is missing

Boolean logic:
  level: "ERROR" AND service.name: "payment-api"
  level: ("ERROR" OR "FATAL")
  NOT level: "DEBUG"
  (level: "ERROR" OR response_code >= 500) AND namespace: "production"

Nested fields:
  kubernetes.pod.name: "payment-api-abc123"
  kubernetes.labels.app: "payment"
```

**Saved Searches:**
```
Once you craft a useful KQL query + column selection:
  Click "Save" → name it "Production Errors"
  Reuse in dashboards as a pre-filtered table panel
  Share URL with team members (URL encodes the query + time range)
```

### 6.4 Lens — Visual Analytics Builder

```
Lens is the modern drag-and-drop visualisation editor.
Replaced TSVB and Aggregation-based editors for most use cases.

Workflow:
  1. Choose chart type (Area, Bar, Line, Metric, Pie, Table, Heatmap, Gauge)
  2. Drag fields from the left panel onto X-axis, Y-axis, or breakdown
  3. Configure aggregations on each axis
  4. Save → add to dashboard

Common visualisation patterns:
```

**Line chart — Error rate over time:**
```
Chart type: Line
X-axis:     @timestamp (date histogram, auto interval)
Y-axis:     Count of records (where level: "ERROR")
Split by:   service.name (top 5 values)

Result: time-series lines, one per service, showing error frequency
```

**Bar chart — Top 10 slowest endpoints:**
```
Chart type: Horizontal bar
Y-axis:     request.path.keyword (top 10 values by count)
X-axis:     Average of response_time_ms
Color by:   http.response.status_code range (2xx=green, 5xx=red)
```

**Data table — Error breakdown:**
```
Columns:
  service.name        (top 50)
  level               (breakdown)
  Count               (metric: count())
  Avg response time   (metric: average(response_time_ms))
  95th percentile     (metric: percentile(response_time_ms, 95))

Sorted by Count descending
```

**Metric panel — Single KPI:**
```
Chart type: Metric
Metric:     Count of documents (where level: "ERROR")
Time:       Last 15 minutes
Comparison: vs previous 15 minutes (shows % change: ▲ 23%)
```

**Gauge / Goal:**
```
Chart type: Gauge
Metric:     Average of p99_latency_ms
Ranges:
  0-200ms   → Green (good)
  200-500ms → Yellow (warning)
  500ms+    → Red (critical)
```

### 6.5 Dashboards

```
Dashboard = collection of panels (Lens visualisations, saved searches, Maps, Markdown)
Panels share the time filter and any applied KQL filters.

Dashboard design pattern (SRE-style):
  Row 1: Service Health Overview
    ├── Total requests/min (Metric)
    ├── Error rate % (Gauge — green/yellow/red)
    └── P99 latency ms (Metric)

  Row 2: Time Series
    ├── Request rate over time (Line — split by service)
    ├── Error rate over time (Area — split by service)
    └── Latency percentiles (Line — p50/p95/p99)

  Row 3: Infrastructure
    ├── Pod count by namespace (Bar)
    ├── CPU usage by node (Heat map)
    └── Memory pressure events (Data table)

  Row 4: Top Issues
    ├── Top 10 error messages (Data table)
    ├── Slowest endpoints (Horizontal bar)
    └── Error distribution by status code (Pie)

  Row 5: Geo & Users
    └── Request origins on world map (Maps panel)
```

**Dashboard Controls (filters):**
```
Add controls to let users filter the dashboard without editing:
  Options list: select namespace from dropdown → all panels update
  Range slider:  slide response_time_ms range → filter all panels

Controls sit at the top of the dashboard.
Clicking a value in any panel also applies it as a global dashboard filter.
```

**Dashboard variables via URL:**
```
Every Kibana dashboard has a URL that encodes:
  time range, KQL filters, panel layout

Share a pre-filtered view:
  https://kibana:5601/app/dashboards#/view/123?_g=(filters:!(),time:(from:now-1h,to:now))
  &_a=(filters:!((query:(match_phrase:(service.name:payment-api)))))
```

### 6.6 Maps — Geo Visualisation

```
Kibana Maps uses Elasticsearch geo_point fields.

Layers:
  Document layer:  plot each log event as a dot on the map (source IP)
  Cluster layer:   group nearby events into circles (size = count)
  Heat map layer:  colour intensity shows event density per region
  Choropleth:      colour fill country/region by metric value

Use cases:
  Incoming request geography → spot unusual traffic from unexpected regions
  DDoS investigation → see attack source IPs on map, correlate with time
  User distribution → where are our users? do we need a CDN PoP here?

Setup requirement:
  Logstash/Ingest pipeline must run geoip filter on source IP field
  Field type in mapping must be geo_point
```

### 6.7 APM — Application Performance Monitoring

```
Kibana APM = distributed tracing + service performance analytics.
Requires Elastic APM agents in your applications (Java, Python, Node.js, Go...).

What APM shows:
  Services map:    visual graph of service-to-service call dependencies
                   latency and error rate on each connection
  Transactions:    list of all HTTP endpoints/Kafka consumers with:
                   avg/p95/p99 latency, error rate, throughput
  Traces:          individual request traces with flame graph
                   each span = one operation (DB query, HTTP call, cache read)
  Errors:          grouped exceptions with stack traces and occurrence count
  Metrics:         JVM heap, GC pauses, thread count (for JVM apps)

Trace example:
  POST /checkout (total: 450ms)
  ├── Auth middleware (12ms)
  ├── GET /inventory/check (45ms)  → inventory-service (35ms DB query)
  ├── POST /payment/charge (380ms) → payment-gateway (external, 370ms)
  └── Publish to Kafka (3ms)

  → Immediately see: payment-gateway is the bottleneck

Correlation — APM ↔ Logs:
  Click a slow trace → "View logs" → see exact log lines from that request
  Requires: trace.id and span.id in log fields (APM agent injects them)
```

### 6.8 Observability — Unified View

```
Kibana Observability consolidates:
  Logs:     log search across all indices (wraps Discover)
  Metrics:  infrastructure metrics (wraps Metrics app)
  APM:      application traces
  Synthetics: uptime checks (HTTP, TCP, Browser-based)
  Profiling:  continuous profiling (universal profiling in 8.x)

Unified Alerts:
  One alerting framework for all data types.
  Alert on: log query count, metric threshold, APM error rate, uptime failure.

Alert types available:
  Log threshold:         count of log events matching query > N in window
  Metric threshold:      metric value > threshold (CPU > 85% for 5 min)
  APM anomaly:           ML detects unusual transaction rate or latency
  APM error count:       exceptions > N in window
  Uptime monitor down:   HTTP check fails for N consecutive checks
  Inventory:             infrastructure resource (pod, container) in bad state
  ES query:              arbitrary Elasticsearch query result > threshold
```

### 6.9 Alerting — Rules and Connectors

```
Rules (what triggers the alert):
  Kibana Rules → Create rule

  Rule types:
    Elasticsearch query:   run a query, alert when hits > threshold
    Index threshold:       count/sum/avg/min/max of field > threshold
    Log threshold:         count log events matching filter
    APM transaction error: error rate > threshold for a service
    Metric anomaly:        ML detects anomaly in metric
    Uptime TLS:            certificate expiry warning

  Check interval:  how often the rule evaluates (1m, 5m, 1h)
  Look-back window: how far back each evaluation looks ("last 5 minutes")
  Threshold:        condition to trigger (e.g., count > 50)

Connectors (where to send alerts):
  Slack:         POST to webhook URL
  PagerDuty:     create incident (routing key)
  Jira:          create issue automatically
  Email:         SMTP
  Webhook:       generic HTTP POST (custom payloads)
  ServiceNow:    create ITSM ticket
  OpsGenie:      alert routing

Example rule — high error rate:
  Rule type: Elasticsearch query
  Index: logs-*
  Query: { "bool": { "filter": [
    {"term": {"level.keyword": "ERROR"}},
    {"term": {"service.keyword": "payment-api"}}
  ]}}
  Threshold: count > 50 in last 5 minutes
  Check every: 1 minute
  Actions (on alert):
    Slack → #platform-alerts: "⚠️ payment-api: {{context.value}} errors in 5 min"
    PagerDuty → P2 incident with runbook link
  Actions (on recovery):
    Slack → #platform-alerts: "✅ payment-api error rate recovered"
```

### 6.10 Machine Learning — Anomaly Detection

```
Kibana ML (requires Platinum/Enterprise licence or trial):

Single metric anomaly detection:
  Monitor one metric over time (e.g., request rate for payment-api)
  ML learns the baseline pattern (time-of-day, day-of-week seasonality)
  Automatically detects when value is unusually high or low

  "Every day at 2pm we get 10,000 req/min. Today at 2pm: 200 req/min"
  → ML flags as anomaly, even if threshold-based alerting wouldn't catch it

Multi-metric jobs:
  Monitor multiple metrics simultaneously
  Correlate anomalies across services
  "Response time spiked AND error rate increased AND request rate dropped"
  → More confident root-cause signal

Population analysis:
  Baseline each entity in a group and flag outliers
  "pod-abc123 has 10x more errors than the other payment-api pods"
  → Identifies a bad pod vs a service-wide issue

Anomaly score: 0-100
  0-25:   low (informational)
  25-50:  warning
  50-75:  major
  75-100: critical

Forecast:
  Project future values of a metric based on historical pattern
  "At current growth rate, disk will be full in 8 days"
```

### 6.11 Security / SIEM

```
Kibana Security app (requires Platinum or Elastic Security subscription):

Detection Rules:
  Pre-built rules: 600+ Elastic-maintained rules for common threats
  Examples:
    "Suspicious PowerShell execution"
    "Base64 encoded command in process args"
    "Brute force login attempts" (>50 failed logins in 5 min)
    "Privilege escalation via sudo"
    "Unusual process spawned by web server"
  Custom rules: write your own EQL queries

Timeline Investigation:
  Pin events from Discover to a Timeline
  Add related events (same host, same user, same IP)
  Build a visual attack narrative
  Save as evidence for incident report

Cases:
  Create a security case from an alert
  Attach signals, timeline, comments
  Assign to analyst, track status
  Export to PDF for compliance

Data sources (via Beats/Fleet):
  Auditbeat:    Linux auditd events, file integrity
  Winlogbeat:   Windows Event Logs (Security, PowerShell)
  Packetbeat:   Network flow data
  Filebeat:     Syslog, web server logs
```

### 6.12 Dev Tools — Console

```
Kibana Dev Tools → Console = send raw Elasticsearch API calls from browser.
Essential for: debugging, index management, performance tuning.

# Check cluster health
GET _cluster/health?pretty

# Create an index with explicit mapping
PUT logs-custom
{
  "mappings": {
    "properties": {
      "@timestamp":  {"type": "date"},
      "level":       {"type": "keyword"},
      "service":     {"type": "keyword"},
      "message":     {"type": "text"},
      "duration_ms": {"type": "integer"},
      "source.ip":   {"type": "ip"}
    }
  },
  "settings": {
    "number_of_shards":   3,
    "number_of_replicas": 1,
    "refresh_interval":   "30s"
  }
}

# Search with DSL
GET logs-*/_search
{
  "query": {"term": {"level.keyword": "ERROR"}},
  "size": 5,
  "sort": [{"@timestamp": "desc"}]
}

# Check index stats
GET logs-*/_stats/docs,store

# List all indices with size and doc count
GET _cat/indices?v&s=store.size:desc&h=index,docs.count,store.size,pri,rep

# Force index rollover
POST logs-current/_rollover
{"conditions": {"max_age": "7d", "max_size": "50gb"}}

# Reindex (copy from old to new index)
POST _reindex
{
  "source": {"index": "logs-old"},
  "dest":   {"index": "logs-new"}
}

# Profile a slow query (shows where time is spent)
GET logs-*/_search
{
  "profile": true,
  "query": {"match": {"message": "timeout"}}
}
```

### 6.13 Stack Management

```
Stack Management → the admin section of Kibana.

Index Management:
  View all indices: size, doc count, shard count, status (green/yellow/red)
  Delete old indices, force merge, close (reduces memory), open

Data Views:
  Create/edit index patterns for Discover and Lens

Index Lifecycle Management (ILM):
  Create/edit ILM policies
  Assign policies to indices

Snapshot and Restore:
  Configure S3/Azure Blob repository for ES snapshots
  Schedule automatic snapshots (hourly/daily)
  Restore specific indices from snapshot (point-in-time recovery)

Saved Objects:
  Export/Import dashboards, visualisations, saved searches
  Migrate between clusters (dev → prod)
  Export: Stack Mgmt → Saved Objects → select → Export
  Import: → Import → upload .ndjson file

  This is how you version-control your Kibana dashboards in Git.

Users and Roles (Security):
  Create roles with index-level permissions:
    Role "logs-reader": read access to logs-* indices
    Role "apm-writer":  write access to apm-* indices
  Assign roles to users or integrate with LDAP/SAML
  Field-level security: hide PII fields from certain roles
  Document-level security: only show logs for specific namespace
```

### 6.14 Kibana Spaces

```
Spaces = logical separation of dashboards, data views, and alerts per team.
Prevents one team's dashboards from cluttering another's.

Use cases:
  Platform team space:    infra dashboards, K8s metrics, node health
  App team space:         application logs, APM, error rates per service
  Security team space:    SIEM dashboards, threat detection alerts
  Business space:         user behaviour analytics, conversion metrics

Setup:
  Stack Mgmt → Spaces → Create space
  Name: "Platform Engineering"
  Avatar: wrench icon
  Features enabled: choose which Kibana apps this space can use

Access control:
  Users can be assigned access to specific spaces only
  "payment-team" users only see the "Payments" space
  "platform-team" users see all spaces

Saved objects are space-specific:
  Dashboard in "Platform" space not visible in "Payments" space
  Can copy objects between spaces if needed
```

### 6.15 Fleet and Elastic Agent

```
Fleet = centralised management of Elastic Agents.
Elastic Agent = single agent that replaces Filebeat + Metricbeat + Auditbeat.

Traditional (multiple agents per host):
  Node 1: Filebeat + Metricbeat + Auditbeat + Packetbeat = 4 agents to manage

With Elastic Agent:
  Node 1: one Elastic Agent, configured via Fleet (policies in Kibana)

Fleet workflow:
  1. In Kibana → Fleet → Create Agent Policy
  2. Add integrations to the policy:
     - Kubernetes integration (pod logs + metrics)
     - System integration (CPU/memory/disk)
     - Docker integration
     - Nginx integration (access + error logs)
  3. Install Elastic Agent on hosts (or deploy as DaemonSet on K8s)
  4. Agent checks into Fleet → receives policy → starts collecting

Benefits:
  Centralized config: change log collection config in Fleet UI, pushed to all agents
  No SSH to each server: config changes applied without touching individual hosts
  Automatic data routing: logs go to correct ES index, metrics to metrics index
  Version management: upgrade all agents from Fleet UI

On Kubernetes (DaemonSet):
  helm install elastic-agent elastic/elastic-agent \
    --set fleet.enabled=true \
    --set fleet.url=https://kibana:5601 \
    --set fleet.token=<enrollment-token>
```

---

## 7. Elasticsearch Queries

### Query DSL

```json
// Find ERROR logs from payment service in last hour
GET logs-*/_search
{
  "query": {
    "bool": {
      "must": [
        { "term": { "level.keyword": "ERROR" } },
        { "term": { "service.keyword": "payment-api" } }
      ],
      "filter": [
        { "range": { "@timestamp": { "gte": "now-1h", "lte": "now" } } }
      ],
      "must_not": [
        { "term": { "message.keyword": "health check" } }
      ]
    }
  },
  "sort": [{ "@timestamp": "desc" }],
  "size": 100
}

// Aggregation — error count per service per hour
GET logs-*/_search
{
  "size": 0,
  "query": { "term": { "level.keyword": "ERROR" } },
  "aggs": {
    "errors_over_time": {
      "date_histogram": {
        "field": "@timestamp",
        "calendar_interval": "1h"
      },
      "aggs": {
        "by_service": {
          "terms": { "field": "service.keyword", "size": 10 }
        }
      }
    }
  }
}

// Full-text search with highlighting
GET logs-*/_search
{
  "query": {
    "match": { "message": "connection timeout" }
  },
  "highlight": {
    "fields": { "message": {} }
  }
}
```

---

## 8. ELK vs Other Log Stacks

| Feature | ELK Stack | Loki + Grafana | Datadog | Splunk |
|---|---|---|---|---|
| **Index approach** | Full-text index (every field) | Labels only (no full-text index) | Proprietary | Proprietary |
| **Search power** | Excellent — any field, full text | Basic — label filter + grep | Excellent | Excellent |
| **Storage cost** | High (indexing overhead) | Low (compressed chunks, minimal index) | Very high (per GB ingested) | Very high (per GB) |
| **Setup complexity** | High (manage cluster) | Low (just Loki + Grafana) | Zero (SaaS) | Medium |
| **Operational overhead** | High (shards, replicas, ILM) | Low | None | Low-medium |
| **Scalability** | Excellent (horizontal) | Excellent | Unlimited (SaaS) | Good |
| **Alerting** | Kibana Alerts / Watcher | Grafana Alerts | Built-in | Built-in |
| **APM tracing** | Elastic APM (add-on) | Tempo (separate) | Built-in | Built-in |
| **Cost model** | Infrastructure cost | Infrastructure cost | Per GB/host | Per GB |
| **Best for** | Full-text log search at scale | K8s logs with label filtering | Managed, all-in-one | Enterprise compliance |

**Key insight for interviews:**
- Loki is cheap because it doesn't index content — only labels. Queries grep through compressed chunks.
- ELK indexes every field → much faster queries but much higher storage cost.
- Use ELK when: complex queries, ad-hoc search, unknown query patterns.
- Use Loki when: K8s logs with known label filters, cost-sensitive.

---

## 9. OpenSearch (AWS Fork)

```
In 2021: Elastic changed Elasticsearch and Kibana from Apache 2.0 to SSPL licence.
AWS forked Elasticsearch 7.10.2 → OpenSearch (kept Apache 2.0).

OpenSearch = Elasticsearch 7.10 with AWS additions:
  Security plugin:     TLS, authentication, RBAC built-in (not in ES basic)
  Anomaly detection:   ML-based anomaly detection on time-series
  Alerting:            Built into OpenSearch (not separate Watcher)
  SQL support:         Query with SQL instead of Query DSL
  Trace analytics:     APM-like trace correlation

AWS OpenSearch Service = managed OpenSearch on AWS
  Replaces AWS Elasticsearch Service
  Integrates with: Kinesis Data Firehose, CloudWatch Logs, S3

API compatibility:
  OpenSearch is wire-compatible with Elasticsearch 7.x clients
  Most Elasticsearch 7.x code works on OpenSearch without change
  For ES 8.x features: not in OpenSearch (diverged)
```

---

## 10. Production Best Practices

```
Cluster sizing:
  Minimum 3 nodes for HA (quorum for master election)
  Dedicated master nodes (3) for large clusters (20+ nodes)
  Data nodes: 10-50GB per shard recommended
  Memory: 50% of JVM heap to OS page cache (set -Xms -Xmx to half RAM)

Index strategy:
  Daily indices: logs-2024.01.15 (easy time-based ILM)
  Index templates: define mappings before data arrives
  ILM policy: automate hot → warm → delete

Mapping best practices:
  Explicit mapping > dynamic mapping (avoid type conflicts)
  keyword for: status codes, service names, IDs (for aggregations)
  text for: message fields (for full-text search)
  Enable dynamic: false for unknown fields (avoid mapping explosion)

Security:
  TLS between all nodes and clients (not optional in production)
  Role-based access: separate roles for read, write, admin
  Audit logging: who searched for what, when

Performance:
  Bulk API: write 1000 documents per request, not 1 by 1
  Refresh interval: default 1s (set to 30s for write-heavy workloads)
  Replicas: set to 0 during initial bulk load, then restore
```

---

## 11. Interview Questions

### Q: Explain Elasticsearch shards and why they matter for performance.

An Elasticsearch index is split into shards — independent units of storage and search.
Primary shards handle writes; replicas provide read scalability and fault tolerance.

**For performance:** Queries are executed in parallel across all shards.
A query on an index with 5 shards uses 5 threads simultaneously → 5x potential speedup.
`shard_count × docs_per_shard = total_docs`, but queries run in parallel.

**Sizing rules:** 10-50GB per shard is recommended. Too large = slow; too many = overhead.
Primary shard count is fixed at index creation. Plan capacity upfront or use ILM rollover.

**Replica performance:** Reads are load-balanced across primary and replicas.
2 replicas on 3 nodes = 3 copies total → 3x read throughput.

---

### Q: What is an inverted index and why is Elasticsearch fast at full-text search?

Traditional SQL `LIKE '%error%'` scans every row — O(n) operation.

Elasticsearch builds an inverted index during document ingestion:
Text is tokenised (split into words), lowercased, stop words removed.
The inverted index maps each unique token → list of document IDs containing it.

When you search "timeout error":
1. Look up "timeout" in inverted index → [doc3, doc7, doc9, doc45]
2. Look up "error" → [doc3, doc9, doc12]
3. Intersection (AND) or union (OR)
4. Return matching documents

This lookup is O(1) regardless of dataset size. That's why ES searches billions of logs in milliseconds.

---

### Q: Logstash vs Beats — when to use each?

**Beats:** Lightweight Go agents (< 50MB RAM). Purpose-built for one data type.
No complex transformation. Ship data fast with minimal resource overhead.
Use when: just need to collect and forward data, run on every host.

**Logstash:** JVM-based (500MB+). Full data processing pipeline.
Complex parsing (grok), enrichment (geoip, dns), transformation (mutate, convert).
Use when: data needs heavy processing before indexing.

**Common pattern:** Filebeat ships raw logs → Logstash parses/enriches → Elasticsearch indexes.
This keeps resource footprint on hosts minimal while doing complex processing centrally.

**Modern alternative:** Elasticsearch Ingest Pipelines — process data in Elasticsearch itself.
Offloads from Logstash. Beats ship directly to ES with an ingest pipeline specified.

---

### Q: Your ELK cluster is showing RED status. How do you investigate and fix it?

```
Cluster health RED = at least one primary shard is unassigned (data unavailable)

Step 1: Check health
GET _cluster/health?pretty
  → status: red, unassigned_shards: 3, active_shards: 97

Step 2: Find unassigned shards
GET _cat/shards?v&h=index,shard,prirep,state,unassigned.reason
  → shows UNASSIGNED rows with reason: NODE_LEFT, ALLOCATION_FAILED, etc.

Step 3: Explain why shard is unassigned
GET _cluster/allocation/explain
  → "no nodes with enough disk space" or "node not found" etc.

Common causes and fixes:
  Node crashed:     Wait for node to rejoin, or add a new node
  Disk full:        Delete old indices, add disk, or increase watermark threshold
    PUT _cluster/settings
    {"transient":{"cluster.routing.allocation.disk.threshold_enabled":false}}
  Corrupted shard:  Restore from snapshot, or force-allocate losing data
    POST _cluster/reroute
    {"commands":[{"allocate_stale_primary":{"index":"my-index","shard":0,"node":"node-1","accept_data_loss":true}}]}

Step 4: Monitor recovery
GET _cat/recovery?v&active_only=true
```

---

### Q: How do you handle log volume spikes without losing data?

**Filebeat side:** Filebeat has an internal registry tracking file offset.
If Logstash is slow, Filebeat queues events in memory (configurable size).
If memory queue fills: Filebeat stops reading new logs (backpressure) — no loss.

**Logstash side:** Enable persistent queue (not in-memory).
`queue.type: persisted` → events stored on disk between input and filter.
Survives Logstash crash and restart.
Size: `queue.max_bytes: 10gb`

**Kafka buffer pattern (most robust):**
Filebeat → Kafka (topic: raw-logs) → Logstash → Elasticsearch
Kafka retains messages for days. Logstash processes at its own speed.
If Logstash is down: messages wait in Kafka (zero loss).
If spike occurs: Kafka buffers, Logstash catches up.

---

### Q: ELK vs Loki — which do you choose and why?

**ELK strength:** Full-text search across any field in any log.
Ad-hoc queries on unknown fields without pre-defining labels.
"Find all logs containing this exception across all services" — ELK excels.
Richer analytics: aggregations, cardinality, percentiles, histograms.

**Loki strength:** Minimal storage cost (no full-text index, only labels).
Purpose-built for Kubernetes (labels = namespace, pod, container).
Familiar PromQL-style query language (teams using Prometheus like it).
Tight Grafana integration (one pane for metrics + logs).

**Decision:**
ELK: when you have unknown query patterns, need full-text search, complex analytics.
Loki: when you have well-defined label-based queries, cost-sensitive, K8s-native.
Both: some organisations run Loki for recent K8s logs (cheap, fast) + ELK for compliance/security archive.

At Voya: Dynatrace for full observability (metrics + logs + traces). Familiar with ELK from previous roles.

---

## Quick Reference

```
ES concepts:
  Document   → JSON object (one log line)
  Index      → collection of documents (logs-2024.01.15)
  Shard      → subset of index (parallel search unit)
  Replica    → copy of shard (HA + read scale)
  Mapping    → field type definitions
  Inverted index → word → documents (fast full-text)

Cluster node roles:
  Master     → cluster state management
  Data       → stores and queries shards
  Ingest     → pre-processing pipeline
  Coordinating → route + merge queries

ILM phases: Hot → Warm → Cold → Frozen → Delete

Logstash: Input → Filter (grok/date/mutate/geoip) → Output

KQL quick:
  field: "value"          exact match
  field > 500             range
  field: *                field exists
  NOT field: "val"        negation
  a AND b                 both conditions
  field: ("a" OR "b")     multiple values
```
