# SRE Practices Interview Guide

**Target Role:** Principal Platform Engineer / SRE Lead  
**Background:** SLO/SLI definition at Voya, on-call for ML platform, audit automation (10 hrs → 10 min)

---

## 1. SLI / SLO / SLA

### Definitions

| Term | Definition | Owner | Example |
|------|-----------|-------|---------|
| **SLI** (Service Level Indicator) | The metric you measure | Engineering | p99 latency of `/predict` endpoint |
| **SLO** (Service Level Objective) | Your target for the SLI | Engineering | p99 latency < 200ms, 99.5% of time over 30 days |
| **SLA** (Service Level Agreement) | Contractual commitment to a customer | Business/Legal | 99.9% uptime; financial penalty if breached |

**Key insight**: SLO is always *stricter* than SLA. You need headroom between your internal target and the contractual commitment. If SLA is 99.9%, your SLO should be 99.95%.

### Good SLI Candidates (Request-Based Services)

```
Availability SLI = successful_requests / total_requests
Latency SLI    = requests_under_threshold / total_requests
Error rate SLI = 1 - (error_requests / total_requests)
Throughput SLI = requests_per_second >= minimum_threshold
```

**Bad SLI choices**: CPU usage, memory utilisation — these are symptoms, not user experience. A server can be at 95% CPU and still serve users fine. Use request success rate instead.

### Error Budget Formula

```
Error budget = 1 - SLO_target
Example: SLO = 99.5% availability over 30 days
  Error budget = 0.5% of 30 days = 0.005 × 30 × 24 × 60 = 216 minutes/month

If you've already had 180 minutes of downtime this month:
  Remaining error budget = 36 minutes (16% remaining)
  Action: slow down risky deployments, focus on reliability work
```

### Burn Rate Alerts

Don't alert on instantaneous error rate — alert on burn rate (how fast you're consuming budget).

```yaml
# Prometheus alert: 5% error budget consumed in 1 hour (too fast)
# This means: at this rate, budget is gone in 20 hours
- alert: HighErrorBudgetBurnRate
  expr: |
    (
      rate(http_requests_total{status=~"5.."}[1h])
      /
      rate(http_requests_total[1h])
    ) > (1 - 0.995) * 5   # 5x the error budget rate = fast burn
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Error budget burning at 5x rate — investigate immediately"
```

Google's multi-window burn rate: combine fast-burn (short window) and slow-burn (long window) alerts to catch both spikes and gradual degradation.

---

## 2. Error Budget Policy

### What to Do When Budget Is Exhausted

Write and enforce an **Error Budget Policy** — a document agreed between engineering and product:

```
If error budget > 50% remaining:
  → Normal deployment cadence. Feature releases proceed.

If error budget 25-50% remaining:
  → Feature releases continue. No risky infrastructure changes.
  → Reliability improvement items must be added to sprint.

If error budget < 25% remaining:
  → Slow down: only P0/P1 bug fixes deployed.
  → Engineering allocates 50% of sprint to reliability work.

If error budget exhausted (0%):
  → Feature freeze. No deployments except emergency fixes.
  → Full sprint dedicated to reliability work until budget recovers.
  → Post-mortem on what consumed the budget.
```

**This policy makes error budgets real**. Without the policy, the number is just a metric nobody acts on.

---

## 3. Toil Reduction

### What Is Toil?

Google's definition: manual, repetitive, automatable work that scales linearly with service growth. Unlike overhead (meetings, planning), toil produces no lasting value.

**Toil identification test**:
- Is it manual (human takes action)?
- Is it repetitive (same steps every time)?
- Is it automatable (a script could do it)?
- Does it scale with traffic (more servers = more work)?
- Does it produce no enduring value (same problem next week)?

### Toil vs Overhead vs Engineering Work

| Category | Example | Action |
|----------|---------|--------|
| Toil | Manual certificate rotation every 90 days | Automate with cert-manager + Vault |
| Overhead | Sprint planning, architecture reviews | Minimize, but can't eliminate |
| Engineering work | Building self-healing infra | Maximize — reduces future toil |

### Toil at Voya — Audit Automation

**Before**: Checking 250+ applications' pipeline configurations against standards = 10 hours/week of manual `grep` + spreadsheet work.

**After**: Python script + GitHub Actions + `oc get jobs -A -o json`:
1. GitHub API: list all repos, fetch `.github/workflows/` contents
2. OCP API: fetch all running Jobs + CronJobs
3. Compare: does each app have a required security scan workflow? Resource limits set? Probes configured?
4. Output: markdown report auto-posted to Confluence + Slack

Result: 10 hours → 10 minutes (99% reduction). Runs automatically every Monday.

This is the SRE answer to the interview question "give me an example of reducing toil."

---

## 4. Incident Management

### Severity Definitions

| SEV | Definition | Response Time | Example |
|-----|-----------|---------------|---------|
| SEV1 | Complete outage / data loss risk | Immediate (< 5 min) | Production cluster down, all inference failing |
| SEV2 | Significant degradation, workaround available | 15 min | p99 latency 10x normal, partial failures |
| SEV3 | Minor degradation, limited impact | 1 hour | Single feature broken, affects < 5% users |
| SEV4 | Cosmetic issue / no user impact | Next sprint | Dashboard widget wrong, docs outdated |

### Incident Response Flow

```
1. Alert fires → on-call acknowledges (SLA: within 5 minutes for SEV1)
2. Create incident channel (#incident-2025-01-15-inference-latency)
3. Assign roles:
   - Incident Commander (IC): coordinates, owns communication
   - Technical Lead: drives investigation
   - Comms Lead: stakeholder updates every 30 minutes
4. Declare SEV level → page appropriate teams
5. Investigate (see below)
6. Mitigate (stop the bleeding — rollback, scale, reroute traffic)
7. Resolve (fix root cause or confirm workaround stable)
8. Communicate resolution
9. Schedule post-mortem (within 48 hours for SEV1/SEV2)
```

### Investigation Loop (the "5 Whys")

```
Symptom: /predict endpoint p99 > 5s (SLO = 200ms)
Why 1: GPU inference pods are saturated (queue depth > 50 requests)
Why 2: Pod count is still 2 (KEDA should have scaled to 10)
Why 3: KEDA ScaledObject is failing — Prometheus query returning no data
Why 4: Prometheus pod restarted 2 hours ago and lost scraped data
Why 5: Prometheus PVC was full (no retention policy configured)
Root cause: Prometheus disk full → metrics gap → KEDA couldn't scale → inference saturation
Fix: expand PVC, configure retention, restore KEDA scaling
```

---

## 5. Post-Mortems

### Blameless Post-Mortem Structure

```markdown
# Post-Mortem: ML Inference Latency Spike — 2025-01-15

## Summary
Production inference endpoint experienced p99 latency of 8s (SLO: 200ms) for 47 minutes.
Error budget consumed: 150 minutes (69% of monthly budget).

## Timeline
- 14:23 Alert: inference-latency p99 firing
- 14:25 On-call acknowledged, created incident channel
- 14:31 KEDA ScaledObject identified as non-functional
- 14:48 Prometheus PVC expanded to 200Gi
- 14:55 Prometheus recovered, KEDA resumed scaling
- 15:10 Inference pods scaled to 10, latency returned to normal
- 15:10 Incident resolved

## Root Cause
Prometheus disk full → 2-hour metrics gap → KEDA could not evaluate scaling trigger.

## Contributing Factors
- No disk usage alert on Prometheus PVC
- No minimum replica count on inference Deployment (scaled to 0 during low traffic)
- KEDA failure mode: scale-to-zero instead of maintain minimum

## What Went Well
- Detection was fast (alert fired within 3 minutes of SLO breach)
- Clear escalation chain, IC took ownership immediately

## Action Items
| Action | Owner | Due | Priority |
|--------|-------|-----|----------|
| Add Prometheus PVC usage alert (>80%) | Sundeep | 2025-01-17 | P1 |
| Set minReplicaCount=2 on all inference ScaledObjects | Sundeep | 2025-01-17 | P1 |
| Configure Prometheus retention policy (30 days) | Sundeep | 2025-01-20 | P2 |
| Runbook for KEDA debugging | Team | 2025-01-24 | P3 |
```

**Blameless culture**: the post-mortem asks "what failed in the system?" not "who made the mistake?". The goal is action items that prevent recurrence, not punishing individuals.

---

## 6. On-Call Best Practices

### Rotation Design

```
Good on-call rotation:
✓ Maximum 1 week per rotation, then hand off
✓ Backup (secondary) on-call who can be paged if primary doesn't respond in 10 min
✓ Business hours escalation to team lead for SEV1
✓ Maximum 2 pages per shift (excessive paging = alert fatigue = missed real incidents)
✓ "You build it, you run it" — team that built the service is on-call for it

Bad on-call rotation:
✗ One person always on-call
✗ More than 5 pages per night on average
✗ Waking someone up for issues they can't fix (wrong escalation path)
```

### Runbook Quality Metrics

A runbook is only useful if it can be followed at 3am by someone who's half-asleep.

```
Good runbook:
1. Alert name + what it means in plain English
2. Triage steps (copy-pasteable commands, not "investigate the pod")
3. Common causes with specific fixes
4. Escalation path if runbook doesn't resolve
5. Rollback procedure

Example runbook entry:
  Alert: InferenceEndpointHighLatency
  Meaning: p99 latency > 500ms for more than 5 minutes (SLO breach in progress)
  
  Step 1: Check pod count
    oc get pods -n ml-platform -l app=inference-server
    Expected: 3-10 pods. If < 3: check KEDA ScaledObject (see step 2)
  
  Step 2: Check KEDA scaling
    oc get scaledobject inference-scaler -n ml-platform
    oc describe scaledobject inference-scaler -n ml-platform | grep -A5 Conditions
    If KEDA is failing: restart KEDA operator (see step 3)
  ...
```

**Metric**: time-to-resolve for P1 incidents decreases when runbooks are high quality. If MTTR is > 30 min for recurring incidents, the runbook needs improvement.

---

## 7. Availability Engineering

### Nines Reference Table

| Availability | Downtime per Year | Downtime per Month | Downtime per Week |
|-------------|------------------|--------------------|-------------------|
| 99% (two nines) | 87.6 hours | 7.3 hours | 1.7 hours |
| 99.9% (three nines) | 8.76 hours | 43.8 minutes | 10.1 minutes |
| 99.95% | 4.38 hours | 21.9 minutes | 5 minutes |
| 99.99% (four nines) | 52.6 minutes | 4.4 minutes | 1 minute |
| 99.999% (five nines) | 5.26 minutes | 26 seconds | 6 seconds |

**Key insight for interviews**: Five nines requires < 5 minutes downtime per year. Any manual intervention (SSH + restart) takes longer than that. Five nines requires automated self-healing, not humans.

### Availability Depends on the Weakest Link

```
Service availability = product of all dependencies' availability

Example: inference service depends on:
  - Kubernetes cluster API: 99.99%
  - ODF storage: 99.9%
  - Prometheus (for KEDA): 99.9%
  - Model registry (MLflow): 99.5%

Composite: 0.9999 × 0.999 × 0.999 × 0.995 = 99.27%

Even though every component targets 99.9%+, the composite is only 99.27%.
This is why redundancy, circuit breakers, and graceful degradation matter.
```

### Redundancy Patterns for Platform Engineering

```
Stateless services: Run ≥ 2 replicas across ≥ 2 nodes (AntiAffinity).
  → Tolerates 1 node failure without downtime.

Databases: Primary + 2 replicas (for quorum). WAL archiving for PITR.
  → Tolerate 1 replica failure; auto-failover within 30 seconds.

etcd (OCP control plane): 3 nodes minimum (quorum = 2/3).
  → Never run 2 etcd nodes — losing 1 loses quorum.

Cross-zone: spread replicas across 3 AZs (Azure Availability Zones).
  → Tolerate AZ failure (entire datacenter).
```

---

## 8. Capacity Planning

### When to Scale Before You Need To

```
Rule of thumb: maintain 30-40% headroom at peak load.
If p95 CPU across all inference pods = 70%, you're near the limit.
Scale before hitting 70% to avoid latency spikes during sudden traffic bursts.
```

### Kubernetes Capacity Planning Workflow

```bash
# 1. Understand current utilisation
kubectl top nodes                   # node-level CPU/memory
kubectl top pods -n ml-platform     # pod-level

# 2. Check resource requests vs limits
oc describe nodes | grep -A3 "Allocated resources"

# 3. Simulate load — k6 or locust
k6 run --vus 100 --duration 5m inference_test.js
# → Find: what RPS can 1 pod handle before p99 > 200ms?
# → Use this to size HPA targets

# 4. Set HPA based on measured data
kubectl autoscale deployment inference-server \
  --cpu-percent=60 --min=2 --max=20
```

### Node Capacity Formula

```
Effective pods per node = (node_allocatable_CPU / pod_request_CPU) × safety_factor
Example: 8 vCPU node, Kubernetes overhead ~500m, safety 0.7:
  Allocatable = 7.5 vCPU
  Pod request = 500m (0.5 vCPU)
  Effective pods = (7500m / 500m) × 0.7 = 10.5 → plan for 10 pods per node
```

---

## 9. Chaos Engineering

### LitmusChaos on Kubernetes

LitmusChaos provides CRDs for defining and running chaos experiments:

```yaml
# Kill a random inference pod (pod failure chaos)
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: inference-pod-failure
  namespace: ml-platform
spec:
  appinfo:
    appns: ml-platform
    applabel: app=inference-server
    appkind: deployment
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "60"       # Kill pods for 60 seconds
            - name: CHAOS_INTERVAL
              value: "10"       # Kill one pod every 10 seconds
            - name: FORCE
              value: "false"    # Graceful termination
```

**Blast radius control**: always run chaos experiments on a single replica first, with a circuit breaker (if latency > 2x SLO, abort experiment). Never run in production without a rollback plan.

```bash
# Monitor SLO during experiment
watch 'kubectl top pods -n ml-platform && oc get hpa -n ml-platform'
```

**Learnings from chaos**: often reveals that PodDisruptionBudgets are wrong (allowing 0 replicas when budget should be `maxUnavailable=1`), or that readiness probes are too slow (pod removed from LB before a new one is ready).

---

## 10. SRE at Platform Level

### Platform SLOs

Platform engineering teams often forget to define their own SLOs. A platform that doesn't have SLOs can't be held accountable.

Example platform SLOs (Voya style):
```
Cluster API availability: 99.95% (< 22 min downtime/month)
  SLI: kube-apiserver health endpoint success rate

Build pipeline (GitHub ARC) success rate: 95% (5% can fail for legitimate reasons)
  SLI: workflow_run_completed{conclusion="success"} / workflow_run_completed

ODF storage provisioning latency: 95% of PVCs bound within 30 seconds
  SLI: time_from_pvc_created to pvc_bound < 30s

ArgoCD sync success rate: 99% of syncs succeed within 5 minutes
  SLI: argocd_app_sync_total{phase="Succeeded"} / argocd_app_sync_total
```

### etcd Backup Testing (OCP)

```bash
# Take etcd snapshot (run on an etcd pod)
oc exec -n openshift-etcd etcd-master-0 -- \
  /usr/bin/etcdctl snapshot save /tmp/etcd-backup.db \
  --endpoints=https://localhost:2379 \
  --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt \
  --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-serving-master-0.crt \
  --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-serving-master-0.key

# Verify snapshot integrity
etcdctl snapshot status /tmp/etcd-backup.db

# Test restore quarterly (on a test cluster, not production)
# Restore = etcdctl snapshot restore → restart all etcd pods
```

---

## 11. Scenario-Based Interview Questions

**Q: Your error budget is exhausted mid-month. Product wants to deploy a new feature. What do you do?**

1. First, enforce the Error Budget Policy — no new feature deployments when budget is at zero.
2. Explain to product: "We've used 100% of our 216-minute allowance for the month. Any further incidents breach our SLA commitment. New deployments increase incident risk."
3. Immediate actions:
   - Freeze feature deployments (only critical security patches allowed).
   - Redirect the team's sprint: allocate 100% to reliability work (fixing the incidents that consumed budget).
4. Investigate the root causes: what consumed the budget? Were the incidents expected or preventable?
5. Run a sprint focused on: better runbooks, adding missing alerts, fixing the root cause, improving recovery time.
6. When budget recovers (start of next month): resume normal cadence with new safeguards in place.

Escalate to engineering manager: the budget exhaustion is a signal that reliability work is being underprioritised. This conversation needs to happen at the leadership level.

**Q: PagerDuty wakes you at 3am: inference endpoint p99 latency is 8s. SLO is 200ms. Walk through your response.**

1. **Acknowledge** (< 5 min). Create incident channel: `#incident-2025-01-15-inference-latency`.
2. **Assess scope**: 
   ```bash
   oc get pods -n ml-platform          # Are pods running?
   oc top pods -n ml-platform          # CPU/memory saturation?
   oc get hpa -n ml-platform           # Is HPA/KEDA trying to scale?
   ```
3. **Quick wins**: If pods are saturated and not scaling: check KEDA trigger metrics, Prometheus health.
   If pods are crashing: `oc logs <pod> --previous` for crash reason.
4. **Stakeholder update** (15 min): "Investigating inference latency spike. Impact: production inference degraded. Cause under investigation."
5. **Mitigation before root cause**: if pods are healthy but overloaded → manually scale: `oc scale deployment inference-server --replicas=10`.
6. **Verify**: watch p99 latency recover in Dynatrace/Prometheus dashboard.
7. **Document**: capture timeline in incident channel. Signal "resolved" when SLO is restored.
8. **Schedule post-mortem within 48 hours**.

**Q: How did you reduce audit effort from 10 hours to 10 minutes at Voya?**

Context: I was responsible for weekly platform audits — verifying that all 250+ applications across the OCP cluster met security and operational standards (resource limits, probes, pipeline scan workflows, RBAC).

The manual process took 10 hours: SSH to bastion, run `oc get` commands, cross-reference with a spreadsheet, check GitHub repos for workflow files, produce a report for the security team.

Automation approach:
1. Identified all audit checks as programmatic queries: `oc get pods -A -o json` → check for containers without resource limits; GitHub API → list repos and check for `security-scan.yml` in `.github/workflows/`.
2. Wrote a Python script that:
   - Authenticates to OCP via a service account token (stored in Vault)
   - Queries GitHub API for all org repos and their workflow files
   - Produces a structured findings dict
   - Renders a markdown report and posts it to Confluence via API
3. Packaged as a GitHub Actions workflow (runs every Monday 9am), outputs to a dedicated Confluence page.
4. Added a Slack notification with a summary: "15 apps missing resource limits (see report)."

Result: 10 hours → 10 minutes for the humans (review the report, not generate it). Runs automatically without any manual trigger.

**Q: How do you design an SLO for an ML model serving endpoint (like KServe inference)?**

An ML serving endpoint has different failure modes than a typical web service, so SLO design needs to account for them.

Recommended SLIs:
1. **Availability**: `successful_predictions / total_predictions` (HTTP 200 / total requests). Target: 99.5%.
2. **TTFT (Time to First Token)**: for streaming inference, time from request receipt to first token returned. Target: p95 < 500ms.
3. **TPOT (Time Per Output Token)**: decode latency. Target: p95 < 50ms/token.
4. **Queue depth**: number of pending requests waiting for GPU. Target: never > 50 for more than 2 minutes.

Error budget:
- 99.5% availability = 3.6 hours/month budget.
- Deployments count against budget: a bad rollout that causes 20 minutes downtime = 9% of budget consumed.

Alert hierarchy:
1. Fast-burn: 5x burn rate for 1 hour → SEV2 page.
2. Slow-burn: 2x burn rate for 6 hours → SEV3 Slack alert.
3. Budget < 25%: Slack notification to team lead → reliability sprint triggered.

**Q: How do you handle on-call for a platform that supports 250+ applications?**

With 250+ applications, you can't be expert on every one. The platform SRE is on-call for the platform layer, not the applications.

Escalation model:
```
App-level alert (e.g., "my Java app is OOMKilling")
  → App team on-call responds first

Platform-level alert (e.g., "ODF cluster HEALTH_WARN", "etcd leader election")
  → Platform SRE responds

If unclear which layer:
  → Platform SRE triages. If it's in the app, hands off to app team with findings.
```

To make this work:
1. Clear ownership: every namespace/application has a team label. `oc label namespace my-app support-team=payments`.
2. Good runbooks: platform SRE can do initial triage on app issues even without deep context.
3. Observability: Dynatrace topology + problem cards often point to the affected layer within 2 minutes.
4. PagerDuty routing: separate escalation policies for platform alerts vs application alerts.
