# AWS System Design Interview Guide

**Target Role:** Principal Platform Engineer / Solutions Architect / SRE Lead
**Focus:** Burst traffic, zero-downtime deployments, cross-cluster data sync, HA, DR

---

## How to Answer a System Design Question

**RADIO Framework** — use this every time:
1. **R**equirements — functional + non-functional (scale, latency, availability)
2. **A**PI / Interface — what does the system expose?
3. **D**ata model — what data, what storage pattern
4. **I**nfrastructure — which services, why
5. **O**ptimisations — scaling, caching, failure modes

Always ask before drawing:
- Expected traffic (RPS, DAU)?
- Availability requirement (99.9%, 99.99%)?
- Data consistency requirement (strong, eventual)?
- Read-heavy or write-heavy?
- Multi-region or single region?

---

## Design 1: Handle Burst Traffic (High Traffic / Auto-Scaling)

### Scenario
"Design a system that handles normal traffic of 1,000 RPS but bursts to 50,000 RPS during flash sales. Response time must stay under 200ms p99."

### Architecture

```
                          ┌──────────────┐
Users ─── HTTPS ──────▶  │  CloudFront  │  CDN — static assets, edge caching
                          └──────┬───────┘
                                 │ Cache miss
                          ┌──────▼───────┐
                          │  Route 53    │  DNS — health-check based routing
                          └──────┬───────┘
                                 │
                          ┌──────▼───────┐
                          │  WAF + Shield│  DDoS protection, rate limiting
                          └──────┬───────┘
                                 │
                    ┌────────────▼────────────┐
                    │  Application Load       │  ALB — path-based routing
                    │  Balancer (ALB)         │  Sticky sessions, HTTP/2, WebSocket
                    └────┬──────────────┬─────┘
                         │              │
              ┌──────────▼──┐    ┌──────▼──────────┐
              │  ECS Fargate│    │  ECS Fargate     │  Serverless containers
              │  (API tier) │    │  (API tier)      │  No EC2 management
              └──────┬──────┘    └──────┬───────────┘
                     │                  │
              ┌──────▼──────────────────▼──┐
              │     ElastiCache (Redis)     │  Session store, hot data cache
              └──────────────┬─────────────┘
                             │ Cache miss
                    ┌────────▼────────┐
                    │  Aurora MySQL   │  Multi-AZ, read replicas
                    │  (Writer)       │  Up to 15 read replicas
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  Aurora Read    │  Read replicas for scale-out
                    │  Replicas (×3)  │
                    └─────────────────┘

Async / burst buffer:
API ──▶ SQS Queue ──▶ Lambda (auto-scales to concurrency limit) ──▶ DynamoDB
```

### Key Design Decisions

**CloudFront (CDN):**
- Cache static assets (JS, CSS, images) at 400+ edge locations
- Cache API responses where data is not user-specific (product listings, prices)
- Dramatically reduces origin load — burst absorbed at edge
- TTL strategy: product data = 60s, user cart = 0 (bypass cache)

**ALB + ECS Fargate:**
- ALB distributes across multiple Fargate tasks
- Fargate auto-scales: `target tracking scaling` on ALB `RequestCountPerTarget`
- No server management — AWS manages underlying EC2 fleet
- Scale from 2 tasks to 200 tasks in ~2-3 minutes

```json
// ECS Service Auto Scaling — scale when >1000 requests per target per minute
{
  "TargetValue": 1000,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ALBRequestCountPerTarget",
    "ResourceLabel": "app/my-alb/123/targetgroup/my-tg/456"
  },
  "ScaleInCooldown": 300,
  "ScaleOutCooldown": 60     // scale out fast, scale in slow
}
```

**ElastiCache Redis:**
- L1 cache: ~0.5ms vs Aurora ~3ms for cached reads
- Cache: session tokens (TTL 30m), product catalog (TTL 60s), user profiles (TTL 5m)
- Write-through pattern: update DB and cache atomically
- Redis Cluster mode: shard data across multiple nodes for horizontal scale

**SQS for burst buffer:**
- Flash sale order placement → write to SQS, return 202 Accepted immediately
- Lambda consumes queue at controlled rate, writes to Aurora
- Decouples burst ingestion from DB write throughput
- SQS handles millions of messages automatically, no provisioning

**Aurora vs RDS:**
- Aurora: 5x MySQL performance, 3 copies of data across 3 AZs automatically
- Read replicas lag: <100ms (synchronous replication for writes, async for reads)
- Aurora Serverless v2: scales compute automatically (0.5-128 ACUs) — good for unpredictable load

### Numbers to Remember
- ALB: 1M RPS throughput, scales automatically
- ECS Fargate: scale-out in 60-90 seconds
- ElastiCache: <0.5ms read latency at any scale
- SQS: virtually unlimited throughput (Standard queue)
- Aurora: up to 128TB storage, 15 read replicas

---

## Design 2: Zero-Downtime Deployment

### Scenario
"Design a deployment pipeline that achieves zero-downtime releases with automatic rollback for a high-traffic e-commerce API running on AWS."

### Three Strategies

#### Strategy A: Blue/Green Deployment (Best for stateful apps)

```
Route 53 / ALB (weighted routing)
        │
   ┌────┴────┐
   │         │
Blue (v1)  Green (v2)   ← deploy here, run smoke tests
100%        0%
                         Step 1: deploy v2 to Green, smoke test
                         Step 2: shift 10% traffic to Green
                         Step 3: watch metrics for 10 min
                         Step 4: shift to 100% Green
                         Step 5: keep Blue for 1 hour (instant rollback)
                         Step 6: decommission Blue
```

```yaml
# ALB Listener Rule — weighted target groups
aws elbv2 modify-rule --rule-arn <rule-arn> \
  --actions Type=forward,ForwardConfig='{
    "TargetGroups": [
      {"TargetGroupArn": "blue-arn", "Weight": 90},
      {"TargetGroupArn": "green-arn", "Weight": 10}
    ]
  }'
```

**When to use:** Stateful applications, databases with schema changes, when you need instant rollback.

**Trade-offs:**
- Requires 2x infrastructure cost during transition (~15-30 min window)
- Session affinity issue — users on Blue mid-session get shifted to Green (use shared session store like ElastiCache)

#### Strategy B: Canary Deployment (Best for risky changes)

```
ALB ──────▶ Target Group A (v1) — 95% traffic — 40 instances
      │
      └────▶ Target Group B (v2) — 5% traffic — 2 instances

Canary metrics watched for 30 min:
  - Error rate < 0.1%
  - p99 latency < 200ms
  - No anomalies in CloudWatch

If healthy → gradually shift: 5% → 20% → 50% → 100%
If unhealthy → remove canary target group instantly
```

**CodeDeploy for ECS Canary:**
```yaml
# appspec.yml for ECS blue/green with CodeDeploy
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: "arn:aws:ecs:..."
        LoadBalancerInfo:
          ContainerName: "api"
          ContainerPort: 8080
Hooks:
  - BeforeAllowTraffic: "LambdaFunctionToRunSmokeTests"
  - AfterAllowTraffic: "LambdaFunctionToRunIntegrationTests"
```

#### Strategy C: Rolling Update with EKS (Best for Kubernetes workloads)

```yaml
# EKS Deployment — rolling update
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: 10
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 2          # max extra pods during update (2 extra = 12 total)
      maxUnavailable: 0    # never take down a pod before new one is ready
  template:
    spec:
      containers:
      - name: api
        image: my-api:v2
        readinessProbe:           # CRITICAL — pod only gets traffic when healthy
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
          failureThreshold: 3
        lifecycle:
          preStop:
            exec:
              command: ["sleep", "15"]   # drain in-flight requests before SIGTERM
```

**PodDisruptionBudget — prevent all pods being down simultaneously:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  minAvailable: "80%"     # at least 80% of pods must be running during disruption
  selector:
    matchLabels:
      app: api
```

### Zero-Downtime Checklist

```
Before deployment:
  □ Readiness probes configured (gates traffic)
  □ Liveness probes configured (restarts unhealthy pods)
  □ PodDisruptionBudget set (min 70-80% available)
  □ HPA configured (won't scale to 0 during update)
  □ preStop hook with sleep (drains in-flight connections)
  □ terminationGracePeriodSeconds > request timeout

During deployment:
  □ Monitor error rate (CloudWatch, Datadog)
  □ Monitor p99 latency
  □ Watch pod events: kubectl get events --sort-by=.lastTimestamp

Rollback trigger:
  □ Error rate > 1% for 5 minutes
  □ p99 latency > threshold
  □ Readiness probe failures
```

### Database Migrations with Zero Downtime

This is the hard part. Schema changes must be backward-compatible:

```
Phase 1: Add column (nullable, no default)    ← deploy, old + new code both work
Phase 2: Deploy new code that writes to column
Phase 3: Backfill existing rows
Phase 4: Add NOT NULL constraint
Phase 5: Remove old code reading old column

NEVER: add NOT NULL column without default in one migration → table lock → downtime
```

---

## Design 3: Data Sync Across Clusters / Regions

### Scenario
"Design a multi-region active-active system where users in US-East and EU-West both write data, and data must be consistent with < 5 seconds lag."

### Architecture

```
US-East-1                                EU-West-1
─────────────────────────────────────────────────────────
Route 53 Latency Routing
    │                                        │
    ▼                                        ▼
ALB (us-east-1)                        ALB (eu-west-1)
    │                                        │
ECS/EKS (API)                          ECS/EKS (API)
    │                                        │
    ▼                                        ▼
Aurora Global DB ◄═══════════════════► Aurora Global DB
(Primary - Writer)   < 1 sec RPO       (Secondary - Reader)
                     async replication
                     (promotes in < 1 min)
    │                                        │
DynamoDB Global      ◄══════════════► DynamoDB Global
Tables (US)          async ~1 sec     Tables (EU)
    │                                        │
ElastiCache                           ElastiCache
(US local)                            (EU local)
    │                                        │
S3 (us-east-1) ══════════════════════► S3 (eu-west-1)
               Cross-Region Replication
               (async, ~15-60 sec)

Conflict resolution layer:
SQS FIFO (per user) → Lambda → merge conflicts → write canonical record
```

### Service-by-Service Sync Strategy

#### Aurora Global Database

Best for: relational data requiring strong consistency on reads.

```
Write path: User A (EU) → API (EU) → Aurora Primary (US-East) → replicated to EU Secondary
Latency: EU write = ~80ms additional (transatlantic)
RPO: < 1 second (replication lag)
RTO: < 1 minute (promote EU secondary to primary)
```

Failover:
```bash
# Promote EU secondary to primary during US outage
aws rds failover-global-cluster \
  --global-cluster-identifier my-global-cluster \
  --target-db-cluster-identifier arn:aws:rds:eu-west-1:...:my-cluster
```

**Limitation:** Aurora Global DB is active-passive for writes. Only one writer region. For true active-active writes → use DynamoDB.

#### DynamoDB Global Tables

Best for: session data, user preferences, shopping carts — eventual consistency acceptable.

```
Write anywhere: User writes to DynamoDB EU → auto-replicated to DynamoDB US
Replication lag: typically < 1 second
Conflict resolution: last-writer-wins (based on timestamp)
```

```python
# Write to local region — DynamoDB handles replication
dynamodb = boto3.resource('dynamodb', region_name='eu-west-1')
table = dynamodb.Table('UserSessions')
table.put_item(Item={
    'userId': 'user123',
    'sessionData': {...},
    'updatedAt': int(time.time() * 1000)   # timestamp for last-writer-wins
})
```

**Custom conflict resolution:** Use Lambda triggers on DynamoDB Streams to detect and resolve conflicts (e.g., merge shopping carts instead of overwrite).

#### S3 Cross-Region Replication

```
S3 (us-east-1) ──replication rule──▶ S3 (eu-west-1)
Latency: 15 seconds - 3 minutes (eventually consistent)
Use for: model artefacts, static assets, backups, large objects
```

```json
{
  "Rules": [{
    "Status": "Enabled",
    "Destination": {
      "Bucket": "arn:aws:s3:::eu-bucket",
      "ReplicationTime": {"Status": "Enabled", "Time": {"Minutes": 15}},
      "Metrics": {"Status": "Enabled"}
    }
  }]
}
```

#### ElastiCache (No Cross-Region Sync)

ElastiCache has NO built-in cross-region replication. Cache is always local to region.

Strategy: treat cache as regional L1. On cache miss, read from DynamoDB (which IS synced). This is correct behaviour — don't try to sync caches.

### Conflict Resolution Patterns

```
Pattern 1: Last-Writer-Wins (LWW)
  - Simplest. Whichever write has the later timestamp wins.
  - Problem: clock skew. Use logical clocks or vector clocks.
  - DynamoDB Global Tables uses LWW.

Pattern 2: Operational Transformation (OT)
  - Track all operations, merge intelligently.
  - Complex to implement. Used by Google Docs, collaborative editors.

Pattern 3: CRDTs (Conflict-free Replicated Data Types)
  - Data structure designed to merge without conflicts.
  - Counters, sets, maps have CRDT variants.
  - Redis has CRDT support in Redis Enterprise.

Pattern 4: Route writes to one region
  - All writes go to US-East. EU API proxies writes to US.
  - Simpler consistency model. Higher write latency for EU users.
  - Aurora Global DB fits this pattern.
```

---

## Design 4: Event-Driven Architecture for Scale

### Scenario
"Design an order processing system that handles 100,000 orders/minute with guaranteed processing and no message loss."

### Architecture

```
Client ──▶ API Gateway ──▶ Lambda (validate + enqueue)
                                  │
                           ┌──────▼──────┐
                           │  SQS FIFO   │  Ordered per order-ID
                           │  (Orders)   │  DLQ for failed messages
                           └──────┬──────┘
                                  │
                    ┌─────────────▼─────────────┐
                    │  Lambda (Order Processor)  │
                    │  - Check inventory         │
                    │  - Charge payment          │
                    │  - Send confirmation       │
                    └─────────────┬─────────────┘
                                  │
               ┌──────────────────┼──────────────────┐
               │                  │                   │
        ┌──────▼──────┐   ┌───────▼──────┐   ┌───────▼──────┐
        │  EventBridge│   │    DynamoDB  │   │  SNS → SES   │
        │  (audit log)│   │  (order DB)  │   │  (email)     │
        └─────────────┘   └─────────────┘   └──────────────┘

Dead Letter Queue:
SQS DLQ ──▶ Lambda (DLQ processor) ──▶ alert + manual review queue
```

### SQS Key Concepts for Interviews

| Feature | Standard Queue | FIFO Queue |
|---|---|---|
| Throughput | Unlimited | 3,000 msg/sec (with batching) |
| Ordering | Best-effort | Strict per MessageGroupId |
| Delivery | At-least-once | Exactly-once |
| Use case | High throughput, order not critical | Financial transactions, order processing |

```python
# Send to FIFO SQS
sqs.send_message(
    QueueUrl='https://sqs.us-east-1.amazonaws.com/123/orders.fifo',
    MessageBody=json.dumps(order),
    MessageGroupId=order['userId'],       # ordering per user
    MessageDeduplicationId=order['id']   # idempotency - deduplicate within 5 min
)
```

### EventBridge vs SNS vs SQS — When to Use Each

| Service | Pattern | Use case |
|---|---|---|
| **SQS** | Queue (pull) | One consumer, buffer, retry, DLQ |
| **SNS** | Pub/Sub (push) | Fan-out to multiple subscribers, notifications |
| **EventBridge** | Event bus | Event routing by content/source, SaaS integrations, scheduled events |
| **Kinesis** | Stream | Real-time data streaming, ordered, replay, analytics |

**Common pattern:** SNS → SQS (fan-out with buffering)
```
Order placed
    │
    SNS (order-events)
    ├──▶ SQS (inventory-service)
    ├──▶ SQS (billing-service)
    └──▶ SQS (notification-service)
```
Each service has its own queue → independent scaling, independent failure handling.

---

## Design 5: Disaster Recovery (DR) Patterns

### Four DR Tiers

| Strategy | RTO | RPO | Cost | Description |
|---|---|---|---|---|
| **Backup & Restore** | Hours | Hours | $ | S3 backups, restore on DR event |
| **Pilot Light** | 10-30 min | Minutes | $$ | Core infrastructure always on, scale up on DR |
| **Warm Standby** | Minutes | Seconds | $$$ | Scaled-down copy always running |
| **Multi-Site Active-Active** | Near-zero | Near-zero | $$$$ | Full traffic in both regions always |

### Pilot Light Architecture

```
Primary Region (us-east-1) — full traffic
  RDS Primary ──── continuous replication ────▶ RDS Standby (eu-west-1)
  EC2 (running)                                  EC2 (stopped, AMI ready)
  ALB (active)                                   ALB (configured, no targets)

DR Event:
  1. Promote RDS Standby to primary     (~3-5 min)
  2. Start EC2 instances from AMI       (~5-8 min)
  3. Register instances with EU ALB     (~2 min)
  4. Update Route 53 to point to EU     (~1 min TTL)
Total RTO: ~15-20 minutes
```

### Route 53 Failover Routing

```
Route 53 ──▶ Health Check on primary endpoint
           ├── Healthy: route to us-east-1 (Primary)
           └── Unhealthy: route to eu-west-1 (Secondary)

Health check:
  - Check every 10 seconds
  - Fail after 3 consecutive failures (30 seconds)
  - String match in response body
```

---

## Common Interview Questions

### Q: How do you handle a sudden 10x traffic spike that exceeds your ASG's ability to scale in time?

Pre-warming strategies:
1. **Scheduled scaling** — if spike is predictable (flash sale, Super Bowl), scale out 30 min before
2. **CloudFront caching** — absorb read traffic at edge before it hits origin
3. **SQS buffering** — accept requests immediately, process asynchronously
4. **API Gateway throttling** — rate limit per API key to protect backend

If spike hits unexpectedly:
1. CloudFront absorbs static + cacheable traffic
2. ALB returns 503 for capacity exceeded
3. Use SQS to queue requests that can be processed later (orders, emails)
4. Emergency: pre-warm ALB by contacting AWS support (for very large events)

### Q: How do you achieve zero-downtime for database schema changes?

The expand-contract (parallel change) pattern:
```
Step 1 EXPAND:   Add new column (nullable). Deploy code that reads both old+new.
Step 2 MIGRATE:  Backfill data. Deploy code that writes to both columns.
Step 3 CONTRACT: Deploy code that only uses new column. Drop old column.
```

Never: ALTER TABLE ADD COLUMN NOT NULL without DEFAULT on large tables. It locks the table.
Use: `pt-online-schema-change` (Percona) or `gh-ost` (GitHub) for live migrations.

### Q: DynamoDB vs Aurora — how do you choose?

| Use Aurora | Use DynamoDB |
|---|---|
| Complex queries (JOINs, aggregates) | Simple key-value or document access |
| Existing relational data model | Need to scale to millions of writes/sec |
| Transactions across many tables | Single-table design, known access patterns |
| Need SQL | Multi-region active-active writes |
| < 64TB data | Virtually unlimited scale |

### Q: How do you handle distributed transactions?

Avoid distributed transactions where possible — they are slow and complex.

If required, use **Saga pattern**:
1. Break transaction into local steps
2. Each step publishes an event on success
3. Each step has a compensating transaction on failure

```
Order placed → Reserve inventory → Charge payment → Send email
           ←                    ←                  (if email fails, charge still happened — acceptable)
           ←  If payment fails → Release inventory → Cancel order
```

Use AWS Step Functions for orchestrating saga steps with built-in retry and compensation.

---

## Quick Reference — AWS Services at a Glance

| Problem | AWS Service |
|---|---|
| Layer 7 load balancing | ALB |
| Layer 4 / UDP load balancing | NLB |
| Global load balancing + CDN | CloudFront + Route 53 |
| Container orchestration (serverless) | ECS Fargate |
| Container orchestration (Kubernetes) | EKS |
| Serverless functions | Lambda |
| Message queue (decouple, buffer) | SQS |
| Pub/Sub notifications | SNS |
| Event routing | EventBridge |
| Real-time streaming | Kinesis Data Streams |
| Relational DB (MySQL/Postgres) | Aurora |
| Key-value / document DB | DynamoDB |
| In-memory cache | ElastiCache (Redis / Memcached) |
| Object storage | S3 |
| Block storage | EBS |
| File storage (shared NFS) | EFS |
| CI/CD | CodePipeline + CodeBuild + CodeDeploy |
| Secret management | Secrets Manager |
| Config management | Systems Manager Parameter Store |
| Monitoring + alerting | CloudWatch |
| Distributed tracing | X-Ray |
| WAF + DDoS protection | WAF + Shield |
