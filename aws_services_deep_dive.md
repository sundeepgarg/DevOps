# AWS Services Deep Dive — Addendum

**Covers gaps in aws_cloud_interview_guide.md:**
EC2, Lambda, DynamoDB, Secrets Manager, KMS, ECR, CodePipeline/CodeBuild, Step Functions

---

## 1. EC2 — Elastic Compute Cloud

### Instance Types

```
Family  Purpose                  Examples
──────────────────────────────────────────────────────────
t3/t4g  Burstable (cheapest)     t3.micro, t4g.small
         CPU credits build up at idle, spent during burst
         Use: dev/test, low-traffic web apps

m5/m6i  General purpose          m5.large, m6i.xlarge
         Balanced CPU+RAM         Use: app servers, small DBs

c5/c6i  Compute optimised        c5.2xlarge
         High vCPU:memory ratio   Use: batch, CI/CD workers, ML inference

r5/r6i  Memory optimised         r5.4xlarge, x1e.32xlarge
         High RAM:vCPU ratio      Use: in-memory DBs, Redis, SAP HANA

p3/p4   GPU (Nvidia)             p3.2xlarge (V100), p4d.24xlarge (A100)
         Use: ML training, video encoding

g4/g5   GPU (inference)          g4dn.xlarge (T4), g5.xlarge (A10G)
         Use: ML inference, gaming, graphics

i3/i4i  Storage optimised        i3.large (NVMe SSD)
         High IOPS local storage   Use: Cassandra, Elasticsearch, data warehousing
```

### Purchasing Options

```
On-Demand:    Pay per second. No commitment. Most expensive.
              Use: unpredictable workloads, short-term spikes

Reserved:     1 or 3 year commitment. Up to 72% discount.
  Standard RI:  locked to instance type+region. Highest discount.
  Convertible RI: can change instance family. Lower discount (~54%).
              Use: stable, always-on workloads (web servers, databases)

Spot:         Use spare AWS capacity. Up to 90% discount.
              Interrupted with 2-min warning when AWS needs capacity back.
              Use: batch jobs, ML training, fault-tolerant workloads.
              NOT for: web servers, DBs, anything stateful.

Savings Plans: Commitment to $/hour spend (not specific instance).
  Compute SP:  most flexible — applies to EC2, Lambda, Fargate
  EC2 SP:      cheaper — locked to instance family+region
              Use: mix of instance types, easier than managing RIs

Dedicated Host: Physical server for you. Most expensive.
              Use: BYOL (Bring Your Own License), compliance requirements

Spot Fleet / Spot Instances strategy:
  Request multiple instance types across AZs
  Set max price = On-Demand price → always get spot if available
  Diversify → less chance of all instances being reclaimed together
```

### Auto Scaling Groups (ASG)

```
ASG manages fleet of EC2 instances:
  Min capacity:    always running (at least)
  Desired capacity: what ASG targets right now
  Max capacity:    never exceed this

Scaling policies:
  Target tracking: keep metric at target
    e.g., "keep average CPU at 70%"
    ASG adds instances when CPU > 70%, removes when < 70%
    → simplest, recommended for most cases

  Step scaling: scale by fixed amount when threshold crossed
    e.g., "CPU > 70%: add 2 instances; CPU > 90%: add 5 instances"
    → more control, useful for non-linear workload spikes

  Simple scaling: one action per alarm (deprecated, use step scaling)

  Scheduled scaling: scale at specific time
    e.g., add 10 instances every weekday at 8am, remove at 8pm

Cooldown period (default 300s):
  After scaling, wait before scaling again (prevents thrashing)

Health checks:
  EC2 health check: is the instance running? (always enabled)
  ELB health check: is the app responding? (enable for web apps)
  If unhealthy: ASG terminates and replaces automatically
```

### Placement Groups

```
Cluster placement group:
  All instances in SAME rack in SAME AZ
  Low latency (<1ms), high bandwidth (10+ Gbps between instances)
  Risk: if rack fails, all instances fail
  Use: HPC, tightly coupled parallel compute, ML training

Spread placement group:
  Instances on DIFFERENT racks (max 7 per AZ)
  Each instance has independent power and network
  Use: small critical apps needing highest availability

Partition placement group:
  Instances split into partitions, each on different rack
  No two partitions share rack (independent failure)
  Use: Hadoop, Cassandra, Kafka (distributed systems)
```

### EC2 User Data and IMDSv2

```bash
# User data: script runs once at first launch (bootstrap)
#!/bin/bash
yum update -y
yum install -y httpd
systemctl start httpd
systemctl enable httpd
echo "Hello from $(hostname)" > /var/www/html/index.html

# IMDSv2 (Instance Metadata Service v2) — always use v2
# v1 was vulnerable to SSRF attacks (token not required)
# v2 requires a session token

# Get instance metadata securely (IMDSv2):
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
```

---

## 2. Lambda — Serverless Functions

### Execution Model

```
Event source ──► Lambda Service ──► Your function (execution environment)

Execution environment lifecycle:
  1. INIT:    AWS provisions a container (micro-VM), installs your package
              Runs your initialization code (outside handler)
              Duration: 100ms–5s depending on runtime and package size
              This is the "COLD START"

  2. INVOKE:  Your handler() is called with the event
              Container stays warm for ~15 minutes after invocation

  3. RE-USE:  Next invocation reuses the same container (NO cold start)
              Variables outside handler() persist between invocations!

  4. SHUTDOWN: Container destroyed after ~15 min idle

Cold start impact:
  Python/Node.js: 100–300ms (acceptable)
  Java:           500ms–2s  (bad for latency-sensitive APIs)
  .NET:           400ms–1s

Reduce cold starts:
  → Provisioned Concurrency: pre-warm N containers (always hot, costs $)
  → Keep package small (<10MB unzipped ideal)
  → Use Layers for dependencies (cached separately)
  → Lambda SnapStart for Java: takes snapshot of initialized container
```

### Triggers (Event Sources)

```
Synchronous (waits for response):
  API Gateway    → HTTP request → Lambda → response to caller
  ALB            → HTTP request → Lambda → response
  Lambda invoke  → direct SDK call (RequestResponse mode)

Asynchronous (fire and forget):
  S3             → object PUT/DELETE → Lambda (retries 2x on failure)
  SNS            → message publish → Lambda
  EventBridge    → scheduled or event rule → Lambda
  SES            → incoming email → Lambda

Polling (Lambda polls the source):
  SQS            → Lambda polls queue, processes batch (1–10,000 messages)
  Kinesis        → Lambda polls shard, processes records in order
  DynamoDB Stream→ Lambda processes change events
  MSK/Kafka      → Lambda polls topics

Key differences:
  SQS trigger:     batch size configurable, on-failure → DLQ
  Kinesis trigger: ordered within shard, checkpoint-based (can replay)
  S3 trigger:      at-least-once delivery (may fire twice for same event)
```

### Concurrency

```
Reserved concurrency:
  Guarantee N concurrent executions for this function
  No other function can steal these slots
  Also acts as a CAP — function never exceeds N
  Use: isolate critical functions; limit downstream DB connections

Provisioned concurrency:
  Pre-initialise N execution environments (no cold starts)
  Costs $ even when idle (like reserved instances)
  Use: latency-critical APIs, trading, payments

Account concurrency limit: 1,000 per region (default, can raise)
Burst concurrency: 3,000 (immediate) then +500/minute

Concurrency math:
  Concurrent executions = requests_per_second × avg_duration_seconds
  100 rps × 0.1s duration = 10 concurrent executions
  1000 rps × 2s duration  = 2000 concurrent executions (hits limit!)
```

### Lambda Layers

```
A Layer = ZIP archive with libraries/dependencies.
Can be shared across multiple functions.

Why use layers:
  → Reduce deployment package size (only upload your code, not boto3)
  → Share common utilities (logging, monitoring wrappers) across functions
  → Update dependencies independently of function code

Up to 5 layers per function.
Layer stored in /opt/ inside the execution environment.

Example:
  Layer: numpy + pandas (100MB)
  Function code: data_processor.py (5KB)
  Deploy: only upload 5KB → faster, reuses cached layer
```

### Lambda VPC Integration

```
By default: Lambda runs in AWS-managed VPC (can reach internet, cannot reach your VPC)

With VPC config: Lambda runs in YOUR VPC subnet
  → Can access RDS, ElastiCache, internal services
  → LOSES internet access (unless you add NAT Gateway)

VPC Lambda cold start: was +1-2s (waiting for ENI creation)
Since 2019 HyperPlane ENIs: cold start penalty eliminated for VPC Lambdas

When to use VPC Lambda:
  → Must access RDS / ElastiCache (no public endpoint)
  → Must access internal services
  → Security requirement (no internet access from function)
```

### Lambda@Edge vs CloudFront Functions

```
Lambda@Edge:
  Runs at CloudFront edge locations (not regional)
  Triggers: viewer request, viewer response, origin request, origin response
  Full Lambda runtime (Node.js, Python)
  Max duration: 5s (viewer-side), 30s (origin-side)
  Use: auth at edge, URL rewrites, A/B testing, header manipulation

CloudFront Functions:
  Faster, cheaper, more restricted
  Only: viewer request and viewer response
  Max duration: 1ms (extremely lightweight)
  Use: simple header manipulation, URL redirects, cookie rewriting
```

---

## 3. DynamoDB — Deep Dive

### Data Model

```
Table → Items (rows) → Attributes (columns, but schema-free)

Primary Key options:
  Simple (Partition Key only):
    Each item uniquely identified by ONE attribute
    e.g., userId="user123"

  Composite (Partition Key + Sort Key):
    Partition key groups items together
    Sort key orders items within the partition
    e.g., PK=userId + SK=timestamp → all events for a user, sorted by time
```

### Partitions and the Partition Key

```
DynamoDB distributes data across partitions (internal storage units).
Partition key is HASHED → determines which partition an item goes to.

HOT PARTITION PROBLEM:
  If one PK value gets all traffic → one partition overloaded
  e.g., PK=date → all writes today go to ONE partition → throttling

Design for even distribution:
  BAD:  PK = "US" (most users in US → hot)
  BAD:  PK = timestamp (all writes go to current second → hot)
  GOOD: PK = userId (random distribution)
  GOOD: PK = tenantId + suffix (userId%10 → spread over 10 partitions)

One-table design pattern (Alex DeBrie):
  Store multiple entity types in one table using PK/SK patterns
  PK="USER#123"  SK="PROFILE"  → user profile
  PK="USER#123"  SK="ORDER#456" → user's order
  Enables efficient access patterns without joins
```

### Indexes

```
Local Secondary Index (LSI):
  Same partition key as table, different sort key
  Created AT TABLE CREATION — cannot add later
  Shares throughput with the base table
  Use: query same partition with different sort criteria

Global Secondary Index (GSI):
  Different partition key AND sort key from table
  Can add after table creation
  Has its own throughput (separate provisioning)
  Eventually consistent (base table → GSI replication ~milliseconds)
  Use: query data by a different attribute entirely

Example:
  Table: PK=orderId, SK=customerId
  GSI:   PK=customerId, SK=orderDate → "give me all orders for customer X sorted by date"
  Without GSI: would need to scan entire table (expensive!)
```

### Capacity Modes

```
Provisioned mode:
  Set Read Capacity Units (RCU) and Write Capacity Units (WCU) per second
  1 RCU = 1 strongly consistent read of up to 4KB
  2 RCU = 1 eventually consistent read of up to 4KB  (half the cost)
  1 WCU = 1 write of up to 1KB

  Auto Scaling: set min/max and target utilisation → DynamoDB adjusts
  Use: predictable traffic, cost-sensitive workloads

On-Demand mode:
  Pay per request — no capacity planning
  Scales instantly to any traffic level
  2-3x more expensive than well-provisioned mode
  Use: unpredictable traffic, new tables, dev/test

Strong vs Eventual consistency:
  Eventually consistent read: data may be slightly stale (milliseconds)
  Strongly consistent read: always returns latest data, uses 2x RCU
  Default: eventually consistent. Specify strongly consistent when needed.
```

### DynamoDB Streams + TTL

```
DynamoDB Streams:
  Ordered log of all item changes (INSERT, MODIFY, REMOVE)
  Retention: 24 hours
  Use cases:
    → Trigger Lambda on data change (event-driven architecture)
    → Replicate to another table/region
    → Invalidate cache when item changes
    → Audit trail

TTL (Time to Live):
  Set an attribute with a Unix timestamp (seconds)
  DynamoDB deletes expired items within 48 hours (lazy deletion)
  Deletion appears as REMOVE event in DynamoDB Streams
  Use: sessions, cache entries, temporary data
  Cost: FREE — deleted items not charged for delete operations
```

---

## 4. Secrets Manager vs SSM Parameter Store

### AWS Secrets Manager

```
Purpose:         Store and AUTOMATICALLY ROTATE secrets
Stores:          Database credentials, API keys, OAuth tokens, arbitrary JSON
Cost:            $0.40/secret/month + $0.05/10,000 API calls
Best for:        Anything requiring automatic rotation

Key features:
  Automatic rotation:
    Schedules Lambda to rotate secret on configurable interval
    RDS/Aurora/Redshift/DocumentDB: built-in rotation Lambdas
    Custom: write your own rotation Lambda
    Zero-downtime: creates new credential, updates app, deletes old

  Cross-account access: share secrets across AWS accounts via resource policies
  
  KMS integration: secrets encrypted at rest with CMK you control
  
  CloudTrail audit: every GetSecretValue logged with caller identity

# Python usage:
import boto3, json
client = boto3.client('secretsmanager')
response = client.get_secret_value(SecretId='prod/database/password')
secret = json.loads(response['SecretString'])
password = secret['password']
```

### SSM Parameter Store

```
Purpose:         Store configuration values and simple secrets
Stores:          Config values, non-sensitive strings, simple passwords
Cost:            Standard: FREE. Advanced: $0.05/parameter/month
Best for:        App configuration, non-rotating secrets, hierarchy of config

Tiers:
  Standard:  4KB max value, 10,000 parameters per account, FREE
  Advanced:  8KB max value, 100,000 parameters, $0.05/param/month, policies

Parameter types:
  String:       plain text value
  StringList:   comma-separated list
  SecureString: encrypted with KMS (use for sensitive values)

Hierarchy (like a filesystem):
  /myapp/prod/database/host      = "db.prod.internal"
  /myapp/prod/database/port      = "5432"
  /myapp/prod/database/password  = (SecureString, encrypted)
  
  Get all params for /myapp/prod/ in one call (path-based retrieval)

# Python usage:
ssm = boto3.client('ssm')
param = ssm.get_parameter(Name='/myapp/prod/database/password', WithDecryption=True)
password = param['Parameter']['Value']
```

### Which to Use When?

| Requirement | Use |
|---|---|
| Automatic credential rotation | Secrets Manager |
| RDS password rotation | Secrets Manager (built-in Lambda) |
| App configuration (non-sensitive) | Parameter Store (Standard, free) |
| Many simple secrets (cost-sensitive) | Parameter Store (free tier) |
| Hierarchy of config values | Parameter Store (path-based) |
| Share secrets across AWS accounts | Secrets Manager |
| Audit every secret read | Both support CloudTrail |
| Store >4KB values | Secrets Manager (up to 65KB) |

```
Quick rule:
  Needs rotation → Secrets Manager
  Config values / no rotation → Parameter Store (free)
  Both → Secrets Manager has priority for credentials
```

---

## 5. KMS — Key Management Service

### What KMS Does

```
KMS manages ENCRYPTION KEYS — it does not store your data.
You use KMS keys to encrypt/decrypt data in other services (S3, EBS, RDS, Secrets Manager).

Key types:
  AWS Managed Key (aws/s3, aws/rds, etc.):
    Automatically created when you enable encryption in a service
    Rotated annually by AWS
    You cannot see or export the key material
    No cost for key itself; charges for API calls

  Customer Managed Key (CMK):
    You create and control
    Can set rotation policy (annual automatic or manual)
    Can set key policy (who can use it)
    Can import your own key material
    $1/month per key + $0.03/10,000 API calls
    Use: compliance, cross-account, custom rotation
```

### Envelope Encryption

```
KMS never encrypts large data directly (max 4KB via API).
Instead, uses ENVELOPE ENCRYPTION:

1. You call KMS: GenerateDataKey(KeyId="cmk-id")
2. KMS returns:
   - Plaintext data key (use to encrypt your data)
   - Encrypted data key (store alongside your data)
3. Encrypt data with plaintext data key (in memory, no KMS call)
4. Store: encrypted data + encrypted data key together
5. Discard plaintext data key (never store it)

To decrypt:
1. Extract encrypted data key from storage
2. Call KMS: Decrypt(CiphertextBlob=encrypted_data_key)
3. KMS returns plaintext data key
4. Decrypt data with plaintext data key
5. Discard plaintext data key

Why? Performance: one KMS API call for any size data
     KMS key never leaves KMS hardware — plaintext data key in memory only
```

### KMS Key Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "Enable IAM User Permissions",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::123456789:root"},
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "Allow use of the key",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::123456789:role/AppRole"},
      "Action": ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"],
      "Resource": "*"
    }
  ]
}
```

**Key policy is the PRIMARY access control for KMS.** IAM policies alone are not enough —
the key policy must also allow the principal. Both must allow the action.

### Common KMS Integrations

```
S3 Server-Side Encryption:
  SSE-S3:  AWS manages key (free, no control)
  SSE-KMS: KMS CMK (audit, cross-account, key rotation control)
           Adds latency (KMS API call per object read/write)
  SSE-C:   Customer provides key per request (you manage keys)

RDS encryption:
  Enable at creation → EBS volume and snapshots encrypted with CMK
  Cannot encrypt an existing unencrypted RDS instance directly
  Workaround: snapshot → copy with encryption → restore from encrypted snapshot

EBS encryption:
  Default KMS key or CMK
  Encrypted AMIs, snapshots automatically encrypted with same key

Secrets Manager: secret values encrypted with CMK at rest
```

---

## 6. ECR — Elastic Container Registry

### What ECR Does

```
ECR = AWS-native Docker registry. Stores container images privately.
Replaces Docker Hub / Nexus for AWS workloads.

Alternatives:
  Docker Hub:    public, free tier limited (rate limits, 6hr cache for unauthenticated)
  ECR Public:    AWS public registry (gallery.ecr.aws) — for public images, free pull from AWS
  ECR Private:   your own registry per AWS account, IAM-controlled access

Advantages over Docker Hub for AWS:
  → No pull rate limits (Docker Hub: 100 pulls/6h for anonymous, 200 for free accounts)
  → IAM auth (no separate username/password)
  → Same AWS network (no data transfer costs from EKS, Lambda, ECS)
  → Vulnerability scanning built-in (ECR Enhanced Scanning via Inspector)
  → Immutable tags (prevent tag overwrite for production)
  → Cross-region replication
```

### Authentication

```bash
# Authenticate Docker to ECR (tokens expire in 12 hours)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  123456789.dkr.ecr.us-east-1.amazonaws.com

# Push an image
docker build -t my-app:v1.0 .
docker tag my-app:v1.0 123456789.dkr.ecr.us-east-1.amazonaws.com/my-app:v1.0
docker push 123456789.dkr.ecr.us-east-1.amazonaws.com/my-app:v1.0

# EKS pulls from ECR automatically if node IAM role has:
# AmazonEC2ContainerRegistryReadOnly policy attached
```

### ECR Key Features

```
Image scanning:
  Basic scanning (free): uses CVE database, scan on push
  Enhanced scanning (paid): Amazon Inspector, continuous scanning, OS + application layers

Lifecycle policies:
  Automatically delete untagged images older than N days
  Keep only last N images with tag prefix "prod-"
  Prevents registry from filling up with old build artefacts

  Example policy:
  {
    "rules": [{
      "rulePriority": 1,
      "description": "Expire untagged images older than 7 days",
      "selection": {
        "tagStatus": "untagged",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": 7
      },
      "action": {"type": "expire"}
    }]
  }

Immutable tags:
  Once pushed with tag "v1.0", cannot push a different image with "v1.0"
  Prevents accidental overwrite of production images
  Best practice: enable for production repositories

Replication:
  Cross-region: replicate to other AWS regions (for multi-region EKS clusters)
  Cross-account: replicate to other AWS accounts (share images with dev accounts)
```

### ECR Repository Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCrossAccountPull",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::987654321:root"},
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability"
      ]
    }
  ]
}
```

---

## 7. CodePipeline + CodeBuild + CodeDeploy

### AWS CI/CD Stack

```
Source        Build        Test         Deploy
────────      ────────     ────────     ────────
CodeCommit    CodeBuild    CodeBuild    CodeDeploy
GitHub    ──► (compile, ──► (run   ──► (to EC2,
Bitbucket     test,         tests)     ECS, Lambda,
ECR           package)                 Beanstalk)
S3

Orchestrated by: CodePipeline (workflow engine)
```

### CodeBuild

```yaml
# buildspec.yml — at root of your repo
version: 0.2

phases:
  install:
    runtime-versions:
      python: 3.11
    commands:
      - pip install -r requirements.txt

  pre_build:
    commands:
      - echo Logging in to ECR...
      - aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_REGISTRY

  build:
    commands:
      - echo Building Docker image...
      - docker build -t $IMAGE_REPO:$CODEBUILD_RESOLVED_SOURCE_VERSION .
      - docker tag $IMAGE_REPO:$CODEBUILD_RESOLVED_SOURCE_VERSION $ECR_REGISTRY/$IMAGE_REPO:latest
      - pytest tests/ -v

  post_build:
    commands:
      - docker push $ECR_REGISTRY/$IMAGE_REPO:latest
      - printf '[{"name":"app","imageUri":"%s"}]' $ECR_REGISTRY/$IMAGE_REPO:latest > imagedefinitions.json

artifacts:
  files:
    - imagedefinitions.json  # passed to CodeDeploy for ECS blue/green
```

### CodeDeploy Deployment Types

```
In-place (EC2/on-prem):
  Stop app → deploy → restart app → health check
  Downtime if single instance
  Use with ASG: deploy to half, wait, deploy to other half (rolling)

Blue/Green (EC2, ECS, Lambda):
  Deploy to new environment → shift traffic → terminate old
  Zero downtime, instant rollback

Lambda deployment:
  Canary10Percent5Minutes:  10% to new for 5 min, then 90% shift
  Linear10PercentEvery1Minute: 10% more per minute over 10 minutes
  AllAtOnce: immediate 100% shift (fastest, highest risk)

ECS blue/green:
  Task set 1 (current) receives 100% traffic
  New task set deployed → health checked
  Traffic shifted (canary or linear)
  Old task set deleted after stabilisation period
```

### CodePipeline

```yaml
# pipeline.yml (via CloudFormation/Terraform)
Pipeline:
  Stages:
    - Name: Source
      Actions:
        - ActionTypeId: Category=Source, Provider=GitHub
          Configuration:
            Owner: myorg
            Repo: my-app
            Branch: main

    - Name: Build
      Actions:
        - ActionTypeId: Category=Build, Provider=CodeBuild
          Configuration:
            ProjectName: my-app-build
          InputArtifacts: [SourceOutput]
          OutputArtifacts: [BuildOutput]

    - Name: ApproveProduction
      Actions:
        - ActionTypeId: Category=Approval, Provider=Manual
          Configuration:
            NotificationArn: arn:aws:sns:...  # notify on-call engineer

    - Name: DeployProd
      Actions:
        - ActionTypeId: Category=Deploy, Provider=CodeDeployToECS
          Configuration:
            ApplicationName: my-app
            DeploymentGroupName: prod
          InputArtifacts: [BuildOutput]
```

---

## 8. Step Functions

### What Step Functions Does

```
Step Functions = serverless workflow orchestrator.
Coordinates multiple AWS services (Lambda, ECS, DynamoDB, SQS) into a state machine.

Without Step Functions:
  Lambda A finishes → code inside A triggers Lambda B
  B finishes → code triggers C
  Error in B → complex retry/compensation logic inside each Lambda
  Monitoring: scattered across individual Lambda logs

With Step Functions:
  Define workflow as a state machine (JSON/YAML)
  Step Functions calls each service, passes state between steps
  Built-in retry with exponential backoff
  Error handling: Catch blocks per state
  Visual workflow in AWS Console
  Audit trail: every state transition logged
```

### State Machine Types

```
Standard workflow:
  Duration: up to 1 year
  Execution: exactly-once
  Price: $0.025 per 1,000 state transitions
  Use: long-running, human approval, business processes, ML pipelines

Express workflow:
  Duration: up to 5 minutes
  Execution: at-least-once (can run twice!)
  Price: based on executions + duration (cheaper for high-volume)
  Use: IoT processing, real-time streaming, high-volume short tasks
```

### Example — ML Training Pipeline

```json
{
  "Comment": "ML model training pipeline",
  "StartAt": "DataValidation",
  "States": {
    "DataValidation": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:::function:validate-data",
      "Next": "TrainingJob",
      "Retry": [{
        "ErrorEquals": ["Lambda.ServiceException"],
        "IntervalSeconds": 2, "MaxAttempts": 3, "BackoffRate": 2
      }],
      "Catch": [{
        "ErrorEquals": ["ValidationError"],
        "Next": "NotifyFailure"
      }]
    },
    "TrainingJob": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sagemaker:createTrainingJob.sync",
      "Parameters": {
        "TrainingJobName.$": "$.jobName",
        "AlgorithmSpecification": {...},
        "InputDataConfig": {...}
      },
      "Next": "EvaluateModel"
    },
    "EvaluateModel": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:::function:evaluate-model",
      "Next": "AccuracyCheck"
    },
    "AccuracyCheck": {
      "Type": "Choice",
      "Choices": [{
        "Variable": "$.accuracy",
        "NumericGreaterThan": 0.90,
        "Next": "DeployModel"
      }],
      "Default": "NotifyLowAccuracy"
    },
    "DeployModel": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sagemaker:createEndpoint.sync",
      "End": true
    },
    "NotifyFailure": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "arn:aws:sns:::ml-alerts",
        "Message": "ML pipeline failed"
      },
      "End": true
    }
  }
}
```

---

## Quick Reference — What the Existing Guides Cover vs This File

| Service | aws_cloud_guide | aws_system_design | This file |
|---|---|---|---|
| VPC | Deep dive | Used in designs | — |
| IAM | Deep dive | — | — |
| EC2 | 1 line | 1 line | **Deep dive here** |
| EKS | Deep dive | Used in designs | — |
| Lambda | 1 line | Used in designs | **Deep dive here** |
| S3 | Good | — | — |
| ALB/NLB | Good | Used | — |
| RDS/Aurora | Good | Used | — |
| DynamoDB | 2 lines | Used | **Deep dive here** |
| ElastiCache | 2 lines | Used | — |
| SQS/SNS | 1 line | Used | — |
| CloudWatch | Good | — | — |
| Secrets Manager | 1 line | — | **Deep dive here** |
| KMS | Missing | — | **Deep dive here** |
| ECR | Missing | — | **Deep dive here** |
| CodePipeline/Build | Missing | — | **Deep dive here** |
| Step Functions | Missing | — | **Deep dive here** |
