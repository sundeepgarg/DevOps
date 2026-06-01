# Message Queues — Complete Interview Guide

**Covers:** Kafka, RabbitMQ, AWS SQS, AWS SNS, Azure Service Bus, Azure Event Hubs,
patterns, comparison, and interview Q&A.

---

## 1. Why Message Queues Exist

### The Problem They Solve

```
Without queues — direct coupling:
  Payment API → synchronously calls → Inventory Service
                                   → Notification Service
                                   → Analytics Service

Problems:
  If Inventory is slow: Payment API request takes 3 seconds (user waits)
  If Notification crashes: entire payment fails
  If Analytics is overloaded: Payment API is throttled
  If all three are down: Payment API returns 500

With message queue:
  Payment API → publishes "OrderPlaced" event → Queue → return 202 Accepted
  Consumers process asynchronously at their own pace:
    Inventory consumer  → reserves stock
    Notification consumer → sends email
    Analytics consumer  → updates dashboard

Benefits:
  Decoupling:       Payment API doesn't know or care about consumers
  Resilience:       If Notification crashes, message waits in queue (no loss)
  Load levelling:   Queue absorbs burst → consumer processes at steady rate
  Scalability:      Add more consumer instances independently
  Backpressure:     If consumer is slow, queue grows → alert → scale consumer
```

### Core Concepts

```
Producer:   Application that sends/publishes messages
Consumer:   Application that receives/processes messages
Queue:      Buffer that holds messages between producer and consumer
Message:    The data unit (JSON body + headers/metadata)
Broker:     The server managing queues (Kafka cluster, RabbitMQ server)

Delivery semantics:
  At-most-once:    Message delivered 0 or 1 times — fast, may lose messages
  At-least-once:   Message delivered 1 or more times — may process duplicates
  Exactly-once:    Delivered exactly once — hardest, most expensive

Acknowledgement (ACK):
  Consumer reads message → processes → sends ACK → broker removes from queue
  If no ACK after timeout → broker re-delivers to another consumer
  This is how "at-least-once" is achieved
```

---

## 2. Apache Kafka — Deep Dive

### What Kafka Is

```
Kafka is a distributed event streaming platform.
Not just a queue — it's a persistent, ordered log of events.

Key difference from traditional queues:
  Traditional queue: message consumed → deleted
  Kafka:            message consumed → STILL THERE (retained for configurable time)
                    multiple consumer groups can read the same messages independently
                    can replay messages from any point in time
```

### Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         Kafka Cluster                                     │
│                                                                           │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │                    Topic: order-events                             │  │
│  │                                                                    │  │
│  │  Partition 0 (Broker 1):                                          │  │
│  │  [offset:0] [offset:1] [offset:2] [offset:3] ... [offset:N]      │  │
│  │                                                                    │  │
│  │  Partition 1 (Broker 2):                                          │  │
│  │  [offset:0] [offset:1] [offset:2] ... [offset:M]                 │  │
│  │                                                                    │  │
│  │  Partition 2 (Broker 3):                                          │  │
│  │  [offset:0] [offset:1] ... [offset:K]                            │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  ZooKeeper/KRaft:  Metadata, leader election, consumer group offsets     │
└──────────────────────────────────────────────────────────────────────────┘

Broker:     Kafka server. Stores partitions. Multiple brokers = cluster.
Topic:      Named category of messages. "order-events", "user-signups".
Partition:  Ordered, immutable sequence of records within a topic.
            Key to Kafka's scalability — topic split across multiple brokers.
Offset:     Sequential ID of each message within a partition. 0, 1, 2, 3...
            Consumers track their position by committing offsets.
Replication factor: number of copies of each partition across brokers.
```

### Partitions — Key to Scalability

```
Partitioning strategy:
  Producers choose which partition to write to:
  - Round-robin (default, no key): distributes load evenly
  - Key-based (with key): same key always → same partition
    "orderid-123" → hash(orderid-123) % 3 = partition 1 (always)

Why key-based partitioning matters:
  All events for the same order go to the same partition
  Single partition is ORDERED → events processed in sequence per order
  Different orders go to different partitions → processed in parallel

  Without key: order events could go to any partition → out of order
  With key:    all events for order-123 are in order (within partition)

  Example:
    Partition 0: order-123 events (in order: placed, paid, shipped)
    Partition 1: order-456 events (in order: placed, paid, cancelled)
    Partition 2: order-789 events (in order: placed, reserved, shipped)

Parallelism:
  3 partitions → maximum 3 consumers in a group processing in parallel
  6 partitions → 6 consumers processing in parallel
  More partitions = more parallelism (but more overhead)
```

### Consumer Groups

```
Consumer Group: group of consumers that share the work of consuming a topic.
Each partition is assigned to EXACTLY ONE consumer in the group.
If more consumers than partitions → extra consumers are idle.

Topic: order-events (3 partitions)

Consumer Group "inventory-service" (2 consumers):
  Consumer A → Partition 0 + Partition 1
  Consumer B → Partition 2

Consumer Group "notification-service" (3 consumers):
  Consumer C → Partition 0
  Consumer D → Partition 1
  Consumer E → Partition 2

Both groups read ALL messages independently — each maintains its own offset!
This is the fundamental difference from traditional queues.

Scale out consumer group:
  Before: 2 consumers → 1 processes 2 partitions, 1 processes 1 partition
  Add consumer: rebalance → each processes 1 partition → more parallelism
  Rule: never add more consumers than partitions (idle consumers)
```

### Offsets — How Consumers Track Position

```
Consumer group offset = "how far have we read in each partition?"
Stored in Kafka's internal topic: __consumer_offsets

At-least-once delivery (default):
  1. Read message at offset 5
  2. Process (e.g., update DB)
  3. Commit offset 5
  If consumer crashes between step 2 and 3 → reprocess message on restart
  Your application must be IDEMPOTENT (safe to process same message twice)

At-most-once:
  1. Commit offset BEFORE processing
  2. Process
  If crash between 1 and 2 → message skipped (lost)
  Use only: when losing messages is acceptable (metrics, click tracking)

Exactly-once (with transactions):
  Kafka Transactions: atomic produce + consume + commit
  Consumer → process → produce result → commit offset — all or nothing
  Complex to implement. Use: financial transactions, deduplication-critical

Re-read from beginning:
  kafka-consumer-groups.sh --reset-offsets --to-earliest --topic order-events
  Consumer group will re-read ALL messages (Kafka retains them by default for 7 days)
  Powerful for: reprocessing, backfill, debugging
```

### Kafka Retention

```
Retention policies (topic-level config):
  Time-based:   retain messages for N days (default: 7 days)
                log.retention.hours=168
  Size-based:   retain until topic reaches N bytes
                log.retention.bytes=1073741824  (1GB)
  Compact:      keep only the LATEST value per key
                log.cleanup.policy=compact
                Use for: state store, current-value-only topics (user preferences)

Kafka is NOT a database — don't use it as one.
Long retention is for replay/catch-up. Delete old data to save disk.
```

### Kafka Configuration Tuning

```
Producer:
  acks=all:            wait for all replicas to acknowledge write (safest, slower)
  acks=1:              leader acknowledges (fast, lose data if leader crashes before replication)
  acks=0:              fire and forget (fastest, may lose data)
  retries=Integer.MAX_VALUE + enable.idempotence=true: safe exactly-once producer
  linger.ms=5:         batch messages for 5ms before sending (more efficient)
  batch.size=16384:    batch size in bytes

Consumer:
  auto.offset.reset=earliest: start from beginning if no committed offset
  auto.offset.reset=latest:   start from newest messages (skip history)
  max.poll.records=500:       max messages per poll call
  enable.auto.commit=false:   manual commit (safer, prevents loss)
  isolation.level=read_committed: only read committed transactional messages
```

---

## 3. RabbitMQ

### What RabbitMQ Is

```
RabbitMQ = traditional message broker with rich routing capabilities.
Based on AMQP protocol (Advanced Message Queuing Protocol).
Messages are routed through EXCHANGES before landing in QUEUES.

Difference from Kafka:
  Kafka:      event log, messages persist after consumption, replay possible
  RabbitMQ:   message queue, messages deleted after consumption (by default)
  Kafka:      pull-based consumers, partitioned parallelism
  RabbitMQ:   push-based consumers (broker pushes), flexible routing
```

### Exchange Types — The Routing Logic

```
Producer → Exchange → Binding → Queue → Consumer

Exchange: decides WHERE to route messages based on routing key + binding rules

1. Direct Exchange:
   Route to queues whose binding key EXACTLY matches routing key
   Producer: routingKey="order.placed"
   Queue A bound with: "order.placed" → receives it
   Queue B bound with: "order.shipped" → does NOT receive it
   Use: simple point-to-point with explicit routing

2. Topic Exchange (most flexible):
   Route based on pattern matching (* = one word, # = zero or more words)
   Producer: routingKey="order.us.placed"
   Queue A bound with: "order.*.placed" → receives it (* matches "us")
   Queue B bound with: "order.#" → receives it (# matches "us.placed")
   Queue C bound with: "payment.#" → does NOT receive it
   Use: publish/subscribe with topic filtering

3. Fanout Exchange:
   Ignores routing key — sends to ALL bound queues
   Producer sends one message → ALL queues receive a copy
   Use: broadcast (notify all services of an event)

4. Headers Exchange:
   Routes based on message headers instead of routing key
   Complex, rarely used in practice

5. Default (Nameless) Exchange:
   Direct exchange pre-created by RabbitMQ
   Routing key = queue name (simplest setup, no explicit exchange)
```

### RabbitMQ Full Flow

```
Order Service                                          Consumers
──────────                                             ─────────
publish(                                               Inventory Service:
  exchange="orders",         ┌──Exchange──┐            ← bound to queue "inventory"
  routingKey="order.placed", │  (topic)   │            process: reserve stock
  body=orderJSON             └──────┬─────┘
)                                   │
                        ┌───────────┼───────────┐
                        │           │           │
                   Queue:       Queue:      Queue:
                  inventory    notification  analytics
                        │           │           │
                  Consumer:   Consumer:  Consumer:
                  reserve     send email  log to DW
                  stock

Each queue can have:
  Multiple consumers (competing consumers — load balancing)
  Durability: durable=true (survives RabbitMQ restart)
  Message TTL: delete unprocessed messages after N ms
  Dead Letter Exchange: redirect failed/expired messages
  Max length: reject new messages when queue is full
  Priority: 0-255 priority per message
```

### Dead Letter Queue (DLQ) Pattern

```
When a message fails (consumer throws exception):
  NACK (negative acknowledgement) → message rejected

What happens to rejected messages?
  Without DLQ: re-queued indefinitely → poison pill (crashes consumer forever)
  With DLQ:    after N failures → routed to Dead Letter Exchange → Dead Letter Queue

DLQ setup:
  queue: orders
  x-dead-letter-exchange: dlx
  x-dead-letter-routing-key: orders.dead

  After 3 NACKs: message moves to orders.dead queue
  Ops team: inspect DLQ, investigate why messages failed, fix and reprocess

This is a universal pattern across all queuing systems:
  RabbitMQ: Dead Letter Exchange → Dead Letter Queue
  AWS SQS:  Dead Letter Queue (separate SQS queue)
  Kafka:    Dead Letter Topic (convention, not built-in)
  Azure SB: Dead-letter sub-queue (built-in per queue)
```

---

## 4. AWS SQS — Simple Queue Service

### Standard vs FIFO Queue

```
Standard Queue:
  Throughput:    Virtually unlimited (100K+ msg/sec)
  Ordering:      Best-effort (mostly in order, not guaranteed)
  Delivery:      At-least-once (may deliver same message 2+ times)
  Use:           High-throughput, order not critical (image processing, emails)

FIFO Queue:
  Throughput:    3,000 msg/sec with batching, 300 without
  Ordering:      Strict FIFO per message group
  Delivery:      Exactly-once (deduplication built in)
  Naming:        Must end in .fifo (e.g., orders.fifo)
  Use:           Financial transactions, state machines, ordering critical

Message Group ID (FIFO):
  All messages with same MessageGroupId are processed in order
  Different MessageGroupIds processed in parallel
  MessageGroupId = userId → all user's events in order

Deduplication ID (FIFO):
  ContentBasedDeduplication: hash of message body = dedup ID
  MessageDeduplicationId: you provide explicit ID
  Within 5-minute window: duplicate with same ID silently discarded
```

### SQS Key Concepts

```
Visibility Timeout:
  When consumer reads a message → message becomes "invisible" to other consumers
  Default: 30 seconds. If not ACK'd (deleted) in time → message reappears.
  Set visibility timeout > your processing time (avoid duplicate processing)
  Extend during processing: ChangeMessageVisibility API call

  Consumer reads → 30s timer starts → process → delete message before 30s
  If crash:         30s expires → message reappears → another consumer picks up

Long Polling (vs Short Polling):
  Short polling: SQS returns immediately even if queue is empty → wasted API calls
  Long polling:  SQS waits up to 20s for a message → fewer empty responses
  Setting:       WaitTimeSeconds=20 (always use long polling in production)
  Cost saving:   Long polling reduces API calls by ~90% on empty queues

Message Retention:
  Default: 4 days. Maximum: 14 days. Minimum: 1 minute.
  Messages older than retention period are automatically deleted.

Batch operations:
  SendMessageBatch:     send up to 10 messages in one API call
  DeleteMessageBatch:   delete up to 10 messages (ACK batch after processing)
  ReceiveMessage(10):   receive up to 10 at once (reduces API calls)
  Cost: $0.40 per million requests → batching saves 10x API calls → 10x cheaper
```

### SQS Dead Letter Queue Setup

```python
import boto3

sqs = boto3.client('sqs')

# Create DLQ first
dlq = sqs.create_queue(QueueName='orders-dlq')
dlq_arn = sqs.get_queue_attributes(
    QueueUrl=dlq['QueueUrl'],
    AttributeNames=['QueueArn']
)['Attributes']['QueueArn']

# Create main queue with DLQ configured
main_queue = sqs.create_queue(
    QueueName='orders',
    Attributes={
        'RedrivePolicy': json.dumps({
            'deadLetterTargetArn': dlq_arn,
            'maxReceiveCount': '3'   # after 3 failures → move to DLQ
        }),
        'VisibilityTimeout': '60',
        'MessageRetentionPeriod': '345600'  # 4 days
    }
)

# Consumer — process with proper ACK/NACK
while True:
    response = sqs.receive_message(
        QueueUrl=main_queue['QueueUrl'],
        MaxNumberOfMessages=10,
        WaitTimeSeconds=20,          # long polling
        VisibilityTimeout=60
    )
    for message in response.get('Messages', []):
        try:
            process(message['Body'])
            # Success: delete the message
            sqs.delete_message(
                QueueUrl=main_queue['QueueUrl'],
                ReceiptHandle=message['ReceiptHandle']
            )
        except Exception as e:
            # Don't delete — message becomes visible after timeout
            # After 3 failures, SQS moves it to DLQ automatically
            logging.error(f"Failed to process: {e}")
```

### SQS + Lambda Integration

```python
# Lambda function triggered by SQS (event source mapping)
# Lambda polls SQS internally — you don't write polling code

import json

def handler(event, context):
    for record in event['Records']:
        body = json.loads(record['body'])
        try:
            process_order(body)
            # Returning normally = success → SQS deletes the message
        except Exception as e:
            # Raising exception = failure → SQS makes message visible again
            raise e
    # Partial batch response (Lambda feature):
    # return {"batchItemFailures": [{"itemIdentifier": record["messageId"]}]}
    # → only re-queue failed items, not the whole batch

# Lambda configuration:
#   Batch size: 1-10,000 messages per invocation
#   Concurrency: one Lambda per shard of messages
#   Error handling: bisect on error (split failing batch in half to isolate poison pill)
```

---

## 5. AWS SNS — Simple Notification Service

### Pub/Sub Model

```
SNS = Publisher/Subscriber notification service.
Unlike SQS (pull), SNS PUSHES notifications to subscribed endpoints.

Topic: named channel (arn:aws:sns:us-east-1:123:order-events)
Publisher: sends message to topic
Subscribers: receive all messages from topic

Subscriber types:
  SQS queue:     fan-out → queue → consumer processes at own pace (recommended)
  Lambda:        direct invocation per message
  HTTP/HTTPS:    webhook to external endpoint
  Email:         literally send email (ops notifications)
  SMS:           text message
  Mobile Push:   APNS (Apple), FCM (Google), ADM (Amazon)

Fan-out pattern (most important use case):
  Order placed → SNS topic → SQS queue (inventory)
                          → SQS queue (notification)
                          → SQS queue (analytics)
                          → Lambda (fraud check)

Why SNS → SQS (not direct to Lambda)?
  SQS provides: buffering, retry, DLQ, rate limiting
  Lambda direct: if Lambda fails, message lost (no buffer)
  SNS → SQS → Lambda: buffer + retry + DLQ + Lambda processing
```

### SNS Message Filtering

```
Without filtering: ALL subscribers receive ALL messages.
With filtering: each subscriber only receives messages matching its filter policy.

Example: order-events topic, different teams subscribe differently:

Inventory team subscribes with filter:
{
  "status": ["placed", "cancelled"],
  "region": ["us", "eu"]
}
→ Only receives placed and cancelled orders from US and EU

Notification team subscribes with filter:
{
  "status": ["placed", "shipped", "delivered"]
}
→ Only receives status change events for email notifications

Analytics team: no filter → receives everything

Cost saving: filter at SNS instead of filtering in each consumer.
```

---

## 6. Azure Service Bus

### Queues vs Topics

```
Service Bus Queue:
  Point-to-point: one sender → one receiver (competing consumers)
  Like SQS Standard Queue but with richer features
  FIFO with sessions (see below)
  Max message size: 100MB (Premium), 256KB (Standard)

Service Bus Topic:
  Pub/Sub: one sender → multiple receivers via subscriptions
  Like SNS → SQS combined
  Each subscription is an independent filtered queue
  Use: fan-out within Azure ecosystem

  Topic: order-events
  ├── Subscription: inventory   (filter: status = 'placed')
  ├── Subscription: notification (filter: no filter = all)
  └── Subscription: analytics    (filter: no filter = all)

Comparison:
  SQS + SNS = Service Bus Queue + Topic (roughly equivalent)
  Service Bus adds: sessions, duplicate detection, transactions, larger messages
```

### Service Bus Sessions (FIFO Guarantee)

```
Sessions = Service Bus's way to guarantee ordered processing per entity.
Equivalent to Kafka's partition keys or SQS FIFO's MessageGroupId.

Session ID = group identifier (e.g., orderId, userId)
All messages with same SessionID delivered in order to the same consumer.
Different SessionIDs processed in parallel by different consumers.

Session receiver — locks an entire session:
  Consumer A locks session "order-123" → processes all its messages in order
  Consumer B locks session "order-456" → parallel, independent

Use when: events for the same entity must be processed in sequence.
```

### Azure Service Bus vs SQS/SNS vs Kafka

```
                Service Bus     SQS/SNS         Kafka
────────────────────────────────────────────────────────
Protocol        AMQP, HTTP      HTTP/SQS        Native, HTTP
Ordering        Sessions (FIFO) FIFO queues     Per-partition
Max msg size    100MB Premium    256KB SQS       1MB default (configurable)
Message TTL     14 days         14 days         Configurable (days to forever)
Replay          No (consumed=gone) No           Yes (retain and replay)
Throughput      Moderate        Very high       Extremely high
Dead letter     Built-in        Separate queue  Convention (dead.orders topic)
Transactions    Yes             No              Yes (Kafka transactions)
Scheduled msgs  Yes             Message timers  No
At-least-once   Yes             Yes             Yes
Exactly-once    Yes (Premium)   FIFO only       Yes (transactions)
Use case        Enterprise BizApps AWS workloads High-throughput streams
```

---

## 7. Azure Event Hubs

### What Event Hubs Is

```
Azure Event Hubs = Azure's version of Apache Kafka.
Built for high-throughput event streaming (telemetry, clickstream, IoT).
Kafka protocol compatible — Kafka producers/consumers work with Event Hubs.

Key concepts map to Kafka:
  Event Hub  ↔  Kafka Topic
  Partition  ↔  Kafka Partition
  Consumer Group ↔  Kafka Consumer Group
  Namespace  ↔  Kafka Cluster

Throughput units (Standard) or Processing units (Premium):
  Each unit = 1 MB/s ingress, 2 MB/s egress
  Auto-inflate: automatically scales TUs on demand

Retention: 1-7 days (Standard), up to 90 days (Premium)
Capture:   auto-save events to Azure Blob Storage / Data Lake (Avro format)
           enables long-term analytics without separate pipeline
```

### Event Hubs vs Service Bus

```
Use Event Hubs when:          Use Service Bus when:
  High throughput (millions)    Moderate throughput (thousands/s)
  Telemetry, logs, metrics      Business transactions
  Multiple consumers / replay   Point-to-point queue
  Kafka migration               AMQP protocol required
  Stream processing             Message ordering (sessions)
  IoT data ingestion            Dead letter queue needed
  No ordering needed            Enterprise integration patterns
  Events = facts                Messages = commands
```

---

## 8. Messaging Patterns

### Pattern 1: Competing Consumers (Load Balancing)

```
Multiple consumers reading from the same queue.
Queue distributes messages across consumers.

Queue: orders
Consumer A ←─────── Queue ──────────────► Consumer B
                       └──────────────► Consumer C

Scale out: add more consumers → proportionally more throughput
Scale in:  remove consumers → remaining pick up slack
Used by: SQS, Service Bus queues, Kafka (within a consumer group)
```

### Pattern 2: Fan-out (Pub/Sub)

```
One message → multiple independent consumers each get a copy.

SNS/Service Bus Topic fan-out:
  Producer ──► SNS Topic ──► SQS Queue (inventory)  ──► Consumer
                          ──► SQS Queue (notification)──► Consumer
                          ──► Lambda (fraud check)

Kafka fan-out (multiple consumer groups):
  Producer ──► Kafka Topic ──► Consumer Group (inventory)
                           ──► Consumer Group (notification)
                           ──► Consumer Group (analytics)
  All groups read all messages independently.
```

### Pattern 3: Saga Pattern (Distributed Transactions)

```
Problem: Order service needs to: reserve inventory, charge payment, send email.
         All three must succeed or all roll back (atomically).
         But they're separate services — no distributed transaction possible.

Saga pattern: each step publishes an event; if step N fails, compensating events undo steps 1-(N-1).

Choreography (event-driven):
  1. OrderService publishes OrderPlaced
  2. InventoryService receives OrderPlaced → reserves stock → publishes StockReserved
  3. PaymentService receives StockReserved → charges card → publishes PaymentCharged
  4. EmailService receives PaymentCharged → sends email → publishes OrderConfirmed
  On failure:
  5. PaymentService fails → publishes PaymentFailed
  6. InventoryService receives PaymentFailed → releases reservation → publishes StockReleased
  7. OrderService receives StockReleased → marks order failed

Orchestration (central coordinator, e.g., AWS Step Functions):
  OrderOrchestrator calls each service in sequence
  On failure: calls compensating transactions in reverse order
  Easier to understand, single point of failure
```

### Pattern 4: Outbox Pattern (Prevent Lost Messages)

```
Problem:
  Service updates DB AND publishes to Kafka in one operation.
  If DB succeeds but Kafka publish fails → data inconsistency.
  If Kafka publishes but DB fails → phantom event.

Outbox pattern:
  1. Service writes to DB AND outbox table in one DB transaction (atomic)
  2. Separate outbox poller reads the outbox table
  3. Poller publishes to Kafka / queue
  4. On success: marks outbox row as published
  5. On failure: retry publishing (outbox row stays unpublished)

  DB Transaction:
    INSERT INTO orders (id, ...) VALUES (...)
    INSERT INTO outbox (event_type, payload, published) VALUES ('OrderPlaced', ..., false)

  Outbox poller runs every 100ms:
    SELECT * FROM outbox WHERE published = false
    → publish to Kafka
    → UPDATE outbox SET published = true WHERE id = ...

Guarantees: at-least-once delivery with no lost events and no DB inconsistency.
Used with: Debezium (CDC — change data capture) reads DB write-ahead log and publishes to Kafka.
```

### Pattern 5: Request-Reply over Queue (Async RPC)

```
When you need a response but want async benefits.

1. Sender creates a reply-to queue (or uses temporary queue)
2. Sends message with header: replyTo="response-queue-xyz", correlationId="abc123"
3. Receiver processes and publishes response to reply-to queue with same correlationId
4. Sender polls reply-to queue, matches correlationId

Use: long-running operations where you don't want to hold HTTP connection.
Example: "Process this 10GB file" → queue → processing service → response queue → caller

Modern alternative: use WebSocket or Server-Sent Events for callbacks instead.
```

---

## 9. Kafka vs RabbitMQ vs SQS — When to Choose

| Criteria | Kafka | RabbitMQ | AWS SQS |
|---|---|---|---|
| **Throughput** | Millions/sec | ~50K/sec | Hundreds of thousands/sec |
| **Message replay** | Yes — retain for days | No — consumed = gone | No |
| **Ordering** | Per-partition | Per-queue (limited) | FIFO queue (limited) |
| **Routing** | Topic + partition key | Flexible (exchange types) | Basic |
| **Protocol** | Kafka native, HTTP | AMQP, STOMP, MQTT | HTTP/SQS |
| **Operational complexity** | High (cluster, ZK/KRaft) | Medium (broker) | Zero (managed) |
| **Message size** | 1MB default | 128MB | 256KB |
| **Retention** | Days (configurable) | Until consumed | Up to 14 days |
| **Consumer model** | Pull (consumer polls) | Push (broker pushes) | Pull (long polling) |
| **Best for** | Event streaming, logs, analytics | Complex routing, BizApps, RPC | AWS microservices, simple queues |
| **Managed cloud** | Confluent, AWS MSK, Azure EH | CloudAMQP, AmazonMQ | SQS (native) |

**Decision framework:**

```
Need to replay messages / multiple consumers read same data?
  → Kafka (or Azure Event Hubs, AWS Kinesis)

Need complex routing (content-based, fanout, topic filter)?
  → RabbitMQ (or Azure Service Bus Topics + subscriptions)

Need simplest possible managed queue on AWS?
  → SQS (no servers, infinite scale, pay per message)

Need strict FIFO ordering with deduplication?
  → SQS FIFO or Kafka (keyed partitions)

Need very large messages (> 256KB)?
  → RabbitMQ (128MB) or Service Bus (100MB) or S3 + queue reference

Building event-driven microservices on AWS from scratch?
  → SQS + SNS (simple, managed, native AWS integration)

High-throughput event streaming (IoT, logs, clickstream)?
  → Kafka or Azure Event Hubs
```

---

## 10. Interview Questions

### Q: Explain the difference between a queue and a topic (pub/sub).

**Queue (point-to-point):**
One message is consumed by exactly ONE consumer.
If 3 consumers are listening, only one gets each message (competing consumers).
Use: workload distribution, task processing.

**Topic (pub/sub):**
One message is delivered to ALL subscribers.
If 3 subscribers are listening, each gets a copy of every message.
Use: event notifications, fan-out, decoupled broadcast.

Examples:
- SQS Queue: point-to-point
- SNS Topic: pub/sub
- Kafka: acts as both — one consumer group = queue behaviour, multiple groups = pub/sub

---

### Q: How does Kafka guarantee message ordering?

Kafka guarantees ordering **within a partition**, not across partitions.

If you produce 3 messages without a key (round-robin):
- Message 1 → Partition 0
- Message 2 → Partition 1
- Message 3 → Partition 2
No global ordering. Each partition is ordered internally, but consumers read partitions independently.

If you produce with a key (e.g., orderId):
- All messages for order-123 go to the same partition (hash(order-123) % N)
- Within that partition, messages are in order (offset 0, 1, 2...)
- Consumer processes order-123's events in order

Design rule: use keys when you need ordering for a specific entity (userId, orderId).

---

### Q: What is a consumer group and why is it important in Kafka?

A consumer group is a set of consumers that collectively consume all partitions of a topic.

Each partition is assigned to exactly one consumer in the group at any time.
Adding consumers to a group increases parallel processing capacity (up to the partition count).

**Isolation:** Multiple independent consumer groups read the same topic independently.
Each group has its own committed offsets — one group's consumption doesn't affect another.

This enables:
- Fan-out: inventory team and notification team both consume the same order-events independently
- Parallelism: scale the inventory consumer group to 10 instances → 10x throughput

---

### Q: What happens when a consumer crashes mid-processing in SQS?

1. Consumer receives message → SQS makes it invisible (visibility timeout starts, e.g., 30s)
2. Consumer crashes mid-processing
3. No ACK (delete) sent to SQS
4. Visibility timeout expires → message becomes visible again
5. Another consumer (or the restarted consumer) receives and processes the message

This is **at-least-once delivery** — the message is processed twice if consumer crashes between receiving and deleting.

Your application must handle duplicates (idempotent processing):
- Check if order was already processed before processing again
- Use DynamoDB conditional writes (only write if item doesn't exist)

After `maxReceiveCount` failures → SQS automatically moves message to Dead Letter Queue.

---

### Q: Kafka vs RabbitMQ — which would you choose for an order processing system?

**My choice: depends on requirements.**

If orders need strict FIFO per customer and replay isn't needed:
→ RabbitMQ with direct/topic exchange. Simpler, consumer gets push notification. Dead letter queue for failures. Sessions-like ordering with consistent hashing.

If high-throughput, need to replay (for auditing/debugging), multiple teams consume independently:
→ Kafka. Partition by customerId → per-customer ordering. Multiple consumer groups (inventory, notification, analytics) each read all events. Replay last 7 days if audit needed.

In practice at Voya: AWS SQS + SNS for most microservice communication (managed, zero operational overhead). Kafka/Event Hubs for high-throughput streaming (ETL pipelines, ML feature pipelines).

---

### Q: What is the visibility timeout in SQS and how do you set it correctly?

Visibility timeout is the period during which a received message is hidden from other consumers.

**Too short:** Message reappears before processing completes → multiple consumers process same message simultaneously → data corruption.

**Too long:** If consumer crashes, message is hidden for the full timeout before redelivery → slow failure recovery → increased processing latency.

**Rule:** Set visibility timeout > maximum expected processing time + buffer.

For variable processing times:
Use `ChangeMessageVisibility` API to extend the timeout while actively processing.
Heartbeat pattern: every 25 seconds, extend visibility by 30 more seconds while still working.

```python
import threading
def heartbeat(sqs, queue_url, receipt_handle, stop_event):
    while not stop_event.is_set():
        sqs.change_message_visibility(
            QueueUrl=queue_url,
            ReceiptHandle=receipt_handle,
            VisibilityTimeout=60   # extend by 60 more seconds
        )
        time.sleep(45)

stop_event = threading.Event()
threading.Thread(target=heartbeat, args=(sqs, url, handle, stop_event)).start()
try:
    process(message)
    sqs.delete_message(...)
finally:
    stop_event.set()  # stop heartbeat
```

---

## Quick Reference

```
Kafka:
  Topic → Partition (ordered log, immutable, offset-based)
  Producer key → same key = same partition = ordered for that key
  Consumer group → each partition = 1 consumer, multiple groups = fan-out
  Offset commit → at-least-once (default), exactly-once (transactions)
  Retention → configurable (default 7 days), replay possible
  Use: high-throughput, replay, multiple independent consumers

RabbitMQ:
  Exchange types: direct (exact), topic (wildcard), fanout (all), headers
  Routing key → exchange routes to bound queues
  ACK/NACK → message stays until ACK'd or moves to DLQ
  Dead letter: DLX + DLQ pattern after N failures
  Use: complex routing, transactional messaging, BizApps

AWS SQS:
  Standard: unlimited throughput, at-least-once, best-effort order
  FIFO:     3000/s, exactly-once, strict FIFO per MessageGroupId
  Visibility timeout: hide from other consumers during processing
  Long polling: WaitTimeSeconds=20 (always use)
  DLQ: maxReceiveCount → auto-move failed messages
  Use: AWS-native, simple, managed, no ops

Azure Service Bus:
  Queue: point-to-point with sessions (FIFO per SessionId)
  Topic: pub/sub with filtered subscriptions
  Built-in DLQ per queue/subscription
  Sessions: ordered delivery per entity (like Kafka partition key)
  Use: Azure-native BizApps, enterprise integration

Azure Event Hubs:
  Kafka-compatible (use Kafka SDK against Event Hubs)
  Partitions + consumer groups (same as Kafka)
  Capture: auto-archive to Blob Storage
  Use: IoT, telemetry, high-throughput streaming on Azure

Key patterns:
  Competing consumers:  scale processing by adding consumers
  Fan-out:              SNS → multiple SQS queues or Kafka consumer groups
  Dead letter:          isolate poison pill messages for investigation
  Outbox:               DB + queue atomically via outbox table + poller
  Saga:                 distributed transaction via events + compensation
  Visibility heartbeat: extend SQS timeout for long-running processing
```
