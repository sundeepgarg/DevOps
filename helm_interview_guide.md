# Senior-Level Helm Interview Guide

**Target Role:** Senior/Lead DevOps Engineer (OpenShift/Kubernetes focus)

Helm is the defacto package manager for Kubernetes. As a senior engineer, you must deeply understand not just the basic commands, but Go templating architecture, application lifecycle management, and how Helm integrates into larger CI/CD paradigms like GitOps.

---

## 1. Core Concepts: Charts & Releases

### What exactly is Helm?
Helm is a package manager for Kubernetes that packages multiple Kubernetes resources into a single logical deployment unit called a **Chart**.

### Key Terminology
- **Chart:** A bundle of information necessary to create an instance of a Kubernetes application (the package itself).
- **Release:** A running instance of a chart in a Kubernetes cluster. You can install the same chart multiple times on the same cluster, and each time Helm creates a unique release.
- **Repository:** The place where published charts can be collected and shared (like Docker Hub is for images, a Helm Repo is for charts).

### What is the structure of a Helm Chart?
A typical chart looks like this:
```text
my-chart/
  Chart.yaml          # Metadata about the chart (version, name, description)
  values.yaml         # Default configuration values for this chart
  charts/             # A directory containing any sub-charts (dependencies)
  templates/          # Directory of Kubernetes manifest templates
  templates/NOTES.txt # Plain text instructions outputted after installation
```

---

## 2. Templates and `values.yaml` Interaction

### How does `values.yaml` inject values into Templates?
Helm uses the **Go Template Language**. When you run `helm install`, the Helm template engine takes the static Kubernetes manifests in the `/templates` directory and parses them, replacing Go template directives (syntax wrapped in `{{ }}`) with actual values provided by `values.yaml`.

For example, in `values.yaml`:
```yaml
replicaCount: 3
image:
  repository: nginx
```

In `templates/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: {{ .Values.replicaCount }}
  template:
    spec:
      containers:
        - name: web
          image: "{{ .Values.image.repository }}"
```
During execution, Helm evaluates `.Values.replicaCount` and replaces it with `3` before pushing the fully hydrated manifest to the Kubernetes API. The `.` at the beginning represents the top-level scope.

---

## 3. Template Methods, Pipelines, and Functions

### What are Template Methods/Functions in Helm?
Helm includes over 60 built-in functions (borrowed heavily from the Sprig library) to manipulate strings, control flow, and format data inside the templates.

**1. Pipelines (`|`)**
Pipelines send the output of one function into another.
Example: `{{ .Values.image.repository | upper | quote }}`
If the value is `nginx`, this renders as `"NGINX"`.

**2. Default Values (`default`)**
Sets a fallback if a value isn’t defined.
Example: `drink: {{ .Values.favoriteDrink | default "tea" }}`

**3. Flow Control (`if/else` and `range`)**
- **If/Else:** Used for conditionally rendering parts of a YAML manifest.
  ```yaml
  {{- if .Values.ingress.enabled }}
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  {{- end }}
  ```
  *(Note: The `-` inside `{{-` strips whitespace/newlines globally, which is critical for valid YAML formatting).*
- **Range (Loops):** Used to loop over a list or map from `values.yaml`.
  ```yaml
  env:
  {{- range $key, $val := .Values.envVars }}
    - name: {{ $key }}
      value: {{ $val | quote }}
  {{- end }}
  ```

---

## 4. Essential Helm Commands

| Command | Usage |
| :--- | :--- |
| `helm create <name>` | Scaffolds a new chart structure automatically. |
| `helm install <release_name> <chart>` | Installs the chart and creates a new release. |
| `helm upgrade <release> <chart>` | Upgrades a release to a new version of a chart. |
| `helm upgrade --install ...` | **Best Practice:** Upgrades the release if it exists, otherwise installs it fresh. Highly favored in CI/CD pipelines. |
| `helm template <chart>` | Renders template configurations locally and prints the raw YAML to stdout without sending it to the cluster. Great for debugging. |
| `helm lint <chart>` | Examines a chart for possible formatting issues. |
| `helm rollback <release> <revision>` | Rolls back a release to a previous revision number. |
| `helm list -A` | Lists all deployed releases across all namespaces. |

---

## 5. Scenario-Based Questions (Senior Level)

### Q1: You have a base Helm chart, but QA, Staging, and Production require vastly different configurations. Do you create 3 different charts?
**Detailed Answer:**
No. The core philosophy of Helm is separation of logic from configuration. We maintain **one** single Chart.
Then, we create environment-specific values files: `values-qa.yaml`, `values-staging.yaml`, `values-prod.yaml`.
During the CD pipeline deployment to Staging, we execute:
`helm upgrade --install my-app ./my-chart -f values-staging.yaml`
This overwrites the baseline `values.yaml` inside the chart with the staging-specific overrides.

### Q2: A deployment just failed in Production. How do you roll it back using Helm?
**Detailed Answer:**
1. First, I identify the revision history by running `helm history my-release`.
2. This lists all revisions and their statuses (e.g., Revision 4: FAILED, Revision 3: SUPERSEDED).
3. I then run `helm rollback my-release 3`. 
Helm natively tracks the exact state of Kubernetes manifests for Revision 3 (stored as Secrets in the cluster namespace) and will re-apply that exact state instantly.

### Q3: How do you handle managing Secrets in a Helm Chart? Hardcoding them in `values.yaml` is insecure.
**Detailed Answer:**
As a Senior Engineer, I never put base64 secrets in `values.yaml` or Git. I use one of these approaches:
1. **Sealed Secrets (Bitnami):** Encrypt the secret offline with a public key and commit the `SealedSecret` custom resource into the Helm chart. A controller inside the cluster decrypts it.
2. **External Secrets Operator (ESO):** Deploy an `ExternalSecret` manifest via Helm. ESO talks to HashiCorp Vault or AWS Secrets Manager, fetches the secure data, and creates the native Kubernetes Secret on the fly. Let Helm deploy the mapping, not the sensitive data.

### Q4: What is an "Umbrella Chart"?
**Detailed Answer:**
An Umbrella Chart is a Helm chart that contains no direct Kubernetes manifests of its own, but instead acts as a wrapper for multiple sub-charts via the `dependencies` block in `Chart.yaml`. 
For example, if deploying a complex microservice architecture requiring a Frontend, Backend, Redis, and PostgreSQL, the Umbrella chart defines these four as dependencies. Running `helm install umbrella-chart` simultaneously installs the entire stack in the correct order.

### Q5: Your `values.yaml` has nested configurations, and you are getting whitespace indentation errors when generating the YAML. How do you dynamically insert a multiline block of text?
**Detailed Answer:**
I use the `toYaml` function combined with the `indent` or `nindent` function.
Example inside the template:
```yaml
resources:
  {{- toYaml .Values.resources | nindent 2 }}
```
This takes the `resources` YAML tree from `values.yaml`, converts it to a string cleanly, and forcibly indents it by 2 spaces, guaranteeing valid YAML in the final rendered Kubernetes manifest.

---

## 6. Advanced Scenario-Based Questions

### Q6: You have a Helm chart that is deployed to both OpenShift and vanilla Kubernetes. OpenShift requires a specific SecurityContextConstraints (SCC). How do you handle this in one chart?

**Detailed Answer:**
Use a conditional template block that renders OpenShift-specific resources only when a flag is set:

In `values.yaml`:
```yaml
openshift:
  enabled: false
```

In `templates/openshift-scc.yaml`:
```yaml
{{- if .Values.openshift.enabled }}
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: {{ include "mychart.fullname" . }}-scc
allowPrivilegedContainer: false
runAsUser:
  type: MustRunAsNonRoot
{{- end }}
```

Deploy to OpenShift: `helm upgrade --install my-app ./chart -f values-openshift.yaml` where `values-openshift.yaml` sets `openshift.enabled: true`.

This keeps one chart, no code duplication, and OpenShift-specific resources are invisible on Kubernetes clusters.

### Q7: Your Helm chart deploys a database migration Job before the main Deployment starts. The Job is flaky — sometimes it fails and leaves the release in a broken state. How do you handle this reliably?

**Detailed Answer:**
Use Helm **hooks** to sequence operations and control failure behavior:

```yaml
# templates/db-migrate-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    "helm.sh/hook": pre-upgrade,pre-install
    "helm.sh/hook-weight": "-5"         # Lower = earlier; run before other pre-hooks
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 3                        # Retry 3 times before marking Job as failed
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: migrate
          image: myapp:{{ .Values.image.tag }}
          command: ["python", "manage.py", "migrate"]
```

Behavior:
- `pre-upgrade,pre-install`: Job runs before any other resources are deployed
- `hook-delete-policy: before-hook-creation,hook-succeeded`: Cleans up old Job on next deploy; keeps failed Job for debugging
- If the Job fails (all retries exhausted), `helm upgrade` rolls back automatically
- `hook-weight` controls ordering when multiple hooks exist

### Q8: How do you version a Helm chart and what should trigger a version bump?

**Detailed Answer:**
`Chart.yaml` has two version fields:
- **`version`**: The chart version (SemVer). Bump when the chart packaging changes — new template, new default, changed hook.
- **`appVersion`**: The version of the application inside the chart. Bump when the application image/binary changes. This is metadata only — does not affect Helm upgrade logic.

```yaml
# Chart.yaml
version: 2.1.0       # Chart packaging version
appVersion: "1.5.3"  # Application version (informational)
```

**Versioning rules (senior practice):**
- **Patch** (`2.1.0 → 2.1.1`): Bug fix in template, no behavioral change for users
- **Minor** (`2.1.0 → 2.2.0`): New optional feature, backwards-compatible new value
- **Major** (`2.1.0 → 3.0.0`): Breaking change — renamed value key, removed template, changed default that affects existing deployments

In CI/CD: bump `appVersion` automatically from the Docker image tag. Bump `version` manually (or via semantic-release based on conventional commits).

### Q9: A Helm release is stuck in "pending-upgrade" state. How do you recover?

**Detailed Answer:**
This happens when a previous `helm upgrade` was interrupted mid-flight (network cut, CI job killed). Helm stores release state as Kubernetes Secrets.

```bash
# 1. Check current release state
helm list --all -n my-namespace | grep my-release
# Shows: my-release  pending-upgrade

# 2. View the release history
helm history my-release -n my-namespace
# REVISION  STATUS           DESCRIPTION
# 1         superseded       Install complete
# 2         pending-upgrade  Upgrade in progress

# 3. Roll back to the last successful revision
helm rollback my-release 1 -n my-namespace

# 4. Verify
helm status my-release -n my-namespace
```

If `helm rollback` also fails (corrupted state), manually delete the pending release Secret:
```bash
kubectl get secrets -n my-namespace | grep my-release
kubectl delete secret sh.helm.release.v1.my-release.v2 -n my-namespace
```
This removes the pending revision from history. Helm will now see the last good state.

### Q10: You are using Helm in a GitOps workflow with ArgoCD. What is the recommended pattern for managing multiple environments?

**Detailed Answer:**
The recommended pattern separates the **chart source** from the **environment config**:

```
├── charts/                     # Git repo 1: Chart source (no environment values)
│   └── myapp/
│       ├── Chart.yaml
│       ├── values.yaml         # Default values only
│       └── templates/

└── gitops/                     # Git repo 2: ArgoCD Application manifests
    ├── dev/
    │   └── myapp-app.yaml      # ArgoCD Application pointing to chart + dev values
    ├── staging/
    │   └── myapp-app.yaml
    └── prod/
        └── myapp-app.yaml
```

**ArgoCD Application with environment values:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp-prod
spec:
  source:
    repoURL: https://github.com/org/charts
    targetRevision: v2.1.0       # Pin chart version
    path: myapp
    helm:
      valueFiles:
        - values-prod.yaml       # In the chart repo, or a separate values repo
  destination:
    server: https://kubernetes.default.svc
    namespace: prod
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Key principle: **never use `targetRevision: HEAD`** in production — always pin to a chart version. Promotions are Git commits changing the `targetRevision`, reviewed via PR.
