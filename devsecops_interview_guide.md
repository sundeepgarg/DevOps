# DevSecOps Interview Guide

**Target Role:** Senior/Principal Platform Engineer  
**Background:** DevSecOps 4 years, CyberArk + Falcon Sensor + cert-manager at Voya/IBM, OCP security hardening

---

## 1. Shift-Left Security

### The Shift-Left Philosophy

Traditional security: security team reviews before production → finds issues late, expensive to fix.
Shift-left: move security checks earlier into the development lifecycle → find issues when they're cheap to fix.

```
Commit  →  Build  →  Test  →  Staging  →  Production
  ↑           ↑        ↑         ↑              ↑
Secret      SAST    DAST/       IaC           Runtime
scanning   (code)  Trivy      scanning      (Falcon/
(gitleaks)         (image)    (tfsec)        Falco)
```

### SAST Tools in CI

```yaml
# GitHub Actions: run Semgrep on every PR
- name: Semgrep SAST
  uses: returntocorp/semgrep-action@v1
  with:
    config: "p/python p/kubernetes p/owasp-top-ten"
  env:
    SEMGREP_APP_TOKEN: ${{ secrets.SEMGREP_TOKEN }}
```

```yaml
# SonarQube quality gate in pipeline
- name: SonarQube Scan
  run: |
    mvn sonar:sonar \
      -Dsonar.host.url=${{ secrets.SONAR_URL }} \
      -Dsonar.login=${{ secrets.SONAR_TOKEN }}

- name: Quality Gate Check
  run: |
    curl -s "$SONAR_URL/api/qualitygates/project_status?projectKey=my-app" \
    | jq -e '.projectStatus.status == "OK"'
```

### IaC Scanning

```bash
# tfsec: scan Terraform for misconfigurations
tfsec . --no-colour --format json | jq '.results[] | select(.severity == "CRITICAL")'

# checkov: policy-as-code for Terraform + K8s manifests
checkov -d . --framework terraform --check CKV_AZURE_35  # storage public access
checkov -d ./k8s --framework kubernetes --check CKV_K8S_30  # root containers

# kubesec: Kubernetes manifest security scoring
kubesec scan deployment.yaml
```

---

## 2. Container Image Security

### Trivy in CI/CD

```yaml
# GitHub Actions: fail build on CRITICAL CVE
- name: Trivy Image Scan
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: "myorg/my-app:${{ github.sha }}"
    format: "table"
    exit-code: "1"           # Fail the pipeline
    severity: "CRITICAL,HIGH"
    vuln-type: "os,library"
    ignore-unfixed: true     # Don't fail on vulns with no fix available
```

**CVE triage workflow:**
1. `trivy image --severity CRITICAL my-app:latest` — list all CRITICAL CVEs.
2. Check if CVE has a fix: `ignore-unfixed: true` skips unfixed (no point failing for unfixable).
3. For fixable CVEs: update the base image to the patched version.
4. For base image CVEs: switch from `ubuntu:22.04` to `gcr.io/distroless/python3` (minimal attack surface, fewer CVEs).
5. For false positives: add to `.trivyignore` with justification comment.

### Distroless and Minimal Images

```dockerfile
# Multi-stage: build in full image, run in minimal
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --target=/app/deps -r requirements.txt

FROM gcr.io/distroless/python3-debian12 AS runtime
COPY --from=builder /app/deps /app/deps
COPY --from=builder /app/src /app/src
ENV PYTHONPATH=/app/deps
CMD ["/app/src/main.py"]
```

Distroless images:
- No shell (no `bash`/`sh`) — reduces attack surface dramatically
- No package manager (can't install tools post-compromise)
- 100-300MB smaller than full OS images
- Fewer CVEs (no unused system packages)

### Image Signing with Cosign (Sigstore)

```bash
# Sign image after build (CI)
cosign sign \
  --key cosign.key \
  myregistry.azurecr.io/myapp:sha-abc123

# Verify before deployment (admission webhook)
cosign verify \
  --key cosign.pub \
  myregistry.azurecr.io/myapp:sha-abc123
```

Sigstore Policy Controller (Kubernetes admission webhook):
```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: require-signed-images
spec:
  images:
    - glob: "myregistry.azurecr.io/**"
  authorities:
    - key:
        hashAlgorithm: sha256
        data: |
          -----BEGIN PUBLIC KEY-----
          ...cosign public key...
          -----END PUBLIC KEY-----
```
Any unsigned image from `myregistry.azurecr.io` will be rejected by the admission webhook.

---

## 3. Secrets Management

### What NOT to Do

```yaml
# NEVER: secrets in ConfigMap
apiVersion: v1
kind: ConfigMap
data:
  DB_PASSWORD: "mysecretpassword"   # stored in etcd in plaintext

# NEVER: secrets in Deployment env vars from plain values
env:
  - name: DB_PASSWORD
    value: "mysecretpassword"

# NEVER: secrets in Git (even .gitignore doesn't protect if accidentally staged)
```

### HashiCorp Vault Dynamic Secrets

```hcl
# Vault policy: allow inference service to read DB credentials
path "database/creds/inference-readonly" {
  capabilities = ["read"]
}
```

```yaml
# Kubernetes annotation to inject Vault secret via Vault Agent sidecar
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "inference-service"
        vault.hashicorp.com/agent-inject-secret-db-creds: "database/creds/inference-readonly"
        vault.hashicorp.com/agent-inject-template-db-creds: |
          {{- with secret "database/creds/inference-readonly" -}}
          DB_USER={{ .Data.data.username }}
          DB_PASSWORD={{ .Data.data.password }}
          {{- end -}}
```

The Vault Agent sidecar:
- Authenticates to Vault using the pod's Kubernetes service account token
- Writes the secret to `/vault/secrets/db-creds` in a tmpfs volume (never etcd, never disk)
- Automatically renews the lease before the TTL expires (dynamic credential rotation without restart)

### External Secrets Operator (ESO)

```yaml
# ExternalSecret pulls from Azure Key Vault into a Kubernetes Secret
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: inference-db-creds
  namespace: ml-platform
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: azure-keyvault-store
    kind: ClusterSecretStore
  target:
    name: inference-db-creds      # Kubernetes Secret created by ESO
    creationPolicy: Owner
  data:
    - secretKey: db-password      # key in Kubernetes Secret
      remoteRef:
        key: ml-inference-db-password   # name in Azure Key Vault
```

The `ClusterSecretStore` uses Workload Identity (no static credentials) to authenticate to Azure Key Vault.

---

## 4. CyberArk

### CyberArk Architecture

```
CyberArk Privileged Access Manager (PAM):
├── Vault (Enterprise Password Vault — EPV)   — encrypted credential storage
├── Central Policy Manager (CPM)              — rotates credentials on schedule
├── Central Credential Provider (CCP)         — REST API for app credential retrieval
└── AAM (Application Access Manager)          — K8s/OpenShift native integration
    └── Conjur (CyberArk's K8s-native vault)  — modern API, CRD-based
```

### Application Access Manager (AAM) on OpenShift

```bash
# Install CyberArk AAM Operator via OperatorHub
# AAM uses Kubernetes service accounts + JWT for authentication

# Create a CyberArk AppIdentity for each application
```

```yaml
# Summon (CyberArk) sidecar pattern
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      initContainers:
        - name: cyberark-secrets-provider
          image: conjur-org/secrets-provider-for-k8s:latest
          env:
            - name: CONJUR_APPLIANCE_URL
              value: "https://conjur.example.com"
            - name: SECRETS_DESTINATION
              value: "file"    # writes to /conjur/secrets/
          volumeMounts:
            - name: conjur-secrets
              mountPath: /conjur/secrets
      containers:
        - name: inference-server
          volumeMounts:
            - name: conjur-secrets
              mountPath: /conjur/secrets
              readOnly: true
      volumes:
        - name: conjur-secrets
          emptyDir:
            medium: Memory    # tmpfs — never written to disk
```

### CCP (Central Credential Provider) REST API

For applications that can't use a sidecar (legacy apps, batch jobs):

```bash
# Retrieve credential via CCP REST API
curl -s \
  --cert /certs/app.crt \
  --key /certs/app.key \
  "https://ccp.company.com/AIMWebService/api/Accounts?AppID=my-inference-app&Safe=InferenceSafe&Object=db-password"
```

Certificate-based authentication: the app presents a client certificate to CCP. CCP validates the cert against its CA, authorises the AppID, and returns the credential. No hardcoded passwords.

**Interview point**: CyberArk is common in regulated industries (financial services, healthcare). Voya is a financial services company — CyberArk is the enterprise standard for privileged access.

---

## 5. Falcon Sensor on OpenShift

### Falcon Sensor Architecture

```
CrowdStrike Falcon on OpenShift:
├── Falcon Node Sensor (DaemonSet)    — kernel-level monitoring on each node
│   └── Uses eBPF or kernel module to observe syscalls
└── Falcon Container Sensor           — process-level monitoring per container (no eBPF)
    └── Runs as a sidecar or via Falcon operator admission webhook
```

### OpenShift-Specific SCC Requirements

The Falcon Node Sensor needs elevated privileges for kernel access:

```yaml
# Falcon Node Sensor requires privileged SCC or a custom SCC
# Minimal custom SCC (preferred over privileged):
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: falcon-node-sensor
allowPrivilegedContainer: false
allowPrivilegeEscalation: false
allowedCapabilities:
  - SYS_PTRACE      # process tracing
  - SYS_ADMIN       # required for eBPF program loading
hostNetwork: true    # required for network-level detection
hostPID: true        # required for cross-process monitoring
hostIPC: false
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: MustRunAs
  seLinuxOptions:
    type: spc_t     # super-privileged container type in SELinux
volumes:
  - hostPath        # access /proc, /sys for kernel monitoring
  - secret
  - configMap
```

```bash
# Deploy Falcon Operator via OperatorHub
# Create FalconNodeSensor CR
cat <<EOF | oc apply -f -
apiVersion: falcon.crowdstrike.com/v1alpha1
kind: FalconNodeSensor
metadata:
  name: falcon-node-sensor
  namespace: falcon-system
spec:
  falcon:
    tags:
      - "env:production"
      - "cluster:aro-prod"
  falcon_api:
    client_id:     # Falcon API client ID
    client_secret: # Falcon API client secret
    cloud_region: "autodiscover"
  node:
    backend: kernel   # or: bpf (preferred on modern kernels)
EOF
```

### Runtime Detection (What Falcon Monitors)

- Process executions: detects `curl | bash`, crypto miners, reverse shells
- Network connections: alerts on unexpected outbound connections from pods
- File writes: alerts on writes to sensitive directories (`/etc/passwd`, `/proc/sys/`)
- Privilege escalation: detects attempts to escape the container

---

## 6. cert-manager

### cert-manager Architecture

```
cert-manager components:
├── cert-manager controller     — processes Certificate, CertificateRequest CRs
├── cert-manager-webhook        — validates Certificate CRs (admission webhook)
└── cert-manager-cainjector     — injects CA bundle into webhook configs

Certificate lifecycle:
  Certificate CR created
    → controller creates CertificateRequest
    → CertificateRequest sent to Issuer (Vault, ACME, self-signed)
    → Certificate issued → stored as Kubernetes Secret
    → Renewed automatically `renewBefore` days before expiry
```

### ClusterIssuer vs Issuer

```yaml
# ClusterIssuer: cluster-scoped, can issue certs for any namespace
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-pki-issuer
spec:
  vault:
    server: https://vault.company.com
    path: pki/sign/platform-certs
    auth:
      kubernetes:
        role: cert-manager
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager

# Issuer: namespace-scoped
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: local-issuer
  namespace: ml-platform
spec:
  selfSigned: {}
```

### Certificate Resource

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: inference-tls
  namespace: ml-platform
spec:
  secretName: inference-tls-secret     # Secret where cert is stored
  issuerRef:
    name: vault-pki-issuer
    kind: ClusterIssuer
  commonName: inference.ml-platform.svc.cluster.local
  dnsNames:
    - inference.ml-platform.svc.cluster.local
    - inference.ml-platform.svc
    - inference.apps.aro-cluster.example.com
  duration: 2160h      # 90 days
  renewBefore: 360h    # Start renewing 15 days before expiry
  privateKey:
    algorithm: ECDSA
    size: 256
```

```bash
# Check certificate status
kubectl get certificate -n ml-platform
kubectl describe certificate inference-tls -n ml-platform
# STATUS: Ready = cert is valid and not expiring soon

# Force renewal (for testing rotation)
kubectl delete secret inference-tls-secret -n ml-platform
# cert-manager will immediately re-issue
```

---

## 7. OPA Gatekeeper and Kyverno

### OPA Gatekeeper

Gatekeeper uses Open Policy Agent to write admission policies in Rego.

```yaml
# ConstraintTemplate: define the policy in Rego
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredresources
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredResources
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredresources
        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not container.resources.limits.memory
          msg := sprintf("Container %v missing memory limit", [container.name])
        }

---
# Constraint: enforce the policy on all Deployments
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredResources
metadata:
  name: require-memory-limits
spec:
  match:
    kinds:
      - apiGroups: ["apps"]
        kinds: ["Deployment"]
    excludedNamespaces: ["kube-system", "openshift-*"]
  enforcementAction: deny   # or: warn (audit mode)
```

### Kyverno (simpler alternative to Gatekeeper)

```yaml
# Kyverno: require resource limits (YAML syntax, no Rego)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resource-limits
spec:
  validationFailureAction: enforce
  rules:
    - name: check-memory-limits
      match:
        resources:
          kinds:
            - Pod
      validate:
        message: "Memory limits are required for all containers."
        pattern:
          spec:
            containers:
              - name: "*"
                resources:
                  limits:
                    memory: "?*"
```

**Kyverno mutation** — auto-add default resource limits:
```yaml
- name: add-default-memory-limit
  mutate:
    patchStrategicMerge:
      spec:
        containers:
          - (name): "*"
            resources:
              limits:
                +(memory): "512Mi"    # Only adds if not already set
```

---

## 8. RBAC Hardening

### Principle of Least Privilege

```bash
# Create a minimal service account for a CI/CD pipeline
oc create sa github-actions-deploy -n ml-platform

# Grant only what the pipeline needs (not cluster-admin)
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer
  namespace: ml-platform
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "update", "patch"]
  - apiGroups: ["serving.kserve.io"]
    resources: ["inferenceservices"]
    verbs: ["get", "list", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: github-actions-deployer
  namespace: ml-platform
subjects:
  - kind: ServiceAccount
    name: github-actions-deploy
roleRef:
  kind: Role
  name: deployer
  apiGroup: rbac.authorization.k8s.io
EOF
```

### OIDC Federation for CI/CD (No Static Credentials)

```yaml
# GitHub Actions: use OIDC token to authenticate to Azure without secrets
- name: Azure Login (OIDC)
  uses: azure/login@v1
  with:
    client-id: ${{ vars.AZURE_CLIENT_ID }}
    tenant-id: ${{ vars.AZURE_TENANT_ID }}
    subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
    # No AZURE_CLIENT_SECRET needed — GitHub provides a short-lived OIDC token
```

For OCP/ARO: use the Azure AD federated identity credential feature. GitHub Actions OIDC token exchanges for an Azure AD token, which then authenticates to ARO.

---

## 9. Supply Chain Security

### SBOM (Software Bill of Materials)

```bash
# Generate SBOM with Syft
syft my-app:sha-abc123 -o spdx-json > sbom.json

# Attach SBOM to image as an OCI artifact (Cosign)
cosign attach sbom --sbom sbom.json my-app:sha-abc123

# Verify SBOM and check for vulnerabilities (Grype)
grype sbom:sbom.json --fail-on critical
```

**Why SBOM matters**: In 2024+, regulated industries (financial services, government) require SBOMs for software procurement. If you deploy open-source software to a regulated environment, you need to know every library it contains and whether any have known CVEs.

### In-Toto Attestations

in-toto provides a framework for generating and verifying provenance:
- "This image was built by this exact CI pipeline from this exact Git commit"
- "SAST scan passed at commit X"
- "Image signing key is from the approved set"

Sigstore's `slsa-verifier` checks SLSA (Supply-chain Levels for Software Artifacts) provenance — increasingly required for regulated environments.

---

## 10. Scenario-Based Interview Questions

**Q: Your CI pipeline fails because Trivy found a CRITICAL CVE in the base image. How do you handle it?**

1. **Read the finding**: `trivy image myapp:latest --severity CRITICAL` — identify the CVE ID, the package affected, and the fixed version.
2. **Check if a fix exists**: most CVEs in the Trivy output will have a "Fixed Version" column. If `ignore-unfixed: true` is set and the pipeline still fails, a fixed version is available.
3. **Update the base image**:
   ```dockerfile
   # Before
   FROM python:3.11.4-slim
   # After — patch includes the CVE fix
   FROM python:3.11.9-slim
   ```
4. **Rebuild and rescan**: confirm the CVE is no longer reported.
5. **If no fix available for the base OS** (e.g., libc CVE with no fix): evaluate switching to distroless or Alpine, which have fewer OS packages.
6. **Document exceptions**: if it's a false positive or a CVE that genuinely doesn't affect your application (e.g., CVE in a library feature you don't use), add it to `.trivyignore` with a comment explaining the justification and an expiry date.
7. **Never bypass the pipeline** for CRITICAL CVEs without a documented exception reviewed by the security team.

**Q: A Falcon Sensor pod won't start on OpenShift. You see "Error: container has runAsNonRoot and image will run as root". Debug it.**

This is a classic SCC conflict on OpenShift.

1. `oc describe pod falcon-node-sensor-<hash> -n falcon-system` — check the exact error.
2. Check which SCC the pod is trying to use:
   ```bash
   oc get pod falcon-node-sensor-<hash> -o jsonpath='{.metadata.annotations.openshift\.io/scc}'
   ```
3. The Falcon Node Sensor DaemonSet needs to run as root (UID 0) for kernel-level access. The `restricted-v2` SCC (default in OCP 4.11+) forbids this.
4. Grant the Falcon service account the appropriate SCC:
   ```bash
   oc adm policy add-scc-to-user privileged \
     -z falcon-operator-node-sensor -n falcon-system
   ```
   Or if CrowdStrike provides a custom SCC manifest: apply it, then bind it to the service account.
5. After fixing the SCC, restart the DaemonSet pod: `oc delete pod -l app=falcon-node-sensor -n falcon-system`.
6. Verify: `oc get pods -n falcon-system` — all should be `Running`.

**Q: A cert-manager Certificate is stuck in "Pending" for 10 minutes. How do you debug?**

```bash
# 1. Check the Certificate status
kubectl describe certificate inference-tls -n ml-platform
# Look at: Status.Conditions

# 2. Check the CertificateRequest
kubectl get certificaterequest -n ml-platform
kubectl describe certificaterequest inference-tls-<hash> -n ml-platform
# Look at: Events, Status.Conditions

# 3. Check the Order (if ACME)
kubectl get orders -n ml-platform
kubectl describe order inference-tls-<hash> -n ml-platform

# 4. Check cert-manager controller logs
kubectl logs -n cert-manager deployment/cert-manager | tail -50
```

Common causes:
- **Vault issue**: cert-manager service account doesn't have the Vault policy to sign. Check Vault audit logs.
- **DNS validation failure (ACME)**: the ACME challenge DNS record wasn't created. Check external-dns or route53 credentials.
- **Webhook not reachable**: cert-manager webhook is behind a NetworkPolicy that blocks traffic from kube-apiserver.
- **ClusterIssuer misconfigured**: wrong Vault path or auth method. `kubectl describe clusterissuer vault-pki-issuer`.

**Q: A CyberArk credential wasn't refreshed before its TTL expired. An application threw a database authentication error. What happened and how do you prevent it?**

**What happened**: CyberArk Conjur issued a dynamic database credential with a 1-hour TTL. The application cached the credential at startup and didn't refresh it. After 1 hour, the credential expired in the database, and the next connection attempt failed with "authentication error."

**How to prevent**:
1. **Application-level**: use a database connection pool that re-authenticates on connection failure. Most ORMs support this (SQLAlchemy `pool_pre_ping=True`, HikariCP `connectionTestQuery`).
2. **Vault Agent / Conjur sidecar**: use the sidecar pattern — the sidecar refreshes the credential in `/conjur/secrets/` before it expires, and the application reads from the file on every connection (not caching in memory).
3. **Set TTL generously + renew early**: Conjur/Vault leases have a `renew_before` concept — renew at 80% of TTL, not 100%.
4. **Alert on credential age**: add a Prometheus metric that tracks how old the current credential is. Alert if approaching TTL without refresh.
5. **Test TTL expiry in staging**: explicitly let the credential expire in a staging environment and verify the application recovers gracefully.

**Q: How do you implement a "no secrets in Git" policy across 250+ repositories?**

1. **Preventive**: deploy GitLeaks as a GitHub Actions workflow and a pre-commit hook:
   ```yaml
   - name: GitLeaks Secret Scan
     uses: gitleaks/gitleaks-action@v2
     env:
       GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
   ```
   GitLeaks runs on every PR and blocks merge if a secret pattern is detected (API keys, passwords, tokens matching known patterns).
2. **Detective**: GitHub Advanced Security "Secret Scanning" — scans all repos including commit history. Free for public repos, paid for private.
3. **Education**: document what to do when a secret is accidentally committed: immediately rotate the secret (assume it's compromised), then `git filter-branch` or BFG Repo Cleaner to remove from history, then force-push.
4. **Organisation-level policy**: GitHub organisation setting: require secret scanning on all repos. New repos automatically get secret scanning enabled.
5. **Audit**: weekly report from `gh api /orgs/myorg/secret-scanning/alerts` to track open alerts.

**Q: What is the difference between OPA Gatekeeper and Kyverno? When do you choose each?**

| | OPA Gatekeeper | Kyverno |
|---|---|---|
| Policy language | Rego (general-purpose, powerful) | YAML patterns (intuitive, limited) |
| Learning curve | Steep (Rego is a new language) | Low (YAML-native) |
| Complex logic | Yes (joins, comprehensions, imports) | Limited |
| Mutation | Via external data / side effects | Native, clean API |
| Generate resources | No | Yes (generate Kubernetes resources) |
| Testing | `conftest` (separate tool) | `kyverno test` built-in |
| Performance | Slower (Rego evaluation) | Faster (simple pattern matching) |

**Choose Gatekeeper when**: you need complex cross-resource validation, reuse of Rego policies across teams, or integration with OPA policy library (many pre-built policies).
**Choose Kyverno when**: your team is YAML-native and doesn't want to learn Rego, you need policy mutation (auto-adding labels/limits), or you're generating resources (auto-creating NetworkPolicies per namespace).

At Voya: Kyverno for standard guardrails (resource limits, labels, probe requirements). Gatekeeper would be overkill for those use cases.
