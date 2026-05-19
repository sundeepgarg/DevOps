# Turing — Tradecraft Evaluation Platform: Interview Preparation Guide

**Role:** Senior DevOps / Platform Engineer (AI Evaluation Platform)  
**Experience Level:** 7–10 years  
**Project:** Deploy Turing's AI evaluation engine on Kubernetes; sole infrastructure owner  
**Background match:** Sundeep — 12 years OpenShift/Kubernetes, Terraform, CI/CD

This guide maps every JD responsibility to a concrete interview question with a senior-level answer.

---

## 1. Kubernetes — Namespace Isolation and Multi-Tenant Design

### Q1: The platform has Scenario Runner Workers, Metric Evaluator Workers, and an API Gateway — all sharing a cluster. How do you design namespace isolation so a runaway evaluation job cannot starve the API Gateway?

**Detailed Answer:**

I separate workloads into four namespaces: `api-gateway`, `eval-runners`, `metric-evaluators`, and `platform-infra` (Weaviate, PostgreSQL, Redis). Each namespace gets its own `ResourceQuota` and `LimitRange`.

```yaml
# ResourceQuota — hard ceiling per namespace
apiVersion: v1
kind: ResourceQuota
metadata:
  name: eval-runners-quota
  namespace: eval-runners
spec:
  hard:
    requests.cpu: "60"
    requests.memory: "240Gi"
    limits.cpu: "120"
    limits.memory: "480Gi"
    count/pods: "20"            # max 20 pods (HPA max is 15 workers + buffer)
    count/persistentvolumeclaims: "10"
```

```yaml
# LimitRange — sets default requests/limits for pods that forget to specify
apiVersion: v1
kind: LimitRange
metadata:
  name: eval-runners-limits
  namespace: eval-runners
spec:
  limits:
    - type: Container
      default:
        cpu: "2"
        memory: "4Gi"
      defaultRequest:
        cpu: "500m"
        memory: "1Gi"
      max:
        cpu: "8"
        memory: "32Gi"
```

Key design decisions:
- **API Gateway namespace gets priority class**: Create a `PriorityClass` (`system-cluster-critical` style) for API Gateway pods so they are never preempted by eval workers
- **Separate node pools per namespace** (if budget allows): API Gateway on general-purpose nodes, eval workers on compute-optimized nodes — enforced with `nodeSelector` + taints
- **NetworkPolicies deny cross-namespace traffic by default** (covered in Q4)

```yaml
# PriorityClass for API Gateway
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: api-gateway-high
value: 1000          # Eval workers get value: 100
globalDefault: false
```

---

### Q2: How do you configure RBAC for a team where the client's security team needs read-only visibility across all namespaces, while the Turing deployment pipeline needs write access only to specific namespaces?

**Detailed Answer:**

Two separate RBAC patterns: ClusterRole for read-only (client security) and namespace-scoped Roles for the CI/CD pipeline.

```yaml
# Client security team — read-only cluster-wide
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: security-readonly
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "events", "namespaces"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["networkpolicies", "ingresses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["secrets"]     # DENY secrets — security team has no reason to read values
    verbs: []

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: client-security-readonly
subjects:
  - kind: Group
    name: "client-security"   # Backed by OIDC group from client's IdP
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: security-readonly
  apiGroup: rbac.authorization.k8s.io
```

```yaml
# CI/CD pipeline — write access only to allowed namespaces
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer
  namespace: eval-runners        # Scoped to this namespace only
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "update", "patch"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "update", "patch"]
  # NO create/delete for pods, NO access to secrets (Vault handles that)
```

The CI/CD pipeline uses a dedicated `ServiceAccount` bound to this `Role` in each allowed namespace. It cannot touch `api-gateway` namespace.

**Key principle**: Least privilege. CI/CD gets `update`/`patch` on Deployments (rolling deploy), not `create`/`delete`. Secrets are never in CI/CD — HashiCorp Vault's agent injects them at pod startup.

---

## 2. HPA with Custom Metrics

### Q3: The JD specifies HPA for Scenario Runner Workers (3–15 instances) and Metric Evaluator Workers (2–10 instances) — but based on what metric? CPU is not the right signal for evaluation jobs. How do you design this?

**Detailed Answer:**

CPU-based HPA is wrong for evaluation pipeline components — a worker can be CPU-idle but have a full job queue. The correct scaling signal is **queue depth** (number of unprocessed evaluation jobs).

Architecture: **KEDA (Kubernetes Event-Driven Autoscaling)** with an SQS or Redis queue trigger.

```yaml
# KEDA ScaledObject for Scenario Runner Workers
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: scenario-runner-scaler
  namespace: eval-runners
spec:
  scaleTargetRef:
    name: scenario-runner-worker
  minReplicaCount: 3             # JD specifies 3 minimum
  maxReplicaCount: 15            # JD specifies 15 maximum
  cooldownPeriod: 120            # 2 min before scaling down (avoid thrashing)
  pollingInterval: 15            # Check queue every 15 seconds
  triggers:
    - type: aws-sqs-queue        # Or redis for Redis-backed queue
      metadata:
        queueURL: https://sqs.us-east-1.amazonaws.com/123456/eval-jobs
        targetQueueLength: "5"   # 1 worker per 5 queued jobs
        awsRegion: us-east-1
      authenticationRef:
        name: keda-sqs-auth      # IRSA / Workload Identity credentials

---
# KEDA TriggerAuthentication — uses IRSA (no static AWS credentials)
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-sqs-auth
  namespace: eval-runners
spec:
  podIdentity:
    provider: aws                # IRSA: KEDA uses EKS pod identity
```

For the **Metric Evaluator Workers**, the scaling signal is different — evaluation output queue depth (how many scored results are waiting to be written):

```yaml
# Metric Evaluator Workers (2-10)
triggers:
  - type: redis
    metadata:
      address: redis-master.platform-infra:6379
      listName: "metric-eval-queue"
      listLength: "3"            # 1 worker per 3 items in queue
```

**For API Gateway (2-6)**: HTTP request rate IS the right signal, so standard KEDA HTTP trigger or Prometheus-based HPA:
```yaml
triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus:9090
      metricName: http_requests_per_second
      query: rate(http_requests_total{namespace="api-gateway"}[1m])
      threshold: "100"           # Scale when > 100 RPS per replica
```

**Senior point**: Set `stabilizationWindowSeconds` on scale-down to prevent workers from terminating mid-job. Workers should be given a termination grace period (`terminationGracePeriodSeconds: 300`) and a `preStop` hook that drains the current job before the pod exits.

---

## 3. NetworkPolicies — Data Pool Separation at Infrastructure Level

### Q4: The JD requires preventing cross-pool data access between eval/training/holdout S3 buckets. At the Kubernetes layer, how do you enforce this with NetworkPolicies?

**Detailed Answer:**

S3 is accessed via HTTPS to AWS endpoints — not a Kubernetes-level concern directly. But I enforce separation at two levels:

**Level 1: IAM Policies (S3 side)** — each pod's ServiceAccount is bound to an IAM Role (via IRSA) that only has access to its pool's bucket:

```
eval-runners ServiceAccount    → IAM Role eval-runner-role
  → S3 policy: Allow s3:GetObject, s3:PutObject on arn:aws:s3:::eval-data-pool/*
  → S3 policy: DENY s3:* on training-data-pool/*, holdout-data-pool/*

metric-evaluators ServiceAccount → IAM Role metric-eval-role
  → S3 policy: Allow s3:GetObject on eval-data-pool/*
  → DENY all access to training and holdout buckets
```

**Level 2: NetworkPolicies (Kubernetes side)** — control which pods can communicate with which internal services (PostgreSQL, Weaviate, Redis):

```yaml
# Default deny ALL ingress and egress for eval-runners namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: eval-runners
spec:
  podSelector: {}          # Applies to all pods in namespace
  policyTypes:
    - Ingress
    - Egress

---
# Allow eval-runners to only reach eval PostgreSQL schema endpoint
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: eval-db-access
  namespace: eval-runners
spec:
  podSelector:
    matchLabels:
      app: scenario-runner
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              name: platform-infra
          podSelector:
            matchLabels:
              pool: eval          # Only the eval-pool PostgreSQL pod
      ports:
        - port: 5432
    - to:                         # Allow DNS resolution
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - port: 53
          protocol: UDP
    - ports:                      # Allow HTTPS egress (for S3, LLM APIs)
        - port: 443
          protocol: TCP
```

**PostgreSQL schema separation**: Even though it's the same PostgreSQL instance, each data pool gets its own schema with a dedicated database user:
```sql
CREATE SCHEMA eval_pool;
CREATE SCHEMA training_pool;
CREATE SCHEMA holdout_pool;

CREATE ROLE eval_runner LOGIN PASSWORD '...';
GRANT USAGE ON SCHEMA eval_pool TO eval_runner;
REVOKE ALL ON SCHEMA training_pool FROM eval_runner;
REVOKE ALL ON SCHEMA holdout_pool FROM eval_runner;
```

The connection strings in Vault secrets reference the schema-scoped user — even if a pod is compromised, it cannot query other schemas.

---

## 4. HashiCorp Vault — Secrets Management and Key Rotation

### Q5: You need to manage LLM API keys (Anthropic, OpenAI, Google), database credentials, and encryption keys — all with automatic rotation. Walk through your Vault architecture for this project.

**Detailed Answer:**

I use Vault in **Agent Sidecar Injection** mode for Kubernetes workloads — secrets are never stored in Kubernetes Secrets (etcd is not encrypted at rest in most default setups).

**Vault architecture:**

```
HashiCorp Vault (HA mode, 3 nodes, auto-unseal with AWS KMS)
  ├── Auth Methods
  │   └── Kubernetes Auth (pods authenticate via ServiceAccount JWT)
  ├── Secret Engines
  │   ├── KV v2: /secret/llm-keys/     (LLM API keys — manual rotation needed)
  │   ├── KV v2: /secret/encryption/   (AES-256 keys)
  │   └── Database Engine: /database/  (dynamic PostgreSQL creds — auto-rotated)
  └── Policies
      ├── eval-runner-policy    (read llm-keys/anthropic, db creds for eval schema)
      └── metric-eval-policy    (read llm-keys/openai, db creds for metric schema)
```

**Dynamic database credentials** (the right way to handle DB passwords):

```hcl
# Vault Database Secret Engine — PostgreSQL
vault write database/config/postgres-eval \
    plugin_name=postgresql-database-plugin \
    allowed_roles="eval-runner" \
    connection_url="postgresql://{{username}}:{{password}}@postgres:5432/tradecraft" \
    username="vault-root" \
    password="<root-password>"

vault write database/roles/eval-runner \
    db_name=postgres-eval \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' \
      VALID UNTIL '{{expiration}}'; \
      GRANT USAGE ON SCHEMA eval_pool TO \"{{name}}\";" \
    default_ttl="1h" \            # Credentials expire in 1 hour
    max_ttl="24h"
```

Pods get fresh, short-lived credentials every hour. No shared passwords. No manual rotation.

**LLM API keys** (static, require manual rotation — Anthropic/OpenAI don't support dynamic generation):

```hcl
vault kv put secret/llm-keys/anthropic \
    api_key="sk-ant-..." \
    rotation_date="2025-08-01"

# Vault policy for eval-runner pods
path "secret/data/llm-keys/anthropic" {
  capabilities = ["read"]
}
path "database/creds/eval-runner" {
  capabilities = ["read"]
}
```

**Pod annotation for Vault Agent injection:**

```yaml
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "eval-runner"
        vault.hashicorp.com/agent-inject-secret-anthropic: "secret/data/llm-keys/anthropic"
        vault.hashicorp.com/agent-inject-template-anthropic: |
          {{- with secret "secret/data/llm-keys/anthropic" -}}
          export ANTHROPIC_API_KEY="{{ .Data.data.api_key }}"
          {{- end }}
```

The Vault Agent sidecar writes secrets to an in-memory `tmpfs` volume at `/vault/secrets/` — never to disk, never in etcd.

**Key rotation for encryption keys**: Use Vault's Transit Engine as an encryption-as-a-service API rather than handling raw keys. Pods send data to Vault for encryption/decryption — the raw key material never leaves Vault.

---

## 5. cert-manager and mTLS

### Q6: How do you configure cert-manager for automatic mTLS between all services in the cluster, and what is the 90-day rotation process?

**Detailed Answer:**

I use cert-manager with an internal **ClusterIssuer** backed by an intermediate CA (stored in Vault PKI engine):

```yaml
# ClusterIssuer — backed by Vault PKI
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-internal-ca
spec:
  vault:
    server: https://vault.platform-infra:8200
    path: pki_int/sign/tradecraft-cluster  # Vault PKI intermediate CA
    caBundle: <base64-encoded-ca-cert>
    auth:
      kubernetes:
        role: cert-manager
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager
```

Each service gets a **Certificate** resource:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: scenario-runner-tls
  namespace: eval-runners
spec:
  secretName: scenario-runner-tls-secret
  duration: 2160h        # 90 days
  renewBefore: 360h      # Renew 15 days before expiry (cert-manager handles this automatically)
  isCA: false
  usages:
    - server auth
    - client auth          # Both — required for mTLS
  dnsNames:
    - scenario-runner.eval-runners.svc.cluster.local
    - scenario-runner.eval-runners.svc
  issuerRef:
    name: vault-internal-ca
    kind: ClusterIssuer
```

**Automatic 90-day rotation**: cert-manager watches the `renewBefore` field. 15 days before expiry it requests a new cert from Vault PKI, updates the Kubernetes Secret, and restarts pods that mount the secret (via `certmanager.io/inject-ca-from` annotation or a Reloader operator).

**Enforcing mTLS at the application level**: Two approaches:
1. **Istio (preferred for this project)**: Enable `PeerAuthentication` in STRICT mode — Istio's Envoy sidecars handle mTLS transparently, application code doesn't need to change:
```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: enforce-mtls
  namespace: eval-runners
spec:
  mtls:
    mode: STRICT       # All traffic must be mTLS — plaintext rejected
```

2. **Without service mesh**: Mount TLS certs into the application and configure the HTTP server to require client certificates. More complex, requires app changes.

**For this JD**: I'd use Istio STRICT mTLS per namespace + cert-manager for cert lifecycle. The combination gives zero-code-change mTLS enforcement.

---

## 6. Weaviate Vector Database on Kubernetes

### Q7: Walk through deploying Weaviate on Kubernetes with persistence, hourly S3 snapshots, and backup automation.

**Detailed Answer:**

Weaviate is deployed as a **StatefulSet** (not Deployment) because it needs stable pod identity and persistent storage:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: weaviate
  namespace: platform-infra
spec:
  serviceName: weaviate-headless
  replicas: 1              # Single node for this project; scale to 3 for HA
  selector:
    matchLabels:
      app: weaviate
  template:
    spec:
      containers:
        - name: weaviate
          image: cr.weaviate.io/semitechnologies/weaviate:1.25.0
          ports:
            - containerPort: 8080
              name: http
            - containerPort: 50051
              name: grpc
          env:
            - name: PERSISTENCE_DATA_PATH
              value: /var/lib/weaviate
            - name: DEFAULT_VECTORIZER_MODULE
              value: none              # Using external embeddings
            - name: ENABLE_MODULES
              value: "backup-s3"       # Enable S3 backup module
            - name: BACKUP_S3_BUCKET
              value: "tradecraft-weaviate-backups"
            - name: BACKUP_S3_PATH
              value: "weaviate/"
            - name: AWS_REGION
              value: "us-east-1"
          volumeMounts:
            - name: weaviate-data
              mountPath: /var/lib/weaviate
          resources:
            requests:
              memory: "4Gi"
              cpu: "1"
            limits:
              memory: "16Gi"
              cpu: "4"
          readinessProbe:
            httpGet:
              path: /v1/.well-known/ready
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
  volumeClaimTemplates:              # PVC per pod (stable storage)
    - metadata:
        name: weaviate-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: "gp3-encrypted"
        resources:
          requests:
            storage: 100Gi
```

**Hourly S3 snapshots via CronJob:**

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: weaviate-backup
  namespace: platform-infra
spec:
  schedule: "0 * * * *"         # Every hour
  concurrencyPolicy: Forbid      # Don't overlap backup jobs
  failedJobsHistoryLimit: 3
  successfulJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: weaviate-backup-sa  # Has S3 write via IRSA
          containers:
            - name: backup
              image: curlimages/curl:latest
              command:
                - sh
                - -c
                - |
                  BACKUP_ID="hourly-$(date +%Y%m%d-%H%M%S)"
                  curl -X POST \
                    "http://weaviate.platform-infra:8080/v1/backups/s3" \
                    -H "Content-Type: application/json" \
                    -d "{
                      \"id\": \"${BACKUP_ID}\",
                      \"include\": [\"EvalCollection\", \"TrainingCollection\"]
                    }"
                  echo "Backup ${BACKUP_ID} triggered"
          restartPolicy: OnFailure
```

**Backup retention policy** (S3 lifecycle rule via Terraform):

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "weaviate_backups" {
  bucket = aws_s3_bucket.weaviate_backups.id

  rule {
    id     = "hourly-retention"
    status = "Enabled"
    
    filter { prefix = "weaviate/hourly-" }
    
    expiration { days = 7 }          # Keep hourly backups for 7 days
  }
  
  rule {
    id     = "daily-retention"
    status = "Enabled"
    
    filter { prefix = "weaviate/daily-" }
    
    expiration { days = 30 }         # Keep daily backups for 30 days
  }
}
```

---

## 8. Elastic Cloud / OpenTelemetry Integration

### Q8: How do you integrate Kubernetes-based microservices with an existing Elastic Cloud/APM stack using OpenTelemetry? What custom indices do you configure for AI inference logs?

**Detailed Answer:**

I deploy an **OpenTelemetry Collector** as a DaemonSet (one per node, for logs/metrics) and as a Deployment (for traces aggregation):

```yaml
# OpenTelemetry Collector — traces from all namespaces
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: otel-collector
  namespace: platform-infra
spec:
  mode: Deployment
  config: |
    receivers:
      otlp:                         # Receive from instrumented apps
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        timeout: 5s
        send_batch_size: 1000
      
      attributes/add_env:           # Enrich spans with cluster metadata
        actions:
          - key: k8s.cluster.name
            value: tradecraft-prod
            action: insert
          - key: deployment.environment
            value: production
            action: insert

      filter/pii:                   # Drop PII before sending to Elastic
        traces:
          span:
            - 'attributes["user.email"] != nil'  # Remove spans with PII

    exporters:
      elasticsearchexporter:
        endpoints:
          - https://elastic.cloud.example.com:9243
        api_key: "${ELASTIC_APM_API_KEY}"
        logs_index: "tradecraft-inference-logs"    # Custom index for AI logs
        traces_index: "tradecraft-traces"
        tls:
          ca_file: /etc/ssl/elastic-ca.pem

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch, attributes/add_env, filter/pii]
          exporters: [elasticsearchexporter]
        logs:
          receivers: [otlp]
          processors: [batch, attributes/add_env]
          exporters: [elasticsearchexporter]
```

**Custom Elastic indices for the AI platform:**

```
tradecraft-inference-logs-*
  Fields: model_name, prompt_tokens, completion_tokens, latency_ms, 
          eval_run_id, scenario_id, pool_name (eval/training/holdout)

tradecraft-eval-metadata-*
  Fields: eval_run_id, scenario_count, pass_rate, model_version,
          started_at, completed_at, triggered_by (user/scheduled)

tradecraft-feedback-audit-*
  Fields: feedback_id, eval_run_id, reviewer_id, original_score,
          adjusted_score, justification, timestamp
          (Immutable index — append-only for compliance audit trail)
```

**Application instrumentation** (Python services):

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

tracer = trace.get_tracer("scenario-runner")

async def run_evaluation(scenario: Scenario, model: str):
    with tracer.start_as_current_span("evaluation") as span:
        span.set_attribute("eval.scenario_id", scenario.id)
        span.set_attribute("eval.model", model)
        span.set_attribute("eval.pool", scenario.data_pool)
        
        with tracer.start_as_current_span("llm_call"):
            span.set_attribute("llm.provider", "anthropic")
            response = await anthropic_client.call(scenario.prompt)
            span.set_attribute("llm.prompt_tokens", response.usage.input_tokens)
            span.set_attribute("llm.completion_tokens", response.usage.output_tokens)
        
        with tracer.start_as_current_span("metric_evaluation"):
            score = evaluate_response(response.content)
            span.set_attribute("eval.score", score)
```

---

## 9. CI/CD Pipeline with Security Gates

### Q9: Design the full CI/CD pipeline for this platform — from PR to production — including Trivy scanning, staging deployment, manual approval, and automatic rollback.

**Detailed Answer:**

```yaml
# .github/workflows/deploy.yml
name: Deploy Tradecraft Platform

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  # ── Stage 1: Build and Scan ────────────────────────────────────
  build-and-scan:
    runs-on: ubuntu-latest
    outputs:
      image-tag: ${{ steps.meta.outputs.tags }}
      image-digest: ${{ steps.build.outputs.digest }}
    steps:
      - uses: actions/checkout@v4
      
      - name: Build container image
        id: build
        uses: docker/build-push-action@v5
        with:
          push: true
          tags: ${{ env.REGISTRY }}/scenario-runner:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Run Trivy vulnerability scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: ${{ env.REGISTRY }}/scenario-runner:${{ github.sha }}
          format: sarif
          output: trivy-results.sarif
          severity: CRITICAL,HIGH      # Fail pipeline on CRITICAL/HIGH CVEs
          exit-code: 1                 # Hard fail — blocks merge
          ignore-unfixed: true         # Skip CVEs with no patch available
      
      - name: Upload scan results to GitHub Security tab
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: trivy-results.sarif

  # ── Stage 2: Automated Tests ───────────────────────────────────
  test:
    needs: build-and-scan
    runs-on: ubuntu-latest
    steps:
      - name: Run integration tests against staging-like environment
        run: |
          docker-compose -f docker-compose.test.yml up --abort-on-container-exit
          docker-compose -f docker-compose.test.yml down

  # ── Stage 3: Staging Deployment ───────────────────────────────
  deploy-staging:
    needs: [build-and-scan, test]
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: staging              # GitHub Environment with staging secrets
    steps:
      - name: Deploy to staging
        run: |
          kubectl set image deployment/scenario-runner \
            scenario-runner=${{ env.REGISTRY }}/scenario-runner:${{ github.sha }} \
            --namespace eval-runners-staging
          
          kubectl rollout status deployment/scenario-runner \
            --namespace eval-runners-staging \
            --timeout=300s

      - name: Run smoke tests against staging
        run: |
          python tests/smoke_test.py \
            --endpoint https://api-staging.tradecraft.turing.com \
            --scenarios 5

  # ── Stage 4: Manual Approval Gate ────────────────────────────
  production-approval:
    needs: deploy-staging
    runs-on: ubuntu-latest
    environment: production           # GitHub Environment with required reviewers
    steps:
      - name: Await approval
        run: echo "Awaiting manual approval from authorized reviewer"

  # ── Stage 5: Production Deployment (Rolling + Auto-Rollback) ──
  deploy-production:
    needs: production-approval
    runs-on: ubuntu-latest
    steps:
      - name: Record pre-deploy revision
        id: pre-deploy
        run: |
          REVISION=$(kubectl rollout history deployment/scenario-runner \
            --namespace eval-runners | tail -1 | awk '{print $1}')
          echo "revision=${REVISION}" >> $GITHUB_OUTPUT

      - name: Deploy to production (rolling update)
        run: |
          kubectl set image deployment/scenario-runner \
            scenario-runner=${{ env.REGISTRY }}/scenario-runner:${{ github.sha }} \
            --namespace eval-runners

      - name: Wait for rollout
        id: rollout
        run: |
          kubectl rollout status deployment/scenario-runner \
            --namespace eval-runners \
            --timeout=600s

      - name: Post-deploy health check
        id: health
        run: |
          sleep 30
          ERRORS=$(kubectl logs -l app=scenario-runner \
            --namespace eval-runners --since=1m | grep -c "ERROR" || true)
          if [ "$ERRORS" -gt "5" ]; then
            echo "Too many errors post-deploy: $ERRORS"
            exit 1
          fi

      - name: Automatic rollback on failure
        if: failure() && steps.rollout.outcome == 'failure' || steps.health.outcome == 'failure'
        run: |
          echo "Deploy failed — rolling back to revision ${{ steps.pre-deploy.outputs.revision }}"
          kubectl rollout undo deployment/scenario-runner \
            --namespace eval-runners \
            --to-revision=${{ steps.pre-deploy.outputs.revision }}
          
          # Alert Slack/PagerDuty
          curl -X POST ${{ secrets.SLACK_WEBHOOK }} \
            -d '{"text":"🚨 Production rollback triggered for scenario-runner"}'
```

---

## 10. PostgreSQL Operations — WAL Archiving and PITR

### Q10: The JD mentions PostgreSQL with WAL archiving and point-in-time recovery. Walk through how you set this up on Kubernetes.

**Detailed Answer:**

For production PostgreSQL on Kubernetes I use **CloudNativePG** operator — it handles WAL archiving, PITR, streaming replication, and automated failover natively:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: tradecraft-postgres
  namespace: platform-infra
spec:
  instances: 3                  # 1 primary + 2 replicas

  postgresql:
    parameters:
      wal_level: "replica"
      archive_mode: "on"
      max_wal_senders: "10"
      hot_standby: "on"

  bootstrap:
    initdb:
      database: tradecraft
      owner: tradecraft_admin
      secret:
        name: tradecraft-db-credentials

  backup:
    retentionPolicy: "30d"       # Keep 30 days of backups + WAL
    barmanObjectStore:
      destinationPath: "s3://tradecraft-postgres-backups/tradecraft/"
      s3Credentials:
        accessKeyId:
          name: postgres-s3-creds
          key: ACCESS_KEY_ID
        secretAccessKey:
          name: postgres-s3-creds
          key: SECRET_ACCESS_KEY
      wal:
        compression: gzip
        maxParallel: 4           # Upload 4 WAL files simultaneously

  storage:
    size: 500Gi
    storageClass: gp3-encrypted

  monitoring:
    enablePodMonitor: true       # Prometheus metrics via PodMonitor
```

**Scheduled base backups:**

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: daily-backup
  namespace: platform-infra
spec:
  schedule: "0 2 * * *"         # 2 AM daily
  cluster:
    name: tradecraft-postgres
  immediate: true
```

**Point-in-time recovery** — restore to a specific timestamp after a bad data migration:

```yaml
# Recovery cluster — spins up a new cluster restored to specific time
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: tradecraft-postgres-recovery
spec:
  instances: 1
  bootstrap:
    recovery:
      source: tradecraft-postgres
      recoveryTarget:
        targetTime: "2025-05-17 14:30:00"   # Restore to this exact moment
      backup:
        name: daily-backup-20250517
  externalClusters:
    - name: tradecraft-postgres
      barmanObjectStore:
        destinationPath: "s3://tradecraft-postgres-backups/tradecraft/"
        # ... s3 credentials
```

PITR accuracy depends on WAL archiving frequency. With WAL archiving enabled, you can recover to any point within seconds of the target time, minimizing data loss.

---

## 11. Whisper Audio Transcription — Data Sovereignty

### Q11: The JD requires deploying self-hosted Whisper Large-v3 to ensure audio data doesn't leave the client's cloud. How do you deploy this on Kubernetes?

**Detailed Answer:**

Whisper Large-v3 requires significant GPU memory (~10GB for FP16). Deployment approach:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whisper-transcription
  namespace: platform-infra
spec:
  replicas: 2                    # 2 replicas for HA
  selector:
    matchLabels:
      app: whisper
  template:
    spec:
      nodeSelector:
        accelerator: nvidia-t4   # T4 16GB is sufficient for Whisper Large-v3
      tolerations:
        - key: "nvidia.com/gpu"
          operator: "Exists"
          effect: "NoSchedule"
      initContainers:
        - name: model-downloader
          image: python:3.11-slim
          command:
            - sh
            - -c
            - |
              pip install huggingface_hub
              # Download once to shared volume — not at every startup
              if [ ! -f /models/whisper-large-v3/pytorch_model.bin ]; then
                huggingface-cli download openai/whisper-large-v3 \
                  --local-dir /models/whisper-large-v3
              fi
          volumeMounts:
            - name: model-storage
              mountPath: /models
      containers:
        - name: whisper-api
          image: ghcr.io/openai/whisper:latest
          # Or custom FastAPI wrapper:
          # image: internal-registry/whisper-api:v1.2.0
          ports:
            - containerPort: 8080
          env:
            - name: MODEL_PATH
              value: /models/whisper-large-v3
            - name: DEVICE
              value: cuda
          resources:
            limits:
              nvidia.com/gpu: "1"
              memory: "16Gi"
            requests:
              nvidia.com/gpu: "1"
              memory: "12Gi"
          volumeMounts:
            - name: model-storage
              mountPath: /models
              readOnly: true
      volumes:
        - name: model-storage
          persistentVolumeClaim:
            claimName: whisper-model-pvc
```

**Data sovereignty enforcement (critical for this JD):**

1. **NetworkPolicy — egress DENY by default**: Whisper pods can only communicate with internal services. No egress to the internet:
```yaml
spec:
  podSelector:
    matchLabels:
      app: whisper
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector: {}   # Allow only intra-cluster traffic
      ports:
        - port: 53                # DNS only
```

2. **No S3 egress for audio**: Audio files are processed in memory, transcripts written to internal PostgreSQL. Raw audio is never written to any external store.

3. **Audit log**: Every transcription request is logged with `requestor_pod`, `timestamp`, `audio_hash` (not the audio itself) to the Elastic audit index.

---

## 12. GitOps with ArgoCD

### Q12: The JD lists ArgoCD as a preferred qualification. How does GitOps change your deployment model for this platform?

**Detailed Answer:**

Without GitOps: CI pipeline applies changes directly with `kubectl`. The cluster state can drift from Git (someone runs `kubectl edit` in production).

With ArgoCD: **Git is the single source of truth**. ArgoCD continuously reconciles cluster state to match Git.

```yaml
# ArgoCD Application for eval-runners namespace
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: eval-runners
  namespace: argocd
spec:
  project: tradecraft
  
  source:
    repoURL: https://github.com/turing/tradecraft-infra
    targetRevision: main
    path: k8s/eval-runners
    
    # If using Helm:
    helm:
      valueFiles:
        - values-production.yaml

  destination:
    server: https://kubernetes.default.svc
    namespace: eval-runners

  syncPolicy:
    automated:
      prune: true          # Delete resources removed from Git
      selfHeal: true       # Revert manual changes (kubectl edit, etc.)
    syncOptions:
      - CreateNamespace=false    # Namespace must be pre-created with right labels
      - RespectIgnoreDifferences=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        maxDuration: 3m
```

**ArgoCD for this project gives:**
1. **Drift detection**: If a security engineer accidentally runs `kubectl delete networkpolicy` in production, ArgoCD re-applies it within 3 minutes (selfHeal)
2. **Rollback = git revert**: Production rollback is `git revert <commit> && git push` — no kubectl commands needed, full audit trail
3. **Promotion workflow**: Staging → Production = PR from `env/staging` to `env/production` branch, with approval gate

**Multi-environment repo structure:**
```
tradecraft-infra/
├── base/                         # Shared manifests
│   ├── eval-runners/
│   └── platform-infra/
├── overlays/
│   ├── staging/                  # Kustomize patches for staging
│   └── production/               # Kustomize patches for production
└── argocd/
    ├── staging-apps.yaml         # ArgoCD ApplicationSet for staging
    └── production-apps.yaml      # ArgoCD ApplicationSet for production
```

---

## 13. Data Separation — S3 Bucket Design

### Q13: Design the S3 bucket architecture for three isolated data pools (eval/training/holdout) with IAM enforcement.

**Detailed Answer:**

```hcl
# Terraform — three physically separate buckets
resource "aws_s3_bucket" "eval_pool" {
  bucket = "tradecraft-eval-data-${var.environment}"
  
  tags = {
    DataPool    = "eval"
    Compliance  = "sensitive"
    Environment = var.environment
  }
}

resource "aws_s3_bucket" "training_pool" {
  bucket = "tradecraft-training-data-${var.environment}"
  tags   = { DataPool = "training" }
}

resource "aws_s3_bucket" "holdout_pool" {
  bucket = "tradecraft-holdout-data-${var.environment}"
  tags   = { DataPool = "holdout" }
}

# Block ALL public access — every bucket
resource "aws_s3_bucket_public_access_block" "all" {
  for_each = {
    eval     = aws_s3_bucket.eval_pool.id
    training = aws_s3_bucket.training_pool.id
    holdout  = aws_s3_bucket.holdout_pool.id
  }
  
  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policy — DENY access from any IAM role NOT in the allowed list
resource "aws_s3_bucket_policy" "holdout_deny_all_except_allowed" {
  bucket = aws_s3_bucket.holdout_pool.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyAllExceptHoldoutRole"
        Effect = "Deny"
        Principal = "*"
        Action = "s3:*"
        Resource = [
          "${aws_s3_bucket.holdout_pool.arn}",
          "${aws_s3_bucket.holdout_pool.arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:PrincipalArn" = [
              aws_iam_role.holdout_reader.arn    # Only holdout evaluator can access
            ]
          }
        }
      }
    ]
  })
}
```

---

## 14. FedRAMP and Compliance Questions

### Q14: The JD mentions FedRAMP-compatible cloud environments. What does this mean operationally?

**Detailed Answer:**

FedRAMP (Federal Risk and Authorization Management Program) mandates NIST 800-53 controls for cloud services used by US federal agencies. "FedRAMP-compatible" in this JD means the architecture must not violate FedRAMP boundaries.

**Operational implications:**

1. **Data residency**: All data stays in US GovCloud regions (`us-gov-east-1`, `us-gov-west-1`) — no data egress to commercial regions
2. **Encryption at rest**: AES-256 required for all data stores (S3 SSE-KMS, EBS encryption, RDS encryption)
3. **Encryption in transit**: TLS 1.2+ minimum, TLS 1.3 preferred — this is why mTLS with cert-manager matters
4. **Audit logging**: All API calls logged to CloudTrail, all DB access logged, immutable audit log (WORM storage)
5. **Access controls**: MFA for all human access, no root account usage, all access via federated identity
6. **Vulnerability scanning**: Regular scanning (Trivy in CI, AWS Inspector for running instances), patches within defined windows (CRITICAL: 72 hours)
7. **Secrets management**: No hardcoded credentials anywhere — Vault or AWS Secrets Manager required
8. **Approved services**: Only FedRAMP-authorized services can be used. OpenAI API is NOT FedRAMP authorized — this is exactly why the JD requires self-hosted Whisper (and likely requires self-hosted LLMs rather than public APIs)

**What changes in your Terraform:**
```hcl
# GovCloud provider
provider "aws" {
  region = "us-gov-west-1"     # Not us-east-1
}

# FIPS endpoints for compliance
resource "aws_s3_bucket" "eval" {
  # All S3 requests use FIPS endpoints: s3-fips.amazonaws.com
}

# KMS CMK — customer-managed key (not AWS-managed)
resource "aws_kms_key" "data_key" {
  description             = "CMK for tradecraft data encryption"
  enable_key_rotation     = true      # Annual automatic rotation
  deletion_window_in_days = 30
}
```

---

## 15. Quick-Fire Technical Questions

**Q: What is the difference between a Kubernetes NetworkPolicy and a Service Mesh (Istio) policy?**

NetworkPolicy operates at L3/L4 — it filters by IP address, port, and namespace/pod label selectors. It cannot inspect HTTP headers, paths, or gRPC method names. A Service Mesh (Istio AuthorizationPolicy) operates at L7 — it can allow/deny based on JWT claims, HTTP methods, URL paths, gRPC service names. For this project, I use both: NetworkPolicy for coarse-grained namespace isolation (eval runners cannot reach holdout DB), Istio AuthorizationPolicy for fine-grained service-to-service rules (scenario runner can only call `/evaluate` endpoint on metric evaluator, not `/admin`).

**Q: How do you handle Kubernetes secret encryption at rest?**

By default etcd (where Kubernetes Secrets are stored) is NOT encrypted at rest. Enable `EncryptionConfiguration` on the API server with AES-GCM-256 using a KMS provider (AWS KMS on EKS). With this, every Secret stored in etcd is encrypted with a DEK (data encryption key) that is itself encrypted by the KMS master key. For this project, since we use Vault Agent injection, most secrets never touch etcd at all.

**Q: How do you debug a pod stuck in CrashLoopBackOff after a deployment?**

```bash
# 1. Check current error
kubectl logs <pod> --namespace eval-runners

# 2. Check previous container's logs (before crash)
kubectl logs <pod> --previous --namespace eval-runners

# 3. Check pod events
kubectl describe pod <pod> --namespace eval-runners
# Look for: OOMKilled (increase memory), ImagePullBackOff (registry auth),
#           Vault agent errors (secret path wrong), readiness probe failures

# 4. For Vault injection issues specifically
kubectl logs <pod> -c vault-agent-init --namespace eval-runners
```

**Q: What is the difference between Horizontal Pod Autoscaler and Cluster Autoscaler?**

HPA scales the **number of pods** within a node — adds or removes replicas of a Deployment. Cluster Autoscaler scales the **number of nodes** — when pods cannot be scheduled (pending) due to insufficient node capacity, CA provisions new nodes; when nodes are underutilized, CA drains and terminates them. For this project: HPA (via KEDA) handles traffic bursts by adding eval worker pods. When HPA requests more pods than nodes can accommodate, Cluster Autoscaler adds GPU nodes from the node group. The two work in tandem.

**Q: Redis Cluster vs Redis Sentinel — which do you deploy for this platform?**

Redis Cluster: horizontal sharding across multiple nodes, each shard holds a portion of the keyspace. Requires client-side awareness (cluster-aware clients). Best for high-throughput, large keyspace.

Redis Sentinel: high availability for a single Redis instance (primary + replicas). Sentinel monitors primary health and promotes a replica on failure. No sharding — one node holds all data. Best for HA without complexity.

For this platform (job queue + session cache): **Redis Sentinel** is appropriate. The data volume is modest, simplicity is preferred. On Kubernetes, deploy using the Bitnami Redis Helm chart with `architecture: replication` + `sentinel.enabled: true`. Sentinel gives automatic failover without the cluster complexity.
