# Senior-Level CI/CD & GitHub Actions Interview Guide

**Target Role:** Senior/Lead DevOps Engineer (12+ Years Experience, OpenShift/Kubernetes focus)

At the 12-year experience mark, interviewers expect you to move beyond basic syntax ("How do you write a step?") to architectural design, security, scalability, and overcoming enterprise-level bottlenecks in the SDLC (Software Development Life Cycle). 

---

## 1. Enterprise CI/CD Architecture & Strategy

### Q1: With 12 years in DevOps, how do you design a CI/CD pipeline for a microservices architecture deploying to OpenShift/Kubernetes?
**Detailed Answer:**
In a microservices architecture, the goal is decoupling. I advocate for isolated pipelines per microservice to allow independent, async releases. 
1. **Continuous Integration (CI):** Trigger builds on feature branches/PRs. The CI pipeline compiles code, runs unit/integration tests, runs Static Application Security Testing (SAST/SonarQube), builds an OCI-compliant container image (e.g., using Buildah or Docker), scans the image for vulnerabilities (Trivy/Clair), and pushes it to an enterprise registry (Harbor/Quay.io) tagged with the Git commit SHA.
2. **Continuous Deployment (CD) & GitOps:** At an enterprise scale on OpenShift, I strongly recommend decoupling CI from CD using the **GitOps paradigm**. Tools like **ArgoCD** or **Flux** run inside the OpenShift cluster. Once CI completes, a lightweight pipeline updates the image tag in a separate config repository (Helm charts or Kustomize manifests). ArgoCD detects this drift and automatically syncs the new manifest state to the cluster.
*Why?* This pull-based deployment model enhances security (CI server doesn't need admin access to OpenShift) and makes the Git config repo the single source of truth for disaster recovery.

### Q2: How do you handle zero-downtime deployments and rollbacks in OpenShift?
**Detailed Answer:**
I utilize advanced deployment strategies orchestrating native Kubernetes/OpenShift primitives:
- **Rolling Updates (Default):** OpenShift gradually replaces old pods with new ones using `maxSurge` and `maxUnavailable` parameters. Readiness probes guarantee traffic isn't routed until the new pod is healthy.
- **Blue/Green Deployments:** Spin up the exact new environment alongside the old one. Once tests pass, switch the OpenShift `Route` (ingress) to point from the Blue service to the Green service instantly. 
- **Canary Releases:** Useful for high-risk apps. Route a small percentage of traffic (e.g., 5%) to the new version using OpenShift Route weights, monitor APM metrics (Prometheus/Dynatrace), and gradually scale to 100%.
- **Rollbacks:** Because I preach GitOps, a rollback simply means reverting the commit in the configuration Git repository. ArgoCD instantly detects the revert and synchronizes the OpenShift cluster back to the previous stable state.

---

## 2. Advanced GitHub Actions Scenarios

### Anatomy of a GitHub Actions Workflow
Before diving into advanced scenarios, it's critical to be able to explain the core hierarchy of GitHub Actions during an interview. What exactly *is* a workflow?

**A Workflow** is a configurable automated process that will run one or more jobs. It is defined by a YAML file checked into your repository under `.github/workflows/`. 

The structural hierarchy is:
1. **Events (Triggers):** What starts the workflow? (e.g., a push to the `main` branch, a PR creation, or a cron schedule).
2. **Workflow:** The overarching container for the entire CI/CD process.
3. **Jobs:** A set of steps that execute on the same runner (server). By default, multiple jobs run in parallel, but you can configure them to run sequentially (e.g., Deploy Job depends on Build Job).
4. **Steps:** Individual tasks inside a job. A step can either run a shell terminal command (like `npm run test`) or invoke a pre-built Action (like `actions/checkout@v4`).

*(See the generated `example_github_workflow.yml` file for a practical code example mapping these concepts.)*

---

### Q3: You have 50 microservices needing identical CI logic. How do you implement this in GitHub Actions without code duplication?
**Detailed Answer:**
I would utilize **Reusable Workflows** and **Composite Actions**.
- **Reusable Workflows (`workflow_call`):** I completely centralize the standard CI processes (testing, Docker build, security scans) into a single centralized repository (e.g., `.github-central` repo). The 50 microservice repositories simply call this centralized workflow via `uses: my-org/central-repo/.github/workflows/ci.yml@main`, passing inputs like the Node.js version or the Dockerfile path.
- **Composite Actions:** If I just need to share a specific sequence of *steps* (like setting up AWS credentials and fetching secrets), I write a Composite Action.
*Benefits:* If the security team mandates a new scanning tool, I update the central reusable workflow once, and all 50 microservices instantly inherit the upgrade on their next run.

### Q4: We don't want to store AWS or OpenShift long-lived static credentials (Access Keys/Passwords) as GitHub Secrets. How do you securely authenticate GitHub Actions?
**Detailed Answer:**
I implement **OpenID Connect (OIDC)**. OIDC allows GitHub Actions workflows to request short-lived, automatically rotating access tokens directly from the cloud provider (AWS, GCP) or an identity broker (Vault) without storing *any* static credentials.
1. The cloud provider establishes a trust relationship with GitHub's OIDC provider.
2. The GitHub workflow asks for a JWT (JSON Web Token).
3. The workflow trades this JWT with the cloud provider (like AWS IAM) for temporary STS credentials.
4. The workflow runs, and the token expires immediately afterward. Completely eliminating the risk of leaked permanent keys.

### Q5: Your GitHub Actions pipeline is taking 30 minutes to build and test. How do you optimize and speed it up?
**Detailed Answer:**
Pipeline optimization is critical for developer velocity. 
1. **Caching Dependencies:** Use `actions/cache` or native language caches (e.g., `actions/setup-node` with `cache: 'npm'`) to avoid downloading thousands of internet packages every run.
2. **Docker Layer Caching:** During container builds, use `--cache-from` and `--cache-to` (such as caching to GitHub registry or an S3 bucket) so only modified code layers are rebuilt instead of rebuilding the entire OS image.
3. **Concurrency & Matrix Strategy:** I split heavy test suites into chunks. Using GitHub Action’s `matrix` strategy, I can spin up 5 parallel runner containers to execute 20% of the tests each, theoretically completing tests 5x faster.
4. **Self-hosted Runners:** If compiling requires heavy compute, GitHub's default runners (2 vCPUs) might be choking. I would provision **Autoscaling Self-Hosted Runners** natively inside OpenShift, leveraging large memory/CPU nodes for builds.

---

## 3. Real-World Troubleshooting & Architecture (Scenario Based)

### Q6: A developer manually scales up a deployment in the OpenShift console from 2 to 5 replicas. Your automated pipeline runs later and the deployment scales back down to 2. How do you balance automated CI/CD with manual emergency interventions?
**Detailed Answer:**
This is the classic "Configuration Drift" problem. Since I advocate for GitOps/Declarative infrastructure, the Git repository is the absolute truth.
If a developer scales manually to mitigate an outage, ArgoCD/Flux will immediately flag the cluster as "Out of Sync" because Git says 2, but the cluster says 5.
- If Auto-Sync is ON, ArgoCD will ruthlessly kill the 3 manual pods to match Git.
- **The Solution:** For production, **GitOps Auto-Sync is often disabled**, and alerts are fired for drift. The developer scales via the UI, an alert fires for drift, and the standard operating procedure (SOP) dictates they must subsequently commit the replica change (to 5) into Git so the automated tool recognizes the new baseline. Once the incident is over, they commit a revert back to 2.

### Q7: You are deploying to a highly restricted Private OpenShift Cluster (no ingress from the internet). How does GitHub Actions (a public SaaS) talk to your private cluster?
**Detailed Answer:**
GitHub-hosted runners cannot reach private corporate IP addresses. To bridge this gap, I use one of two architectures:
1. **Self-Hosted GitHub Action Runner Controller (ARC) inside OpenShift:** I deploy ARC into the private OpenShift cluster. The runner opens an outbound long-polling connection *out* to GitHub.com asking for jobs. Since the traffic originates from inside the private network, it clears the firewall. 
2. **Pull-based GitOps (ArgoCD):** GitHub Actions is strictly limited to doing CI: building the image and pushing to our internal corporate registry. It then commits the image tag to our internal Git repository. The private OpenShift cluster, running ArgoCD, constantly pulls/polls that internal Git repo and applies the changes itself. GitHub never touches the cluster.

### Q8: We are managing secrets across Dev, QA, and Prod. How do you secure them in your CI/CD pipelines instead of scattering them as standard GitHub Secrets?
**Detailed Answer:**
For an enterprise-grade solution, I integrate **HashiCorp Vault** (or a cloud equivalent like AWS Secrets Manager).
- Instead of copying API keys into 50 different GitHub repositories, Vault acts as the centralized authority.
- During the GitHub Action run, I use OIDC to authenticate with Vault.
- Vault dynamically generates a short-lived credential specific for that pipeline run, or retrieves the needed secret.
- In OpenShift, I utilize the **External Secrets Operator (ESO)**. ESO lives inside the cluster, authenticates to Vault, pulls the secret, and injects it as a native Kubernetes Secret. This completely removes secrets from the CI/CD pipeline traffic entirely, providing zero-trust security.

---

## 4. Jenkins Advanced Scenarios

### Q9: We have hundreds of Jenkins pipelines using the exact same Maven build and Docker stages. How do you manage this without copy-pasting the Jenkinsfile everywhere?
**Detailed Answer:**
I utilize **Jenkins Shared Libraries** written in Groovy.
- I create a centralized Git repository containing modular logic for building, testing, and deploying.
- In the shared library, I expose a custom pipeline wrapper. For example, `standardJavaPipeline()`.
- Inside the individual microservice `Jenkinsfile`, developers simply invoke that wrapper block and pass parameters.
*This allows the DevOps team to update the core CI/CD functionality (like injecting a new security layer) across hundreds of services by merely committing an update to the shared library.*

### Q10: Our Jenkins Master (Controller) crashes frequently because it runs out of memory executing dozens of concurrent heavy builds. How do you re-architect Jenkins to fix this?
**Detailed Answer:**
The master node should **never** run builds. For enterprise stability:
1. Set the `# of executors` on the Master node to `0`. 
2. **Dynamic Kubernetes Agents:** I integrate Jenkins with the Kubernetes/OpenShift plugin. Whenever a pipeline job triggers, Jenkins spins up a pod on OpenShift as an ephemeral, dynamic agent. The build runs isolated in that pod.
3. Once the build finishes, the agent pod is automatically destroyed.
*Benefits:* This guarantees the Master only focuses on scheduling and UI responsiveness. It natively inherits OpenShift’s horizontal scalability, ensuring infinite compute resource availability for concurrent builds without paying for static VM instances.

### Q11: What are the differences between Declarative and Scripted Pipelines in Jenkins, and which do you prefer?
**Detailed Answer:**
- **Scripted Pipelines:** The older syntax. Built purely on Groovy. It offers immense flexibility and advanced control features, but lacks structured enforcement, easily turning into complex, unreadable logic.
- **Declarative Pipelines:** The modern standard (`pipeline { agent any ... }`). It heavily enforces a structured syntax, built-in post-actions, and readability.
- **Preference:** I exclusively enforce **Declarative Pipelines** across enterprise teams. It's much easier to lint, read, and onboard junior engineers with. I isolate any absolutely required complex Groovy manipulation to a Shared Library that the Declarative pipeline simply calls.

### Q12: How would you migrate a legacy company from Jenkins to GitHub Actions?
**Detailed Answer:**
Migrations require extreme care to prevent SDLC disruption:
1. **Audit & Abstract:** Audit the existing Jenkins Shared Libraries. Eliminate complex bash scripts trapped in Jenkins UI and convert them to modular scripts (`build.sh`) checked into Git first.
2. **Proof of Concept (PoC):** Select one low-risk microservice and replicate its Jenkins UI hooks and `Jenkinsfile` into a `.github/workflows/` file. Evaluate parity.
3. **Dual Running:** Run both GitHub Actions CI and Jenkins CI in parallel on PRs temporarily to ensure tests result in identical success rates.
4. **Evangelism:** Build templates/Reusable Workflows in GitHub so developers see improved agility over Jenkins. Slowly roll this out team by team and formally deprecate the associated Jenkins jobs.
