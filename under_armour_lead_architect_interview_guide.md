# Under Armour — Lead DevOps Architect Interview Guide

**Role:** Lead DevOps Architect - Cloud (AWS)
**Context:** E-commerce + retail, high-volume, peak trading (Black Friday scale)
**Reports to:** Under Armour Global Services Pvt. Ltd., India

---

## How to Frame Yourself for This Role

You are not applying as a hands-on engineer. You are applying as the person who:
- Owns the AWS platform architecture strategy
- Sets standards that 10s of engineers follow
- Protects revenue during peak retail events
- Bridges engineering, security, finance, and product

Your OpenShift/Kubernetes background is a direct match for EKS.
Your MLOps work shows you can run complex workloads on Kubernetes — not just web apps.
Lead with architecture decisions and their business impact, not tools.

---

## Section 1 — AWS Architecture for E-commerce

---

**Q: How would you design a highly available AWS architecture for an e-commerce platform that must sustain peak traffic on Black Friday?**

The architecture needs to be active-active across at least 2 AZs, with the ability to scale horizontally within minutes.

Core components:
- **CloudFront + WAF** at the edge — offloads static assets (product images, CSS, JS), protects against DDoS and bot traffic. Cache hit ratio >90% for product pages reduces origin load significantly
- **Route 53 with latency-based routing** — routes international customers to closest region
- **ALB** in front of EKS clusters — path-based routing separates product browsing traffic from checkout traffic. Checkout gets dedicated node groups with reserved capacity
- **EKS with Cluster Autoscaler + Karpenter** — Karpenter provisions nodes faster than CAS (30s vs 2-3 min). Pre-warm node pools 48 hours before peak events using scheduled scaling
- **Aurora Global Database** — primary in us-east-1, read replica in eu-west-1. Checkout writes go to primary, product catalog reads distributed across replicas. Aurora Serverless v2 for variable catalog traffic
- **ElastiCache (Redis)** — session state, cart contents, product catalog cache. Never hit the DB for catalog pages
- **SQS + Lambda** for order processing — decouples checkout from fulfillment. If downstream order management is slow, orders queue rather than failing

For peak events specifically:
- Load test at 3x expected peak, not 1x
- Pre-scale 30 minutes before event start — autoscaling reacts too slowly for a sudden spike
- Freeze deployments 48 hours before peak
- Have rollback runbooks ready with practiced DR drills

**Business impact framing:** Every 100ms of checkout latency costs measurable conversion rate. The architecture must treat latency as a revenue metric, not just an SLA.

---

**Q: Walk me through your approach to VPC design at an enterprise scale with multiple teams and environments.**

At enterprise scale, a single VPC per account is wrong. The right model is AWS Organizations with Control Tower.

Structure I'd implement:
```
Management Account (billing, governance only)
├── Security OU
│   └── Security Account (GuardDuty, SecurityHub, centralized logging)
├── Infrastructure OU
│   └── Network Account (Transit Gateway, shared VPCs, DNS)
├── Production OU
│   ├── Prod Account (e-commerce production)
│   └── Prod-DR Account (disaster recovery region)
└── Non-Production OU
    ├── Staging Account
    └── Dev Account
```

VPC CIDR planning:
- Use non-overlapping RFC 1918 ranges from the start — /16 per account
- Transit Gateway for cross-account connectivity, not VPC peering (peering doesn't scale beyond 10-15 connections)
- PrivateLink for cross-account service access instead of routing through TGW where possible

For e-commerce specifically:
- PCI scope must be isolated — checkout services in a dedicated subnet with strict SG rules
- Database tier in private subnets, no internet route ever
- Separate subnets for EKS nodes, RDS, and Lambda — different security posture per tier

---

**Q: How do you approach CloudFront and CDN strategy for a retail site?**

CloudFront sits at the edge and the configuration strategy depends on what you're caching vs what must be dynamic.

Cache policies by path:
- `/static/*` — long TTL (1 year), cache everything, busted via file hash in filename
- `/api/products/*` — 5 minute TTL, cache at edge, origin shield in front of EKS
- `/api/cart/*` and `/checkout/*` — no cache, always origin, pass cookies
- `/` and category pages — short TTL (60s), cached at edge, invalidated on content change

Origin Shield:
- Single region consolidation point between CloudFront PoPs and your origin
- Reduces origin load by 80%+ during traffic spikes
- Critical for Black Friday — without it, CloudFront PoPs each independently hammer your ALB

WAF rules:
- AWS managed rules for OWASP Top 10
- Rate limiting per IP on `/login` and `/checkout` to prevent credential stuffing
- Geo-blocking for regions you don't sell in (reduces bot traffic significantly)
- Signal Sciences or Fastly for advanced bot management if budget allows

---

## Section 2 — Kubernetes / EKS at Scale

---

**Q: How do you design EKS clusters for a production e-commerce environment?**

I don't run one big cluster — I run purpose-built clusters or at minimum purpose-built node groups.

Cluster topology for e-commerce:
- **Frontend cluster** — product browsing, search, content delivery. Can tolerate brief disruption
- **Transactional cluster** — cart, checkout, order management. Zero tolerance for disruption. Separate from frontend so a deployment issue in search doesn't affect checkout
- Or alternatively: single cluster with strict namespace isolation and dedicated node groups per workload class using node affinity and taints

Node group strategy:
- On-demand nodes for critical workloads (checkout, auth) — never Spot for these
- Spot instances with mixed instance types for stateless catalog services — 70-80% cost saving
- GPU node group for ML inference (recommendations, fraud detection) — separate from compute

EKS add-ons I always configure:
- **Karpenter** over Cluster Autoscaler — faster, more flexible, supports consolidation
- **VPC CNI** with prefix delegation — more IPs per node, important at scale
- **ALB controller** — native AWS integration for ingress
- **External Secrets Operator** — pulls secrets from Secrets Manager / Vault into pods
- **Kube-state-metrics + metrics-server** — foundation for HPA and observability

Upgrade strategy:
- Managed node groups make rolling upgrades safer
- Blue/green cluster upgrade for major version changes (1.27 → 1.28)
- Test upgrade in staging first, have rollback plan
- Never upgrade within 72 hours of a peak trading event

---

**Q: How do you handle secrets management in Kubernetes at scale?**

Never store secrets in Kubernetes Secrets directly — they're base64 encoded, not encrypted, and synced to etcd.

The right pattern:
- **HashiCorp Vault** or **AWS Secrets Manager** as the source of truth
- **External Secrets Operator** in Kubernetes syncs secrets from Vault/ASM into real K8s Secrets at runtime
- Pods consume K8s Secrets as env vars or mounted files — no application code change needed
- Secrets rotation happens in Vault/ASM, ESO resyncs automatically

With Vault specifically:
- Vault runs outside the cluster (not in it — avoids circular dependency)
- Kubernetes auth method — pods authenticate using their ServiceAccount token
- Dynamic secrets for database credentials — each pod gets a unique short-lived DB credential, revoked when pod terminates
- This is the gold standard for PCI compliance — no static DB passwords anywhere

For CI/CD:
- GitHub Actions uses Vault with OIDC auth — no stored API keys in GitHub Secrets
- Pipeline gets a short-lived Vault token, fetches what it needs, token expires

---

**Q: Describe how you would implement progressive delivery in a retail context.**

Progressive delivery = deploy to a small percentage of traffic first, validate, then expand.

Tools: Argo Rollouts (my preference) or Flagger.

Canary deployment for checkout service:
1. Deploy new version as canary — 5% of traffic
2. Monitor: error rate, P99 latency, checkout completion rate
3. Automatic promotion if metrics stay within thresholds for 10 minutes
4. Automatic rollback if error rate exceeds baseline by >1%
5. Full rollout after 30 minutes at 100%

For e-commerce specifically:
- Never run a canary during peak hours — do it at 2am
- Checkout completion rate is the business metric to track, not just HTTP errors
- A deployment that causes a 0.5% drop in checkout conversion on £10M/day revenue = £50,000/hour problem

Feature flags (LaunchDarkly or AWS AppConfig):
- Separate deployment from release — code ships dark, feature turned on when ready
- Instant rollback without a deployment — just flip the flag
- Percentage rollouts per user segment — test new checkout flow on 10% of UK users first

---

## Section 3 — Terraform / IaC at Enterprise Scale

---

**Q: How do you structure Terraform at an enterprise level with multiple teams and accounts?**

The wrong approach: one monolithic Terraform repo where everyone fights over state.

What I implement:

**Repository structure:**
```
terraform-platform/        ← shared modules (VPC, EKS, RDS patterns)
terraform-accounts/        ← per-account root modules
  ├── prod/
  ├── staging/
  └── dev/
terraform-services/        ← per-team service infrastructure
  ├── team-checkout/
  └── team-catalog/
```

**State management:**
- S3 backend with DynamoDB locking, one state file per environment per team
- State files never shared across teams — blast radius isolation
- State locking prevents concurrent applies
- Remote state data sources for cross-team references (e.g., checkout team reads VPC outputs from platform team)

**Module design principles:**
- Modules are versioned and published to Terraform Registry or private registry
- Teams consume modules like dependencies — `module "vpc" { source = "git::...?ref=v2.3.0" }`
- Breaking changes bump major version — teams opt in on their own timeline
- No inline module calls in root modules — everything is composable

**Governance:**
- Atlantis or Terraform Cloud for plan/apply with GitHub PR integration
- `terraform plan` output posted as PR comment — reviewable by anyone
- Branch protection: no direct apply to prod without PR approval from platform team
- Sentinel policies (Terraform Enterprise) or OPA policies for guardrails — can't create public S3 buckets, must have specific tags, etc.

---

**Q: How do you manage Terraform state for a large organization without it becoming a bottleneck?**

State granularity is the key decision. Too coarse = slow plans and high blast radius. Too fine = dependency hell.

Rules I follow:
- Network/VPC layer: separate state — changes rarely, shared by everyone
- EKS cluster: separate state per cluster
- Application services: state per team per environment
- Never put DNS, networking, and compute in the same state file

For speed:
- `-target` is a last resort, not a workflow — it creates drift
- `-refresh=false` for large plans where state is known good — faster
- Use `moved` blocks when refactoring instead of destroy/recreate

For safety:
- `prevent_destroy = true` on RDS, S3 buckets with data, EKS clusters
- State file backups enabled with versioning on S3
- If state is corrupted: `terraform state pull > backup.tfstate`, fix, `terraform state push`

---

## Section 4 — Security / PCI-DSS

---

**Q: How do you approach PCI-DSS compliance in an AWS environment?**

PCI-DSS scope reduction is the primary goal — get as little of your infrastructure in scope as possible.

Scope isolation:
- Cardholder data environment (CDE) in a dedicated AWS account
- CDE VPC isolated — no peering to non-CDE VPCs, only approved flows via security groups
- Use a payment gateway (Stripe, Braintree) — they take on PCI scope, you never touch raw card data
- If you must handle PANs: tokenization immediately on receipt, store only tokens

Technical controls:
- All data at rest encrypted (KMS customer-managed keys, not AWS-managed)
- All data in transit TLS 1.2+, TLS 1.0/1.1 disabled
- Database access via IAM authentication + Vault dynamic credentials — no static passwords
- Network segmentation: WAF → ALB → application tier → database tier, strict SG rules
- Immutable infrastructure — no SSH to production, all changes via CI/CD
- CloudTrail + AWS Config for audit trail — every API call logged
- GuardDuty for threat detection, SecurityHub for compliance posture

Vulnerability management:
- Amazon Inspector on all EC2 and container images
- Container image scanning in CI pipeline — block deployment if critical CVEs
- Patch cycle: OS patches within 30 days, critical security patches within 48 hours

For SOC 2 Type 2:
- Evidence collection automated via AWS Config rules
- Access reviews via IAM Access Analyzer quarterly

---

**Q: Describe your approach to IAM least privilege at scale.**

Least privilege IAM is easy to say and hard to implement at scale because permissions sprawl over time.

What I implement:
- **Permission boundaries** on all roles created by teams — they can create roles but can't exceed the boundary
- **Service Control Policies** at the OU level in Control Tower — hard ceiling on what any account can do
- **IAM Access Analyzer** to identify resources accessible from outside the account and unused permissions
- No human users with long-lived access keys — everyone uses SSO via IAM Identity Center
- Break-glass accounts for emergency access — time-limited, session recorded, requires 2-person authorization

For EKS specifically:
- IRSA (IAM Roles for Service Accounts) — pods get exactly the IAM permissions they need, nothing from the node role
- Node instance profile has minimal permissions — just ECR pull and SSM agent
- Namespace-level RBAC in Kubernetes mapped to IAM roles

Drift detection:
- AWS Config rule: detect when IAM policies are modified outside Terraform
- Alert on AdministratorAccess policy attachment
- Quarterly review of unused roles/users via Access Analyzer

---

## Section 5 — Observability + SRE

---

**Q: How do you define and implement SLOs for an e-commerce platform?**

SLOs start with what the customer experiences, not what's technically convenient to measure.

For a retail platform I'd define:

| Service | SLI | SLO |
|---|---|---|
| Homepage | Page load P75 < 2s | 99.5% of requests |
| Product search | Result returned < 500ms P95 | 99.9% of requests |
| Add to cart | API success rate | 99.95% |
| Checkout | Transaction success rate | 99.99% |
| Order confirmation | Email delivered < 5 min | 99.5% |

Error budgets:
- 99.9% SLO = 43 minutes downtime per month error budget
- Track burn rate — if burning at 2x the normal rate, alert and freeze deployments
- Error budget policy: when budget is <20%, no new feature deployments until budget recovers

Tooling:
- Datadog SLO dashboards — executive-visible, shows remaining budget
- Prometheus/Thanos for internal metrics, Grafana for engineering dashboards
- Distributed tracing with Datadog APM or OpenTelemetry → Jaeger for cross-service latency

What I present to executives:
- Not "99.97% uptime" — "We had 13 minutes of degraded checkout performance this month, costing an estimated £X in lost orders"
- Ties reliability to revenue — executives understand this language

---

**Q: How do you instrument a Kubernetes-based platform for full observability?**

Three pillars: metrics, logs, traces. Plus one more: events.

**Metrics:**
- `kube-state-metrics` + `metrics-server` in every cluster
- Application metrics via Prometheus client libraries or OpenTelemetry SDK
- Scrape via Prometheus, long-term storage in Thanos or Datadog
- Node-level metrics via Datadog agent DaemonSet

**Logs:**
- Structured JSON logs from all applications
- Fluent Bit DaemonSet → CloudWatch Logs or Datadog
- Never log PII or card data — log correlation IDs only, look up details in secure store
- Log retention: 90 days hot, 1 year cold (S3 Glacier) for compliance

**Traces:**
- OpenTelemetry SDK in applications — vendor-neutral
- Collector sidecar or DaemonSet aggregates and forwards
- 100% sampling for errors, 1-5% sampling for healthy requests
- Trace context propagated through SQS messages for async flows

**Kubernetes events:**
- Events are ephemeral by default (1 hour) — pipe them to a persistent store
- Alert on: OOMKilled, CrashLoopBackoff, pod evictions, node pressure

**Alerting philosophy:**
- Alert on symptoms (high error rate, slow checkout) not causes (high CPU)
- PagerDuty for P1/P2, Slack for everything else
- Every alert must have a runbook — if there's no runbook, the alert shouldn't exist

---

## Section 6 — HashiCorp Vault

---

**Q: How do you architect HashiCorp Vault for an enterprise?**

Vault runs in HA mode — never single instance in production.

Architecture:
- 3-node Vault cluster with Raft integrated storage (no separate Consul for storage since Vault 1.4)
- Auto-unseal via AWS KMS — vault comes back up after restart without manual intervention
- Deployed on EC2 or EKS (I prefer EC2 for Vault — simpler blast radius, not dependent on K8s)
- Load balancer in front, pods connect to LB address

Auth methods by consumer:
- **Kubernetes auth** — EKS pods authenticate via ServiceAccount JWT, get role-specific policies
- **AWS IAM auth** — Lambda, EC2 instances, GitHub Actions via OIDC
- **LDAP/SSO** — human operators

Secret engines in use:
- **KV v2** for static secrets with versioning
- **Database secrets engine** — dynamic credentials for RDS/Aurora, 1-hour TTL
- **PKI secrets engine** — internal certificate authority for mTLS between services
- **AWS secrets engine** — dynamic IAM credentials for short-lived AWS access

Policies follow principle of least privilege:
```hcl
# checkout service policy
path "secret/data/checkout/*" { capabilities = ["read"] }
path "database/creds/checkout-role" { capabilities = ["read"] }
# nothing else
```

Operations:
- Vault audit log to CloudWatch — every secret access is logged
- Vault agent sidecar in Kubernetes — caches and renews leases without app code changes
- Break-glass procedure: root token in sealed envelope in physical safe, never used in normal operations

---

## Section 7 — Leadership + Architecture at Scale

---

**Q: How do you drive architectural standards across engineering teams who resist change?**

Mandates don't work at scale — engineers route around them.

What works:
1. **Make the right way the easy way** — if the golden path (approved module, standard template) is easier than rolling your own, teams use it naturally
2. **Paved road not guardrails** — publish opinionated, working templates. Not a policy document, but actual working Terraform + GitHub Actions workflow they can copy
3. **Show the cost of deviation** — when a team's non-standard S3 config causes a security finding, the incident review makes the case better than any architecture deck
4. **Architecture review process** — lightweight, not a gate. New designs get reviewed early when they're cheap to change, not before go-live when they're expensive to change
5. **Champions in each team** — identify the influential engineer in each team, bring them in early. They carry the message better than a central architect can

Specifically for transitioning legacy systems:
- Strangler fig pattern — new cloud-native capability runs alongside legacy, traffic migrates incrementally
- Don't try to re-architect everything at once — pick the highest-risk or highest-cost component first

---

**Q: How do you approach disaster recovery for a retail platform?**

DR in retail has one job: protect revenue during peak events.

I define three tiers:
- **RTO 4 hours, RPO 1 hour** — non-customer-facing systems (reporting, internal tools)
- **RTO 30 minutes, RPO 5 minutes** — product catalog, browsing
- **RTO 5 minutes, RPO 30 seconds** — checkout, payment, order management

Multi-region strategy:
- Active-active in 2 regions (us-east-1 + eu-west-1) for global retailers
- Route 53 health checks + failover routing — automatic DNS failover in 60-120 seconds
- Aurora Global Database replication lag <1 second — acceptable RPO
- DynamoDB Global Tables for session state — multi-region active-active

What I test:
- Chaos engineering with AWS Fault Injection Simulator — randomly terminate EKS nodes, inject latency into database calls
- Full regional failover drill twice a year, not a theoretical exercise
- Game days before peak events — simulate 2x peak load with one AZ disabled

The uncomfortable truth about DR: most teams write DR runbooks but never test them. A runbook that hasn't been tested in 6 months is not a DR plan — it's a document.

---

## Section 8 — FinOps / Cost Optimization

---

**Q: How do you manage cloud costs at scale for a retail platform?**

Retail has highly variable traffic — the spend profile should match.

Immediate wins:
- Right-size over-provisioned EC2 and RDS instances using Compute Optimizer recommendations
- Purchase Savings Plans (not Reserved Instances) for predictable baseline compute — 30-40% saving
- Spot instances for batch processing, non-critical services — 70% saving vs on-demand
- S3 Intelligent Tiering for large object stores where access pattern is unpredictable

Architectural cost decisions:
- EKS bin packing with Karpenter consolidation — fewer, fuller nodes
- CloudFront cache hit ratio is a cost metric — every cache miss costs an origin request
- NAT Gateway data transfer is surprisingly expensive at scale — VPC endpoints for S3 and DynamoDB to bypass NAT

Governance:
- Tagging policy enforced via SCP — every resource must have Team, Environment, CostCenter tags
- Cost allocation reports per team in AWS Cost Explorer
- Monthly FinOps review with each team lead — show them their spend trend
- Budget alerts at 80% and 100% of monthly budget

Retail-specific:
- Scale down non-prod environments outside business hours — 40-50% saving on non-prod
- Pre-purchase Compute Savings Plans covering 70% of baseline before peak season

---

## Section 9 — Questions They Will Ask You

**Q: Why Under Armour specifically?**

Talk about:
- E-commerce at scale is the hardest infrastructure problem — seasonal spikes, global traffic, checkout reliability
- The architectural scope (Control Tower, multi-region, EKS at scale) matches what you want to build
- The visibility — reporting to India leadership with executive exposure means your architectural decisions matter at the business level

**Q: You have a background in OpenShift, not EKS. How does that translate?**

The Kubernetes control plane concepts are identical. What changes is the managed layer on top.
- OpenShift adds SCCs, OperatorHub, Maistra — EKS is leaner with more AWS-native integration
- I've operated Kubernetes at the operator/SRE level. EKS removes the control plane management burden — that's actually simpler, not harder
- AWS-native integrations (ALB controller, IRSA, Karpenter) are production-ready equivalents of what I've implemented in OpenShift

**Q: How would you approach the first 90 days in this role?**

- Days 1-30: Listen. Architecture reviews of current state, 1:1s with all engineering team leads, CISO, Head of Platform. Identify the top 3 pain points — don't implement anything yet
- Days 31-60: Propose — document current state gaps, proposed target architecture, prioritized roadmap. Present to engineering leadership, get alignment
- Days 61-90: Execute first quick win — one meaningful improvement that demonstrates value and builds credibility. Probably observability gaps or IaC governance

---

## Should You Stop Practising AI/MLOps?

**No. Here is why:**

This JD says: *"Evaluate and introduce new technologies and architectural patterns to advance platform maturity."*

Under Armour runs ML for:
- Product recommendations (you browse trainers, you get shown socks)
- Demand forecasting (how many units to stock by region)
- Fraud detection on payments
- Personalisation engine

All of that runs on Kubernetes. The person who owns the EKS platform also owns the infrastructure that runs ML workloads.

Your angle in the interview: **"I don't just run Kubernetes for web apps — I've built the infrastructure for AI/ML workloads on Kubernetes. GPU node groups, KServe, model serving, MLOps pipelines. That's increasingly where e-commerce differentiation happens."**

That is a differentiator vs a pure DevOps candidate who has never touched GPU workloads or ML serving.

**What to do:**
- For THIS interview: focus your preparation on AWS + EKS + Terraform + Security + SRE (the core JD)
- Don't stop AI/MLOps entirely — keep the knowledge fresh, it's your edge
- In the interview: mention it when asked about "new technologies" or "platform evolution" — not as your headline

The candidate who says "I run Kubernetes for microservices AND ML workloads" is stronger than the one who only knows one.
