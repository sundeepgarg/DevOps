# ArgoCD / GitOps Interview Guide

**Target Role:** Senior/Principal Platform Engineer  
**Background:** ArgoCD on OpenShift (Voya), Helm-based GitOps frameworks, 3,000+ repo migration

---

## 1. GitOps Principles

### The Four GitOps Principles (OpenGitOps)

1. **Declarative**: the desired state of the system is expressed declaratively (YAML, Helm values, Kustomize overlays — not imperative scripts)
2. **Versioned and immutable**: desired state is stored in Git. Every change has a commit SHA. `git log` = full audit trail.
3. **Pulled automatically**: software agents (ArgoCD) pull desired state from Git and apply it. No CI system pushes to the cluster.
4. **Continuously reconciled**: the agent continuously compares actual state to desired state and corrects drift.

### GitOps vs Traditional CI/CD

```
Traditional CI/CD (push):
  Developer → Git → CI (build + test) → CI PUSHES to cluster
  Problem: CI system needs cluster credentials. 
           Drift not detected after deployment.

GitOps (pull):
  Developer → Git → CI (build + test) → update image tag in Git
                              ↑
  ArgoCD PULLS from Git → applies to cluster → detects drift → reconciles
  Benefit: cluster credentials never leave the cluster.
           Drift auto-corrected by ArgoCD.
```

---

## 2. ArgoCD Architecture

```
ArgoCD Components:
├── argocd-server           — API server + Web UI (port 443/80)
├── argocd-repo-server      — clones Git repos, renders Helm/Kustomize
├── argocd-application-controller — reconciles Applications (watches cluster + git)
├── argocd-dex-server       — OIDC/OAuth2 identity broker (Azure AD, GitHub)
├── argocd-redis            — caches app state, repo data
└── argocd-notifications    — sends Slack/email/webhook on sync events
```

### How Reconciliation Works

```
Every 3 minutes (default) OR on Git webhook push:
  repo-server clones/fetches the Git repo
  repo-server renders Helm/Kustomize → produces plain YAML manifests
  application-controller compares rendered YAML vs live cluster state
  If diff found: marks app as OutOfSync
  If autoSync enabled: applies the diff via kubectl/kube API
```

---

## 3. Application CRD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ml-inference-platform
  namespace: argocd
spec:
  project: ml-platform          # AppProject for RBAC
  source:
    repoURL: https://github.com/voya/platform-gitops
    targetRevision: HEAD         # or a tag: v2.3.0 (preferred for prod)
    path: apps/ml-inference/overlays/production
    helm:                        # optional Helm-specific config
      valueFiles:
        - values-production.yaml
      parameters:
        - name: image.tag
          value: "sha-abc123"
  destination:
    server: https://kubernetes.default.svc   # in-cluster
    namespace: ml-platform
  syncPolicy:
    automated:
      prune: true          # delete resources removed from Git
      selfHeal: true       # correct manual kubectl changes
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  ignoreDifferences:             # don't alert on these fields changing
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas         # HPA manages this — ignore ArgoCD diff
```

### Health Status Flow

```
Unknown → Missing → OutOfSync → Syncing → Synced
                                           ↓
                                       Healthy / Degraded / Progressing / Suspended
```

Check health: `argocd app get ml-inference-platform` or `oc get application -n argocd`.

---

## 4. ApplicationSet — Multi-Cluster / Multi-Env

ApplicationSet generates multiple `Application` CRs from a template + a generator.

### Cluster Generator (deploy to all clusters)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ml-platform-all-clusters
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            env: production       # only production clusters
  template:
    metadata:
      name: "ml-platform-{{name}}"     # name = cluster name
    spec:
      source:
        repoURL: https://github.com/voya/platform-gitops
        targetRevision: main
        path: "apps/ml-platform/overlays/{{metadata.labels.region}}"
      destination:
        server: "{{server}}"           # each cluster's API server URL
        namespace: ml-platform
      syncPolicy:
        automated:
          selfHeal: true
```

### Matrix Generator (env × region)

```yaml
generators:
  - matrix:
      generators:
        - list:
            elements:
              - env: staging
              - env: production
        - list:
            elements:
              - region: us-east
              - region: eu-west
# Creates 4 Applications: staging/us-east, staging/eu-west, prod/us-east, prod/eu-west
```

### Git Generator (one app per directory)

```yaml
generators:
  - git:
      repoURL: https://github.com/voya/platform-gitops
      revision: HEAD
      directories:
        - path: "teams/*/apps/*"   # creates one Application per matching path
```

---

## 5. Sync Policies

| Policy | Effect | When to Use |
|--------|--------|-------------|
| `automated.prune: true` | Delete cluster resources removed from Git | Always in GitOps — prevents orphan resources |
| `automated.selfHeal: true` | Revert manual `kubectl edit` changes | Prod environments where only Git changes are allowed |
| `syncOptions: PruneLast=true` | Delete resources after creating new ones (not before) | Avoid downtime during Deployment replacement |
| `ignoreDifferences` | Ignore specified field diffs (HPA replicas, webhook caBundle) | Prevent noise on auto-managed fields |
| `retry.limit: 3` | Retry failed syncs with backoff | Transient API errors, webhook admission delays |

### Protecting Production from Auto-Sync

```yaml
# Production: manual sync required (someone must click "Sync" in UI or run argocd app sync)
syncPolicy: {}    # No automated sync

# Staging: fully automated
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

---

## 6. Helm + Kustomize with ArgoCD

### Kustomize Overlay Pattern (most common at Voya)

```
platform-gitops/
├── base/
│   ├── deployment.yaml        # base Deployment with no env-specific values
│   ├── service.yaml
│   └── kustomization.yaml
└── overlays/
    ├── staging/
    │   ├── kustomization.yaml
    │   └── patch-replicas.yaml  # staging: replicas=1
    └── production/
        ├── kustomization.yaml
        └── patch-replicas.yaml  # prod: replicas=3
```

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
bases:
  - ../../base
patchesStrategicMerge:
  - patch-replicas.yaml
images:
  - name: my-app
    newTag: "sha-abc123"       # Updated by CI pipeline after image build
```

### Helm with ArgoCD Best Practice

```yaml
# ArgoCD Application pointing to a Helm chart
source:
  repoURL: https://github.com/voya/helm-charts
  targetRevision: v2.3.0       # ALWAYS pin chart version in prod
  chart: ml-inference           # or path: for local chart
  helm:
    valueFiles:
      - values.yaml
      - values-production.yaml  # overrides for production
    parameters:                 # CI sets this after building image
      - name: image.tag
        value: "sha-abc123"
```

---

## 7. App-of-Apps Pattern

Used when you have many applications to manage as a unit.

```
argocd/
└── root-app.yaml              ← ArgoCD watches this one Application
    └── points to apps/ directory
        ├── ml-platform-app.yaml
        ├── monitoring-app.yaml
        ├── ingress-controller-app.yaml
        └── cert-manager-app.yaml
```

```yaml
# root-app.yaml — the "bootstrap" Application
spec:
  source:
    path: argocd/apps           # directory containing child Application YAMLs
  destination:
    namespace: argocd           # child Applications deployed into ArgoCD namespace
```

**Interview point**: App-of-Apps is a self-managing pattern. Once you apply the root app to ArgoCD,
everything else bootstraps itself from Git. New cluster onboarding = apply one YAML.

---

## 8. ArgoCD RBAC and AppProjects

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ml-platform
  namespace: argocd
spec:
  description: "ML Platform team project"
  sourceRepos:
    - "https://github.com/voya/platform-gitops"   # only allow this repo
  destinations:
    - namespace: ml-platform
      server: https://kubernetes.default.svc
    - namespace: ml-monitoring
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace              # allow creating namespaces
  namespaceResourceWhitelist:
    - group: "apps"
      kind: Deployment
    - group: ""
      kind: Service
    - group: "serving.kserve.io"
      kind: InferenceService
  roles:
    - name: ml-developer
      description: "Read-only access for ML developers"
      policies:
        - p, proj:ml-platform:ml-developer, applications, get, ml-platform/*, allow
        - p, proj:ml-platform:ml-developer, applications, sync, ml-platform/*, allow
      groups:
        - ml-developers            # Azure AD group (via Dex OIDC)
```

---

## 9. ArgoCD on OpenShift

```bash
# Install ArgoCD Operator via OperatorHub (OpenShift GitOps Operator)
# This installs ArgoCD in openshift-gitops namespace

# Access the ArgoCD server via OpenShift Route
oc get route openshift-gitops-server -n openshift-gitops

# Default admin password
oc extract secret/openshift-gitops-cluster -n openshift-gitops --to=-

# ArgoCD server needs read access to all namespaces
# Grant cluster-admin to ArgoCD service account (OpenShift GitOps Operator does this automatically)
oc adm policy add-cluster-role-to-user cluster-admin \
  system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

**SCC for ArgoCD on OpenShift**: ArgoCD application-controller and repo-server run as non-root.
The OpenShift GitOps Operator handles SCC automatically. If using upstream ArgoCD:
```bash
oc adm policy add-scc-to-user nonroot -z argocd-application-controller -n argocd
oc adm policy add-scc-to-user nonroot -z argocd-repo-server -n argocd
```

---

## 10. Drift Detection and Rollback

### Auto-Detection
ArgoCD with `selfHeal: true` detects and corrects drift within seconds of a `kubectl edit`.

Without `selfHeal`: ArgoCD shows the app as `OutOfSync` but doesn't auto-correct.
Use this for critical workloads where you want to approve changes before applying.

### Rollback Strategy in GitOps

```
❌ WRONG: argocd app rollback my-app 5  (rolls back ArgoCD history, not Git)
   This creates divergence between Git and cluster state.

✓ CORRECT: git revert <commit-sha> && git push
   ArgoCD detects the new Git commit, syncs the reverted state.
   Git history shows both the original change AND the revert — full audit trail.
```

```bash
# Emergency: disable auto-sync to freeze the app
argocd app set ml-inference-platform --sync-policy none

# Then investigate, create fix, push to Git
# Re-enable auto-sync
argocd app set ml-inference-platform --sync-policy automated --auto-prune --self-heal
```

---

## 11. Scenario-Based Interview Questions

**Q: Your ArgoCD application shows `OutOfSync` even though you just pushed to the correct Git branch. How do you debug?**

1. Check if ArgoCD detected the new commit: `argocd app get my-app` → look at `Last Sync` timestamp vs your Git push time.
2. If ArgoCD hasn't picked up the commit: it polls every 3 minutes. Force a refresh: `argocd app get my-app --refresh` or click "Refresh" in UI.
3. If webhook is configured but still slow: check ArgoCD's GitHub webhook endpoint (`/api/webhook`) is reachable from GitHub (check VPN/firewall for ARO private cluster).
4. Check the Git repository connection: `argocd repo list` — ensure the repo shows "Successful" connection.
5. If the commit was pushed but the rendered YAML is unchanged (e.g., you changed a comment): ArgoCD compares rendered manifests, not raw YAML. No rendered diff = stays Synced.
6. Check the repo-server logs for rendering errors: `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server`.

**Q: A developer accidentally did `kubectl edit deployment my-app` and changed an environment variable in production. ArgoCD with selfHeal is enabled. What happens?**

With `selfHeal: true`:
1. ArgoCD's application-controller detects the diff within seconds (watches cluster via informers).
2. App transitions to `OutOfSync` briefly.
3. ArgoCD immediately re-applies the Git-version of the Deployment, overwriting the manual change.
4. App returns to `Synced`.
5. The developer's change is lost — that's the point of selfHeal.

For the developer to make a legitimate change: they must push to Git. The PR review process is the gate.

If a temporary change is needed (incident response): temporarily disable selfHeal: `argocd app set my-app --self-heal=false`, make the change, then re-enable and push the proper fix to Git.

**Q: How do you promote a release from staging to production using ArgoCD + ApplicationSet?**

Pattern: separate overlays per environment in Git, each with its own `Application` or `ApplicationSet`.

```
platform-gitops/
├── overlays/staging/    → ArgoCD Application A (watches HEAD of main, staging values)
└── overlays/production/ → ArgoCD Application B (watches tagged releases)
```

Promotion workflow:
1. CI builds image → pushes to registry → updates `image.tag` in staging overlay via `kustomize edit set image`.
2. ArgoCD auto-syncs staging. Engineers verify.
3. For production promotion: create a PR that copies the `image.tag` from staging to production overlay.
4. PR review is the approval gate. On merge, ArgoCD syncs production.
5. Or for Helm charts: PR updates `targetRevision: v2.3.0` in the production Application.

**This pattern ensures**: production only changes when Git changes, and every change to production is reviewed and auditable.

**Q: An ArgoCD sync is failing with "resource already exists and is not managed by ArgoCD". How do you handle it?**

This happens when a resource (e.g., a Service or ConfigMap) was created manually or by another tool before ArgoCD managed it.

Options:
1. **Adopt the resource**: annotate it to tell ArgoCD it owns it:
   ```bash
   kubectl annotate service my-svc \
     argocd.argoproj.io/managed-by=my-app \
     -n my-namespace
   ```
2. **Delete and recreate**: if safe (no data), delete the resource. ArgoCD will recreate it from Git on next sync.
3. **Use `syncOptions: Replace=true`**: ArgoCD will replace (delete + create) the resource instead of applying it. Use carefully for CRDs or resources with immutable fields.

Prevention: label resources with ArgoCD annotations from day one; don't create cluster resources outside of GitOps.

**Q: How do you handle secrets in a GitOps workflow with ArgoCD? You can't store them in Git as plaintext.**

Four approaches:
1. **Sealed Secrets** (Bitnami): encrypt secrets with a cluster-specific key. Store encrypted `SealedSecret` CRs in Git. ArgoCD syncs them; the SealedSecrets controller decrypts in-cluster. Simple, no extra infrastructure.
2. **External Secrets Operator + Vault/Azure Key Vault**: `ExternalSecret` CRs in Git point to secret paths in Vault. ESO fetches and creates Kubernetes Secrets in-cluster. The CRs in Git contain references, not values.
3. **SOPS** (Mozilla): encrypt YAML files at rest in Git using GPG or Age keys. ArgoCD's `argocd-vault-plugin` or Helm secrets plugin decrypts during rendering.
4. **Vault Agent Sidecar**: don't use Kubernetes Secrets at all — Vault Agent injects secrets into pod filesystem at startup. Nothing sensitive ever enters etcd.

At Voya: External Secrets Operator + Azure Key Vault. All secret references in Git, no secrets in etcd except what ESO creates with short TTLs.

**Q: How do you handle CRD upgrades when using ArgoCD? (e.g., upgrading the cert-manager CRDs)**

CRDs are cluster-scoped and require cluster-admin to update. Considerations:
1. **CRDs in a separate ArgoCD Application**: manage CRDs separately from the operator. Upgrade CRDs first, verify, then upgrade the operator. CRD App uses `syncOptions: Replace=true` because CRDs often have immutable schema fields.
2. **Sync wave ordering**: use `argocd.argoproj.io/sync-wave: "-1"` annotation on CRD manifests so they sync before the operator Deployment:
   ```yaml
   metadata:
     annotations:
       argocd.argoproj.io/sync-wave: "-1"
   ```
3. **Avoid CRDs in Helm charts**: Helm CRD upgrades are problematic (Helm doesn't upgrade CRDs on `helm upgrade` by design). Either use a pre-install hook or manage CRDs separately in ArgoCD.
4. **Test in staging**: upgrade CRD in staging cluster first. Verify all existing CRs still validate against the new schema.

**Q: How did you build reusable Helm-based deployment frameworks at Voya?**

The problem: 250+ applications each wrote their own Helm charts, leading to inconsistency in:
- Resource limits/requests (some had none, causing OOM evictions)
- Liveness/readiness probes (some were missing, causing failed rollouts)
- Prometheus annotations for scraping
- PodDisruptionBudgets

Solution: created a "golden path" Helm library chart (`platform-chart`) that all teams use as a base:
```
helm-charts/
├── platform-chart/        # Library chart: common templates
│   ├── templates/
│   │   ├── _deployment.tpl   # standard Deployment with required fields
│   │   ├── _service.tpl
│   │   ├── _hpa.tpl
│   │   └── _pdb.tpl
│   └── values.yaml        # sensible defaults: resources, probes, labels
└── app-chart/             # Application chart wrapping the library
    ├── Chart.yaml          # dependencies: [platform-chart]
    └── values.yaml         # app-specific overrides
```

ArgoCD `AppProject` enforced that all production Applications used charts from the approved `helm-charts` repo at pinned versions. Teams couldn't deploy without the platform chart, ensuring compliance automatically.
