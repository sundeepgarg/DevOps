# AWS Cloud Services Interview Guide

**Target Role:** Senior/Principal Platform / DevOps / MLOps Engineer  
**Background:** Multi-cloud (Azure primary, AWS secondary), ACE Aviatrix certified, IaC with Terraform

---

## Architecture Overview

```
AWS Global Infrastructure:
┌─────────────────────────────────────────────────────────────────┐
│  Region (e.g., us-east-1)                                       │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Availability Zone A          Availability Zone B       │    │
│  │  ┌──────────────────┐        ┌──────────────────┐       │    │
│  │  │   VPC Subnet     │        │   VPC Subnet     │       │    │
│  │  │   (public/priv)  │        │   (public/priv)  │       │    │
│  │  │   EC2 / EKS      │        │   EC2 / EKS      │       │    │
│  │  └──────────────────┘        └──────────────────┘       │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  Global Services (region-independent):                          │
│  IAM, Route53, CloudFront, S3 (regional but global namespace)   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. VPC (Virtual Private Cloud)

### Core Networking Architecture

```
Internet
    │
Internet Gateway (IGW)
    │
┌───▼──────────────────────────────────────────────────────┐
│  VPC: 10.0.0.0/16                                        │
│                                                          │
│  ┌──────────────────────┐  ┌──────────────────────┐     │
│  │  Public Subnet       │  │  Private Subnet       │     │
│  │  10.0.1.0/24  AZ-A  │  │  10.0.3.0/24  AZ-A  │     │
│  │  ┌──────────────┐   │  │  ┌──────────────┐    │     │
│  │  │ ALB          │   │  │  │ EC2/EKS pods │    │     │
│  │  │ NAT Gateway  │   │  │  │ RDS          │    │     │
│  │  │ Bastion Host │   │  │  └──────────────┘    │     │
│  │  └──────────────┘   │  │          ▲           │     │
│  └──────────────────────┘  │          │ NAT GW    │     │
│                             └──────────────────────┘     │
│  Route Tables:                                           │
│    Public:  0.0.0.0/0 → IGW                             │
│    Private: 0.0.0.0/0 → NAT Gateway (for outbound only) │
└──────────────────────────────────────────────────────────┘
```

### Key Networking Components

| Component | Function | Analogy |
|-----------|----------|---------|
| VPC | Isolated virtual network | Your own data centre in AWS |
| Subnet | Sub-division of VPC across one AZ | Floor in a building |
| IGW | Bidirectional internet access | Front door |
| NAT Gateway | Outbound-only internet for private subnets | One-way mirror |
| Security Group | Stateful firewall per instance/ENI | Lock on a door |
| NACL | Stateless firewall per subnet | Guard at subnet entrance |
| Route Table | Where does traffic go? | Road signs |

### Security Group vs NACL

```
Security Group (SG):                    NACL:
  - Stateful: return traffic            - Stateless: must allow both
    auto-allowed                          directions explicitly
  - Allow rules only                    - Allow + Deny rules
  - Applied to ENI/instance             - Applied to subnet
  - All rules evaluated                 - Rules evaluated in order (lowest #)
  - Default: deny all inbound           - Default: allow all
    allow all outbound
```

```bash
# Create VPC + subnets with Terraform
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "platform-vpc" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "us-east-1a"
  tags = { Name = "private-subnet-a", Tier = "private" }
}
```

---

## 2. IAM (Identity and Access Management)

### IAM Flow

```
Principal (Who)        Action (What)          Resource (On What)
┌─────────────┐       ┌─────────────┐        ┌──────────────────┐
│ IAM User    │       │ s3:GetObject│        │ arn:aws:s3:::my- │
│ IAM Role    │──────►│ ec2:Describe│───────►│ bucket/*         │
│ IAM Group   │       │ sts:AssumeRole        │ arn:aws:ec2:...  │
│ AWS Service │       └─────────────┘        └──────────────────┘
└─────────────┘
        │ Policy attached: Allow/Deny?
        ▼
  Evaluation Result: ALLOW or implicit DENY
```

### Key IAM Concepts

```json
// IAM Policy (JSON)
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::ml-models-bucket/*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "us-east-1"
        }
      }
    }
  ]
}
```

### OIDC Federation for CI/CD (No Static Credentials)

```yaml
# GitHub Actions → AWS via OIDC (no AWS_SECRET_ACCESS_KEY needed)
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::123456789:role/github-actions-role
    aws-region: us-east-1
    # GitHub OIDC token automatically exchanged for AWS temporary credentials

# IAM Role Trust Policy (allows GitHub Actions to assume it)
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::123456789:oidc-provider/token.actions.githubusercontent.com"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:myorg/myrepo:*"
      }
    }
  }]
}
```

### Instance Profiles (EC2 / EKS Pod Identity)

```
EC2 Instance → Instance Profile → IAM Role → Policies
(no credentials stored on disk — metadata service provides temp tokens)

curl http://169.254.169.254/latest/meta-data/iam/security-credentials/my-role
# Returns: AccessKeyId, SecretAccessKey, Token (expire in ~1hr, auto-rotated)
```

---

## 3. EKS (Elastic Kubernetes Service)

### EKS Architecture

```
┌─────────────────────────────────────────────────────────┐
│  EKS Control Plane (AWS managed, multi-AZ)              │
│  ┌─────────────────────────────────────────────────┐    │
│  │  kube-apiserver  etcd  controller-manager       │    │
│  │  scheduler       cloud-controller-manager       │    │
│  └─────────────────────────────────────────────────┘    │
│                        │                                 │
│          AWS managed — you don't see these nodes         │
└────────────────────────┼─────────────────────────────────┘
                         │ kubelet connects to API server
┌────────────────────────▼─────────────────────────────────┐
│  Worker Node Group (your EC2 instances)                  │
│  ┌──────────────────┐   ┌──────────────────┐            │
│  │  Node (AZ-A)     │   │  Node (AZ-B)     │            │
│  │  kubelet, kube-  │   │  kubelet, kube-  │            │
│  │  proxy, VPC CNI  │   │  proxy, VPC CNI  │            │
│  │  [Pods...]       │   │  [Pods...]       │            │
│  └──────────────────┘   └──────────────────┘            │
└──────────────────────────────────────────────────────────┘
```

### EKS CNI — VPC Native Networking

```
VPC CNI gives each pod a real VPC IP address:
  Node CIDR:  10.0.1.0/24
  Pod IPs:    10.0.1.15, 10.0.1.16, 10.0.1.17 (from the same subnet)

vs Azure CNI Overlay (different IP space for pods)

Implication:
  - Pods are directly routable in the VPC
  - Security Groups can be applied directly to pods (SG for Pods feature)
  - Subnet size limits pod count: /24 = 256 IPs → ~250 pods per subnet
```

### IRSA (IAM Roles for Service Accounts)

```yaml
# Pod-level AWS permissions without node-level credentials
apiVersion: v1
kind: ServiceAccount
metadata:
  name: s3-reader
  namespace: ml-platform
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/s3-reader-role
---
# Pod uses this SA → gets AWS credentials scoped to s3-reader-role
spec:
  serviceAccountName: s3-reader
  # AWS SDK automatically picks up the IRSA token from projected volume
```

---

## 4. S3 (Simple Storage Service)

### S3 Architecture Concepts

```
S3 Bucket
├── Objects (key-value: key=path-like string, value=data)
├── Versioning (keep all versions, soft delete with delete markers)
├── Lifecycle policies (move to Glacier after 90 days)
├── Replication (CRR: cross-region, SRR: same-region)
├── Event notifications → Lambda/SQS/SNS on object PUT/DELETE
└── Access: IAM policies + Bucket policies + ACLs + Block Public Access

Storage Classes:
  Standard         → hot data, frequent access, $0.023/GB
  Standard-IA      → infrequent access, $0.0125/GB + retrieval fee
  Glacier Instant  → archive, millisecond retrieval, $0.004/GB
  Glacier Deep     → archive, 12hr retrieval, $0.00099/GB
  Intelligent-Tiering → auto moves between tiers based on access
```

```bash
# S3 operations
aws s3 cp model.pkl s3://ml-models/v3/model.pkl
aws s3 sync ./data/ s3://ml-data/raw/
aws s3 ls s3://ml-models/ --recursive --human-readable

# Presigned URL (give temporary access to a private object)
aws s3 presign s3://ml-models/v3/model.pkl --expires-in 3600
```

---

## 5. Load Balancers

```
ALB (Application Load Balancer) — Layer 7:
  HTTP/HTTPS/gRPC aware
  Path-based routing: /api/* → target group A, /static/* → target group B
  Host-based routing: api.example.com → group A, app.example.com → group B
  Sticky sessions, WAF integration, Lambda targets
  Use for: microservices, Kubernetes Ingress, APIs

NLB (Network Load Balancer) — Layer 4:
  TCP/UDP/TLS
  Preserves source IP
  Extreme performance: millions of RPS, ultra-low latency
  Static IP (Elastic IP assignable)
  Use for: gaming, IoT, Kubernetes LoadBalancer for non-HTTP

ALB + EKS:
  AWS Load Balancer Controller watches Ingress CRDs
  Creates ALB automatically with correct target groups
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip  # pod IPs directly
```

---

## 6. RDS and Database Services

```
RDS Multi-AZ Architecture:
┌──────────────────────────────────────────┐
│  Primary (AZ-A)      Standby (AZ-B)     │
│  ┌─────────────┐     ┌─────────────┐    │
│  │ RDS Primary │────►│ RDS Standby │    │
│  │ (read/write)│sync │ (no reads!) │    │
│  └──────┬──────┘     └──────┬──────┘    │
│         │                   │           │
│    DNS endpoint: auto-failover (60-120s) │
└──────────────────────────────────────────┘

RDS Read Replicas (up to 15):
  Async replication → eventual consistency
  Can be promoted to standalone (for DR)
  Used for: read-heavy workloads, reporting, ML training data

Aurora vs RDS:
  Aurora: distributed storage (6 copies across 3 AZs)
          failover < 30s, auto-scaling storage
          Aurora Serverless v2: scale to 0
  RDS:    traditional block storage, simpler, cheaper for small workloads
```

---

## 7. CloudWatch + Observability

```
AWS Observability Stack:
┌─────────────────────────────────────────────────────────┐
│                    CloudWatch                           │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────┐  │
│  │   Metrics    │  │    Logs      │  │   Alarms    │  │
│  │ EC2,EKS,RDS  │  │ App logs,    │  │ SNS notify  │  │
│  │ Custom metrics│  │ VPC Flow,   │  │ Auto Scaling│  │
│  │ from SDK     │  │ CloudTrail   │  │ trigger     │  │
│  └──────────────┘  └──────────────┘  └─────────────┘  │
│                                                         │
│  CloudWatch Container Insights → EKS pod metrics       │
│  CloudWatch Logs Insights → query log groups with SQL   │
└─────────────────────────────────────────────────────────┘

CloudTrail: WHO did WHAT to WHICH resource and WHEN
  All API calls logged → S3 bucket → query with Athena
  Required for compliance, audit, security investigation
```

---

## 8. Networking Deep Dive

### VPC Peering vs Transit Gateway

```
VPC Peering:
  VPC-A ←──peering──► VPC-B
  VPC-B ←──peering──► VPC-C
  VPC-A ✗ VPC-C (peering is NOT transitive)
  
  Pros: free data transfer within region, simple
  Cons: doesn't scale (N×(N-1)/2 peerings for N VPCs), no transitive routing

Transit Gateway:
  VPC-A ─────────────► TGW ◄──────────── VPC-B
  VPC-C ─────────────► TGW ◄──────────── On-Prem (via VPN/Direct Connect)
  
  All VPCs attached to TGW can communicate (transitive)
  TGW route tables control which VPCs can talk to which
  $0.05/GB data processed + $0.05/attachment-hour
  
  Use TGW when: > 5 VPCs, need on-prem connectivity, need segmentation
```

### Direct Connect vs Site-to-Site VPN

| Feature | Direct Connect | Site-to-Site VPN |
|---------|---------------|------------------|
| Connection | Dedicated physical circuit | IPsec over internet |
| Bandwidth | 1-100 Gbps | Up to 1.25 Gbps |
| Latency | Consistent, low | Variable (internet) |
| Cost | High ($250-$2000/month) | Low ($37/month) |
| Setup time | Weeks | Minutes |
| Use for | Production, high throughput | DR, quick POC, backup |

---

## 9. Scenario-Based Interview Questions

**Q: A pod in EKS can't reach an S3 bucket. How do you debug?**

1. Check if the pod has an IAM role attached via IRSA:
   ```bash
   kubectl describe sa <service-account> -n <namespace>
   # Look for: eks.amazonaws.com/role-arn annotation
   ```
2. Check the IAM role has S3 permissions:
   ```bash
   aws iam get-role-policy --role-name s3-reader-role --policy-name S3Access
   ```
3. Check the S3 bucket policy isn't denying the request. Explicit Deny overrides any Allow.
4. Check VPC endpoint: if using a private VPC with no internet access, you need an S3 VPC Endpoint (Gateway type — free). Without it, S3 traffic tries to go via internet → blocked.
5. Check the region: `s3:GetObject` on `us-east-1` bucket from a pod in `eu-west-1` may need cross-region permission and higher latency.

**Q: Your EKS cluster is running fine but pods are stuck in Pending. Nodes show available capacity. Why?**

Common causes:
1. **Taints without tolerations**: nodes have taints the pods don't tolerate.
   ```bash
   kubectl describe node <node> | grep Taints
   kubectl describe pod <pod> | grep -A5 Events
   ```
2. **Node selector mismatch**: pod requires `gpu=true` label, no node has it.
3. **Resource requests exceeding allocatable**: pod requests 4 CPUs, largest allocatable node has 3.5 (overhead reserved for system).
4. **PVC not bound**: pod depends on a PVC that's still `Pending` (EBS PVC in wrong AZ).
5. **Topology constraints**: `topologySpreadConstraints` with `whenUnsatisfiable: DoNotSchedule` — no AZ has room.

**Q: How do you design a highly available 3-tier application on AWS?**

```
Internet
    │
Route53 (DNS failover, health checks)
    │
CloudFront (CDN, WAF, DDoS protection, SSL termination)
    │
ALB (cross-AZ, health checks)
    │
┌───▼─────────────────────────────────┐
│  Auto Scaling Group (min=2, max=10) │
│  EC2/EKS across AZ-A + AZ-B        │
│  (Web/App tier)                     │
└───┬─────────────────────────────────┘
    │
    │ Private subnets only
    │
┌───▼─────────────────────────────────┐
│  RDS Aurora Multi-AZ                │
│  (Primary AZ-A + Replica AZ-B)      │
│  ElastiCache Redis (session, cache) │
└─────────────────────────────────────┘

Data: S3 (static assets, backups, logs)
Secrets: AWS Secrets Manager (rotated, audited)
Monitoring: CloudWatch + X-Ray (distributed tracing)
```

**Q: How do you reduce AWS costs without impacting production reliability?**

1. **Right-sizing**: use AWS Compute Optimizer recommendations. Identify over-provisioned EC2 instances.
2. **Savings Plans / Reserved Instances**: commit 1-3 years for predictable workloads (40-60% savings).
3. **Spot Instances**: for batch jobs, dev/test, stateless workers. 70-90% cheaper. Use Spot Interruption Advisor to pick stable instance types.
4. **S3 lifecycle policies**: move old model artifacts to Glacier (95% storage cost reduction).
5. **NAT Gateway**: large data transfer cost. Use VPC Endpoints (S3, DynamoDB — free gateway endpoints) to avoid NAT Gateway charges for these services.
6. **Data transfer**: same-AZ traffic is free. Cross-AZ costs $0.01/GB. Place RDS in same AZ as primary app tier.

**Q: What is the difference between IAM Role and IAM User? When do you use each?**

- **IAM User**: a person or application with long-term credentials (username + password + access keys). Access keys don't expire automatically. Risk: keys can be leaked.
- **IAM Role**: an identity with temporary credentials (15 min to 12 hrs). No long-term secrets. Assumed by EC2 instances, Lambda, EKS pods, other AWS accounts, CI/CD systems.

**Rule**: never create IAM users for applications. Always use roles. For human users: use AWS SSO (IAM Identity Center) with federated identity (Azure AD, Okta) — users assume roles, no permanent credentials.

For CI/CD (GitHub Actions, Jenkins): use OIDC federation → assume a role → short-lived credentials. Never store `AWS_ACCESS_KEY_ID` in CI secrets.

**Q: How does AWS Transit Gateway differ from Aviatrix?**

AWS TGW: AWS-native, manages routing between VPCs within AWS. No network visibility beyond AWS VPCs. No packet-level troubleshooting. Limited to AWS.

Aviatrix: multi-cloud. Manages routing between AWS VPCs + Azure VNets + GCP VPCs + on-prem. CoPilot provides FlightPath (packet trace), topology visualization, anomaly detection. Network Domains for segmentation.

At ACE level: use TGW when you're 100% AWS and don't need advanced visibility. Use Aviatrix for multi-cloud, compliance (encryption between all VPCs), or when your network team needs FlightPath for troubleshooting.
