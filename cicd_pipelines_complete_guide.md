# CI/CD Pipelines — Complete Guide

**Covers:** Jenkins (Freestyle / Scripted / Declarative), Azure DevOps (Classic + YAML),
GitHub Actions — syntax, concepts, real examples, and interview Q&A.

---

## 1. CI/CD Core Concepts

### What CI/CD Actually Means

```
CI — Continuous Integration
  Every code commit is automatically:
  - Built (compiled or packaged)
  - Tested (unit, integration, lint, security scan)
  - Validated (quality gates)
  Goal: catch bugs immediately, not at release time

CD — Continuous Delivery
  Every validated build is automatically deployable to any environment
  DEPLOY to production requires a human approval
  Goal: release is always ready, team chooses when to press the button

CD — Continuous Deployment
  Every validated build is automatically deployed to production
  NO human approval step
  Goal: fully automated, multiple deployments per day
  Used by: Netflix, Amazon, Google

Most companies practice Continuous DELIVERY, not Deployment.
```

### Pipeline Stages (the standard pattern)

```
Source         Build          Test           Security       Package        Deploy
──────         ──────         ──────         ──────         ──────         ──────
Code push  →   Compile/   →   Unit tests  →  SAST scan  →  Docker     →   Dev
Git pull       build          Integration    Dependency     build          │
request        npm install    tests          scan           Push to        Staging
               mvn package    Code coverage  Secret scan    registry       │
               pip install    Lint           DAST (after    Helm chart     Prod
                              E2E tests      deploy)        package        (approval)
```

### Key Terminology

```
Pipeline:    The full automation workflow (all stages end-to-end)
Stage:       A logical group of steps (Build, Test, Deploy)
Step/Task:   A single action within a stage (run a command, call an API)
Job:         Unit of execution that runs on an agent/runner
Agent/Runner: The machine that executes pipeline steps
Artifact:    Output of a build step passed to later stages (JAR, Docker image, test reports)
Trigger:     What starts the pipeline (code push, PR, schedule, manual)
Environment: Logical deployment target (dev, staging, production) with optional approvals
Secret:      Sensitive value (passwords, API keys) injected as env vars, not stored in code
```

---

## 2. Jenkins

### 2.1 Freestyle Jobs (Classic — GUI-based)

```
What it is:
  Oldest Jenkins job type. Configured entirely in the Jenkins UI.
  No code/file in your repository defines the pipeline.
  Click-and-configure: Source, Build Triggers, Build Steps, Post-Build Actions.

When you see it in interviews:
  "We have legacy Jenkins jobs" = Freestyle
  Problem: configuration lives in Jenkins (not version controlled)
           Hard to review, test, reproduce
           Cannot express complex logic (conditionals, loops, parallel)

Typical Freestyle config:
  Source: Git repo URL + branch
  Build triggers: Poll SCM (*/5 * * * *), GitHub webhook
  Build step: Execute shell
    #!/bin/bash
    mvn clean package -DskipTests
    docker build -t my-app:${BUILD_NUMBER} .
  Post-build: Archive artifacts (target/*.jar)
              Send email notification
              Trigger another job

Limitations:
  No Pipeline as Code → not in version control
  No parallelism control
  No complex conditionals
  No shared libraries
  → Migrate to Declarative Pipeline
```

### 2.2 Scripted Pipeline

```groovy
// Jenkinsfile (Scripted) — Groovy code, full programming language
// Placed at root of repository

node('linux-agent') {               // run on agent labelled 'linux-agent'

    def imageName = "my-app:${env.BUILD_NUMBER}"

    stage('Checkout') {
        checkout scm               // checks out the triggering commit
    }

    stage('Build') {
        sh 'mvn clean package -DskipTests'
    }

    stage('Unit Tests') {
        try {
            sh 'mvn test'
        } catch (Exception e) {
            currentBuild.result = 'UNSTABLE'  // mark unstable, don't fail
        } finally {
            junit 'target/surefire-reports/*.xml'   // publish test results
        }
    }

    stage('Docker Build') {
        sh "docker build -t ${imageName} ."
        sh "docker tag ${imageName} my-registry/${imageName}"
    }

    stage('Push to Registry') {
        withCredentials([usernamePassword(
            credentialsId: 'registry-creds',
            usernameVariable: 'DOCKER_USER',
            passwordVariable: 'DOCKER_PASS'
        )]) {
            sh "echo $DOCKER_PASS | docker login my-registry -u $DOCKER_USER --password-stdin"
            sh "docker push my-registry/${imageName}"
        }
    }

    stage('Deploy to Dev') {
        if (env.BRANCH_NAME == 'main') {
            sh "helm upgrade --install my-app ./chart \
                --set image.tag=${env.BUILD_NUMBER} \
                --namespace dev"
        } else {
            echo "Skipping deploy — not main branch"
        }
    }
}
```

**Characteristics of Scripted Pipeline:**
```
+ Full Groovy — any logic (loops, functions, try/catch, dynamic variables)
+ Very flexible — anything you can do in Groovy
- Verbose boilerplate (try/catch everywhere for error handling)
- No built-in structure enforcement
- Hard to read for non-Groovy people
- No built-in post-build actions (must use try/finally)
```

### 2.3 Declarative Pipeline (modern standard)

```groovy
// Jenkinsfile (Declarative) — structured syntax, easier to read
// Jenkins validates structure before running

pipeline {
    // WHERE to run
    agent {
        kubernetes {                        // run in a Kubernetes pod
            yaml """
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: maven
    image: maven:3.9-eclipse-temurin-17
    command: ['sleep', 'infinity']
  - name: docker
    image: docker:24-dind
    securityContext:
      privileged: true
"""
        }
    }

    // ENVIRONMENT VARIABLES (available to all stages)
    environment {
        REGISTRY       = 'my-registry.azurecr.io'
        IMAGE_NAME     = 'my-app'
        IMAGE_TAG      = "${BUILD_NUMBER}"
        FULL_IMAGE     = "${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
        SONAR_TOKEN    = credentials('sonar-token')     // inject from Jenkins credentials
    }

    // PARAMETERS (user can override on manual runs)
    parameters {
        string(name: 'DEPLOY_ENV', defaultValue: 'dev', description: 'Target environment')
        booleanParam(name: 'RUN_INTEGRATION_TESTS', defaultValue: true)
        choice(name: 'LOG_LEVEL', choices: ['INFO', 'DEBUG', 'WARN'], description: '')
    }

    // TRIGGERS
    triggers {
        githubPush()                          // trigger on GitHub push
        cron('H 2 * * 1-5')                 // nightly build Mon-Fri at ~2am
        pollSCM('*/5 * * * *')              // poll every 5 min (fallback if webhooks unreliable)
    }

    options {
        timeout(time: 30, unit: 'MINUTES')   // abort if pipeline runs > 30 min
        buildDiscarder(logRotator(numToKeepStr: '20'))  // keep last 20 builds
        timestamps()                          // add timestamps to all log lines
        ansiColor('xterm')                   // colored output in logs
        disableConcurrentBuilds()            // prevent parallel runs of same branch
    }

    stages {

        stage('Checkout') {
            steps {
                checkout scm
                script {
                    // set build display name to branch + commit
                    currentBuild.displayName = "#${BUILD_NUMBER} ${env.BRANCH_NAME}"
                }
            }
        }

        stage('Build') {
            steps {
                container('maven') {         // run in 'maven' container in the pod
                    sh 'mvn clean package -DskipTests -Dmaven.repo.local=/root/.m2'
                }
            }
        }

        stage('Test') {
            parallel {                        // run test types in PARALLEL
                stage('Unit Tests') {
                    steps {
                        container('maven') {
                            sh 'mvn test'
                        }
                    }
                    post {
                        always {
                            junit 'target/surefire-reports/*.xml'
                            jacoco execPattern: 'target/jacoco.exec'   // code coverage
                        }
                    }
                }
                stage('SonarQube Analysis') {
                    steps {
                        container('maven') {
                            sh """
                                mvn sonar:sonar \
                                  -Dsonar.projectKey=my-app \
                                  -Dsonar.host.url=${SONAR_URL} \
                                  -Dsonar.login=${SONAR_TOKEN}
                            """
                        }
                    }
                }
            }
        }

        stage('Docker Build & Push') {
            when {
                anyOf {
                    branch 'main'
                    branch 'release/*'
                    buildingTag()
                }
            }
            steps {
                container('docker') {
                    withCredentials([usernamePassword(
                        credentialsId: 'acr-credentials',
                        usernameVariable: 'ACR_USER',
                        passwordVariable: 'ACR_PASS'
                    )]) {
                        sh """
                            echo \$ACR_PASS | docker login ${REGISTRY} -u \$ACR_USER --password-stdin
                            docker build -t ${FULL_IMAGE} .
                            docker push ${FULL_IMAGE}
                            docker tag ${FULL_IMAGE} ${REGISTRY}/${IMAGE_NAME}:latest
                            docker push ${REGISTRY}/${IMAGE_NAME}:latest
                        """
                    }
                }
            }
        }

        stage('Deploy to Dev') {
            when {
                branch 'main'
            }
            steps {
                container('maven') {
                    withKubeConfig([credentialsId: 'kubeconfig-dev']) {
                        sh """
                            helm upgrade --install my-app ./helm-chart \
                              --namespace dev \
                              --set image.repository=${REGISTRY}/${IMAGE_NAME} \
                              --set image.tag=${IMAGE_TAG} \
                              --wait --timeout 5m
                        """
                    }
                }
            }
        }

        stage('Deploy to Staging') {
            when {
                branch 'main'
            }
            input {                           // pause and wait for human approval
                message "Deploy to Staging?"
                ok "Yes, deploy"
                submitter "qa-team,release-managers"  // only these users can approve
                parameters {
                    string(name: 'CHANGE_TICKET', defaultValue: '', description: 'Jira ticket')
                }
            }
            steps {
                container('maven') {
                    withKubeConfig([credentialsId: 'kubeconfig-staging']) {
                        sh "helm upgrade --install my-app ./helm-chart --namespace staging --set image.tag=${IMAGE_TAG}"
                    }
                }
            }
        }

    }  // end stages

    // POST — runs after all stages regardless of outcome
    post {
        always {
            cleanWs()                          // clean workspace after build
        }
        success {
            slackSend(
                channel: '#deployments',
                color: 'good',
                message: "✅ ${env.JOB_NAME} #${env.BUILD_NUMBER} succeeded — ${env.FULL_IMAGE}"
            )
        }
        failure {
            slackSend(
                channel: '#deployments',
                color: 'danger',
                message: "❌ ${env.JOB_NAME} #${env.BUILD_NUMBER} FAILED — ${env.BUILD_URL}"
            )
            emailext(
                to: 'devops-team@company.com',
                subject: "Build FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER}",
                body: "See: ${env.BUILD_URL}"
            )
        }
        unstable {                             // tests passed but marked unstable
            slackSend(color: 'warning', message: "⚠️ ${env.JOB_NAME} unstable (test failures)")
        }
    }

}  // end pipeline
```

### 2.4 Jenkins Shared Libraries

```
Problem: 50 microservices, each with identical Jenkinsfile (build/test/push/deploy).
Every change (new Sonar version, new deploy step) requires 50 PRs.

Solution: Shared Library — common Groovy code in a central Git repo.

Repository structure (jenkins-shared-library):
  vars/
    buildAndPush.groovy   ← global function, call as: buildAndPush(args)
    deployHelm.groovy     ← call as: deployHelm(args)
    standardPipeline.groovy ← call as: standardPipeline(args)
  src/
    com/company/
      DockerUtils.groovy  ← Groovy class for complex logic
  resources/
    com/company/
      Dockerfile.template ← file resources

# vars/standardPipeline.groovy
def call(Map config) {
    pipeline {
        agent { label config.agentLabel ?: 'linux' }
        environment {
            IMAGE_NAME = config.imageName
            REGISTRY   = config.registry ?: 'my-registry.azurecr.io'
        }
        stages {
            stage('Build')  { steps { sh config.buildCommand ?: 'mvn package' } }
            stage('Test')   { steps { sh config.testCommand  ?: 'mvn test'    } }
            stage('Docker') { steps { buildAndPush(config)                     } }
            stage('Deploy') { steps { deployHelm(config)                       } }
        }
        post { failure { slackSend(channel: '#ci', message: "FAILED: ${JOB_NAME}") } }
    }
}

# Jenkinsfile in each microservice (3 lines!):
@Library('jenkins-shared-library') _
standardPipeline(
    imageName:    'payment-service',
    buildCommand: 'mvn clean package',
    testCommand:  'mvn verify'
)
```

### 2.5 Jenkins Architecture

```
Jenkins Controller (Master):
  - Stores configuration, job definitions, build history
  - Schedules builds to agents
  - Serves the web UI
  - SHOULD NOT run builds directly (CPU/memory starvation)

Jenkins Agents:
  Static agents:   Always-on VMs/nodes registered in Jenkins
  Dynamic agents:  Kubernetes plugin — spins up pods on demand, destroys after build
                   Each build gets fresh, clean environment
                   Pod template defined in Jenkinsfile or globally

  Kubernetes agent (most common in modern Jenkins):
  ┌─────────────────────────────────────────────────────┐
  │  Kubernetes Cluster                                  │
  │                                                      │
  │  ┌──────────────┐   triggers  ┌──────────────────┐  │
  │  │  Jenkins     │ ──────────► │  Build Pod       │  │
  │  │  Controller  │             │  ┌────────────┐  │  │
  │  │  (StatefulSet│             │  │ jnlp       │  │  │
  │  │   1 replica) │             │  │ (agent)    │  │  │
  │  └──────────────┘             │  ├────────────┤  │  │
  │                               │  │ maven/node │  │  │
  │                               │  │ (build)    │  │  │
  │                               │  ├────────────┤  │  │
  │                               │  │ docker/    │  │  │
  │                               │  │ kaniko     │  │  │
  │                               │  └────────────┘  │  │
  │                               └──────────────────┘  │
  └─────────────────────────────────────────────────────┘

JNLP container: the Jenkins agent process that connects back to Controller
Build containers: tools (maven, node, python, helm, kubectl)
```

---

## 3. Azure DevOps Pipelines

### 3.1 Classic (GUI) Pipelines

```
Classic Build Pipeline:
  Configured in Azure DevOps UI → Pipelines → Classic editor
  Drag-and-drop tasks (like Jenkins Freestyle)
  Stored in Azure DevOps, NOT in your repo
  Good for: simple builds, teams unfamiliar with YAML

Classic Release Pipeline:
  Separate from Classic Build
  Visual stages with approvals between environments
  Artifacts from Build pipeline fed into Release
  Still widely used in enterprises for its approval UI

Limitations (same as Jenkins Freestyle):
  Not version controlled in Git
  Hard to diff changes ("who changed this task last week?")
  Cannot easily reuse across projects
  → Microsoft recommends migrating to YAML pipelines
```

### 3.2 Azure DevOps YAML Pipeline — Full Syntax

```yaml
# azure-pipelines.yml — placed at repo root

# TRIGGERS
trigger:
  branches:
    include:
      - main
      - release/*
  paths:
    exclude:
      - docs/*
      - '*.md'

pr:
  branches:
    include:
      - main
  paths:
    exclude:
      - docs/*

# SCHEDULE (cron)
schedules:
  - cron: "0 2 * * Mon-Fri"
    displayName: Nightly build
    branches:
      include:
        - main
    always: true     # run even if no code changes

# VARIABLES
variables:
  # Inline variables
  imageName: 'my-app'
  registry: 'myregistry.azurecr.io'
  # Variable group (Azure DevOps Library — shared across pipelines)
  - group: production-secrets        # contains: ACR_PASSWORD, KUBECONFIG, etc.
  # Conditionally set variable
  - name: deployEnvironment
    ${{ if eq(variables['Build.SourceBranch'], 'refs/heads/main') }}:
      value: production
    ${{ else }}:
      value: staging

# PIPELINE-LEVEL PARAMETERS (user can override at queue time)
parameters:
  - name: runIntegrationTests
    type: boolean
    default: true
  - name: targetEnvironment
    type: string
    default: dev
    values:
      - dev
      - staging
      - production

# ── STAGES ────────────────────────────────────────────────────────────────────

stages:

# ── STAGE 1: Build & Test ─────────────────────────────────────────────────────
- stage: BuildTest
  displayName: Build and Test
  jobs:

  - job: Build
    displayName: Build Application
    pool:
      vmImage: ubuntu-latest          # Microsoft-hosted agent
      # OR use self-hosted:
      # name: my-agent-pool           # self-hosted agent pool

    steps:
    - task: UseNode@1
      inputs:
        version: '20.x'

    - script: npm ci
      displayName: Install dependencies

    - script: npm run build
      displayName: Build

    - script: npm test -- --coverage
      displayName: Unit tests

    - task: PublishTestResults@2       # publish test results to Azure DevOps
      condition: always()              # run even if tests fail
      inputs:
        testResultsFormat: JUnit
        testResultsFiles: '**/junit.xml'
        mergeTestResults: true

    - task: PublishCodeCoverageResults@1
      inputs:
        codeCoverageTool: Cobertura
        summaryFileLocation: coverage/cobertura-coverage.xml

    - task: SonarCloudPrepare@1
      inputs:
        SonarCloud: 'SonarCloud-ServiceConnection'
        organization: 'my-org'
        projectKey: 'my-app'

    - task: SonarCloudPublish@1
      inputs:
        pollingTimeoutSec: 300

    # Publish artifact for later stages
    - task: PublishBuildArtifacts@1
      inputs:
        pathToPublish: dist/
        artifactName: build-output

  - job: SecurityScan
    displayName: SAST Security Scan
    pool:
      vmImage: ubuntu-latest
    steps:
    - task: SnykSecurityScan@1
      inputs:
        serviceConnectionEndpoint: 'Snyk'
        testType: app
        severityThreshold: high
        failOnIssues: true

# ── STAGE 2: Docker Build & Push ─────────────────────────────────────────────
- stage: Docker
  displayName: Build and Push Docker Image
  dependsOn: BuildTest
  condition: succeeded()

  jobs:
  - job: DockerBuildPush
    pool:
      vmImage: ubuntu-latest
    steps:

    - task: DownloadBuildArtifacts@1
      inputs:
        artifactName: build-output
        downloadPath: dist/

    - task: Docker@2
      displayName: Login to ACR
      inputs:
        command: login
        containerRegistry: 'ACR-ServiceConnection'  # service connection in ADO

    - task: Docker@2
      displayName: Build and push
      inputs:
        command: buildAndPush
        repository: $(imageName)
        dockerfile: Dockerfile
        containerRegistry: 'ACR-ServiceConnection'
        tags: |
          $(Build.BuildId)
          $(Build.SourceBranchName)-latest
          latest

    - script: |
        echo "##vso[task.setvariable variable=imageTag;isOutput=true]$(Build.BuildId)"
      name: setTag              # name required for isOutput variables
      displayName: Set image tag output

# ── STAGE 3: Deploy Dev ───────────────────────────────────────────────────────
- stage: DeployDev
  displayName: Deploy to Dev
  dependsOn: Docker
  condition: and(succeeded(), eq(variables['Build.SourceBranch'], 'refs/heads/main'))

  jobs:
  - deployment: DeployToDev         # 'deployment' job (not 'job') for environments
    displayName: Deploy to Dev
    environment: dev                # tracks deployments, optional approvals
    strategy:
      runOnce:
        deploy:
          steps:
          - task: HelmDeploy@0
            inputs:
              connectionType: Kubernetes Service Connection
              kubernetesServiceConnection: 'k8s-dev'
              namespace: my-app-dev
              command: upgrade
              chartType: FilePath
              chartPath: ./helm-chart
              releaseName: my-app
              overrideValues: 'image.repository=$(registry)/$(imageName),image.tag=$(Build.BuildId)'
              install: true
              waitForExecution: true

# ── STAGE 4: Deploy Staging (with approval) ──────────────────────────────────
- stage: DeployStaging
  displayName: Deploy to Staging
  dependsOn: DeployDev
  condition: succeeded()

  jobs:
  - deployment: DeployToStaging
    environment: staging            # has approval configured in ADO Environments UI
    strategy:
      runOnce:
        deploy:
          steps:
          - task: HelmDeploy@0
            inputs:
              kubernetesServiceConnection: 'k8s-staging'
              namespace: my-app-staging
              command: upgrade
              releaseName: my-app
              overrideValues: 'image.tag=$(Build.BuildId)'

# ── STAGE 5: Deploy Production (with approval + gates) ───────────────────────
- stage: DeployProd
  displayName: Deploy to Production
  dependsOn: DeployStaging
  condition: succeeded()

  jobs:
  - deployment: DeployToProd
    environment: production         # requires approval from release-managers group
    strategy:
      canary:                       # canary deployment strategy
        increments: [10, 50]        # 10% → wait → 50% → wait → 100%
        preDeploy:
          steps:
          - script: echo "Pre-deploy checks"
        deploy:
          steps:
          - task: HelmDeploy@0
            inputs:
              kubernetesServiceConnection: 'k8s-prod'
              namespace: my-app-prod
              overrideValues: 'image.tag=$(Build.BuildId)'
        postRouteTraffic:
          steps:
          - script: |
              # smoke test after traffic shift
              curl -f https://my-app.prod.example.com/health
        on:
          failure:
            steps:
            - task: HelmDeploy@0
              inputs:
                command: rollback
                releaseName: my-app
```

### 3.3 Azure DevOps Templates (reusability)

```yaml
# templates/build-steps.yml — shared template file
parameters:
  - name: nodeVersion
    type: string
    default: '20.x'
  - name: runTests
    type: boolean
    default: true

steps:
- task: UseNode@1
  inputs:
    version: ${{ parameters.nodeVersion }}

- script: npm ci
  displayName: Install dependencies

- script: npm run build
  displayName: Build

- ${{ if eq(parameters.runTests, true) }}:   # conditional template step
  - script: npm test
    displayName: Run tests

---
# templates/deploy-job.yml
parameters:
  - name: environment
    type: string
  - name: kubernetesConnection
    type: string
  - name: imageTag
    type: string

jobs:
- deployment: Deploy_${{ parameters.environment }}
  environment: ${{ parameters.environment }}
  strategy:
    runOnce:
      deploy:
        steps:
        - task: HelmDeploy@0
          inputs:
            kubernetesServiceConnection: ${{ parameters.kubernetesConnection }}
            overrideValues: 'image.tag=${{ parameters.imageTag }}'

---
# Main pipeline using templates
stages:
- stage: Build
  jobs:
  - job: Build
    steps:
    - template: templates/build-steps.yml
      parameters:
        nodeVersion: '20.x'
        runTests: true

- stage: DeployDev
  jobs:
  - template: templates/deploy-job.yml
    parameters:
      environment: dev
      kubernetesConnection: k8s-dev
      imageTag: $(Build.BuildId)
```

### 3.4 Service Connections

```
Service Connection = stored credential for connecting to external services.
Configured in: Project Settings → Service Connections.

Types:
  Azure Resource Manager:  authenticate to Azure (subscription/resource group)
  Docker Registry:         authenticate to ACR, Docker Hub, etc.
  Kubernetes:              kubeconfig for a cluster
  GitHub:                  access GitHub repos
  AWS:                     AWS credentials for AWS tasks
  SonarCloud:              SonarCloud authentication

Using in pipeline:
  task: AzureCLI@2
    inputs:
      azureSubscription: 'Production-ServiceConnection'   ← service connection name
      scriptType: bash
      inlineScript: az aks get-credentials ...

Security: grant access to specific pipelines only (not all pipelines in project)
```

---

## 4. GitHub Actions

### 4.1 Core Concepts

```
Workflow:    YAML file in .github/workflows/ — defines the automation
Event:       What triggers the workflow (push, PR, schedule, manual)
Job:         Runs on one runner, has multiple steps
Step:        Single task within a job (run command or use action)
Action:      Reusable step package (actions/checkout, actions/setup-node)
Runner:      Machine that runs jobs (GitHub-hosted or self-hosted)
```

### 4.2 Complete Workflow — Full Syntax

```yaml
# .github/workflows/ci-cd.yml

name: CI/CD Pipeline

# ── TRIGGERS ─────────────────────────────────────────────────────────────────
on:
  push:
    branches: [main, 'release/**']
    paths-ignore:
      - 'docs/**'
      - '**.md'

  pull_request:
    branches: [main]
    types: [opened, synchronize, reopened]

  workflow_dispatch:                   # manual trigger via GitHub UI
    inputs:
      environment:
        description: 'Target environment'
        required: true
        default: dev
        type: choice
        options: [dev, staging, production]
      debug:
        description: 'Enable debug logging'
        type: boolean
        default: false

  schedule:
    - cron: '0 2 * * 1-5'            # nightly Mon-Fri at 2am UTC

# ── PERMISSIONS (OIDC — no static secrets needed) ────────────────────────────
permissions:
  id-token: write        # required for OIDC auth to Azure/AWS
  contents: read
  packages: write        # push to GitHub Container Registry (ghcr.io)
  security-events: write # upload SARIF security scan results

# ── ENVIRONMENT VARIABLES (available to all jobs) ────────────────────────────
env:
  REGISTRY: myregistry.azurecr.io
  IMAGE_NAME: my-app
  NODE_VERSION: '20'

# ── JOBS ─────────────────────────────────────────────────────────────────────
jobs:

  # ── JOB 1: Build ────────────────────────────────────────────────────────────
  build:
    name: Build and Test
    runs-on: ubuntu-latest            # GitHub-hosted runner

    # Job-level outputs (passed to downstream jobs)
    outputs:
      image-tag: ${{ steps.set-tag.outputs.tag }}

    steps:
    - name: Checkout code
      uses: actions/checkout@v4
      with:
        fetch-depth: 0               # full history for SonarQube

    - name: Set up Node.js
      uses: actions/setup-node@v4
      with:
        node-version: ${{ env.NODE_VERSION }}
        cache: npm                   # cache ~/.npm based on package-lock.json

    - name: Install dependencies
      run: npm ci

    - name: Build
      run: npm run build

    - name: Run unit tests
      run: npm test -- --coverage --ci

    - name: Upload test coverage
      uses: codecov/codecov-action@v4
      with:
        token: ${{ secrets.CODECOV_TOKEN }}
        files: ./coverage/lcov.info

    - name: SonarCloud scan
      uses: SonarSource/sonarcloud-github-action@v2
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        SONAR_TOKEN:  ${{ secrets.SONAR_TOKEN }}

    - name: Set image tag output
      id: set-tag
      run: echo "tag=${{ github.sha }}" >> $GITHUB_OUTPUT

    - name: Upload build artifact
      uses: actions/upload-artifact@v4
      with:
        name: build-output
        path: dist/
        retention-days: 7

  # ── JOB 2: Security Scan ────────────────────────────────────────────────────
  security:
    name: Security Scan
    runs-on: ubuntu-latest
    needs: []                        # runs in PARALLEL with build

    steps:
    - uses: actions/checkout@v4

    - name: Run Trivy vulnerability scan
      uses: aquasecurity/trivy-action@master
      with:
        scan-type: fs
        scan-ref: .
        format: sarif
        output: trivy-results.sarif
        severity: CRITICAL,HIGH

    - name: Upload Trivy results to GitHub Security tab
      uses: github/codeql-action/upload-sarif@v3
      with:
        sarif_file: trivy-results.sarif

  # ── JOB 3: Docker Build & Push ──────────────────────────────────────────────
  docker:
    name: Build and Push Docker Image
    runs-on: ubuntu-latest
    needs: [build, security]         # wait for both build and security to pass
    if: github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/heads/release/')

    steps:
    - uses: actions/checkout@v4

    - name: Download build artifact
      uses: actions/download-artifact@v4
      with:
        name: build-output
        path: dist/

    # ── Login to Azure with OIDC (no stored secrets) ──────────────────────────
    - name: Login to Azure
      uses: azure/login@v2
      with:
        client-id:       ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

    - name: Login to ACR
      run: az acr login --name myregistry

    # ── Docker layer caching ──────────────────────────────────────────────────
    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Build and push
      uses: docker/build-push-action@v6
      with:
        context: .
        push: true
        tags: |
          ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
          ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
        cache-from: type=gha          # GitHub Actions cache for Docker layers
        cache-to: type=gha,mode=max

  # ── JOB 4: Deploy Dev ────────────────────────────────────────────────────────
  deploy-dev:
    name: Deploy to Dev
    runs-on: ubuntu-latest
    needs: docker
    environment: dev                 # GitHub Environment — optional approvals

    steps:
    - uses: actions/checkout@v4

    - name: Login to Azure
      uses: azure/login@v2
      with:
        client-id:       ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

    - name: Get AKS credentials
      uses: azure/aks-set-context@v3
      with:
        resource-group: my-rg
        cluster-name: my-aks-dev

    - name: Deploy with Helm
      run: |
        helm upgrade --install my-app ./helm-chart \
          --namespace my-app \
          --create-namespace \
          --set image.repository=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }} \
          --set image.tag=${{ github.sha }} \
          --wait --timeout 5m

    - name: Smoke test
      run: |
        kubectl wait --for=condition=ready pod -l app=my-app \
          -n my-app --timeout=120s
        curl -f https://my-app.dev.example.com/health

  # ── JOB 5: Deploy Staging (approval required) ─────────────────────────────
  deploy-staging:
    name: Deploy to Staging
    runs-on: ubuntu-latest
    needs: deploy-dev
    environment:
      name: staging                  # configure reviewers in GitHub Settings
      url: https://my-app.staging.example.com

    steps:
    - uses: actions/checkout@v4
    - uses: azure/login@v2
      with:
        client-id:       ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    - uses: azure/aks-set-context@v3
      with:
        resource-group: my-rg
        cluster-name: my-aks-staging
    - run: |
        helm upgrade --install my-app ./helm-chart \
          --namespace my-app \
          --set image.tag=${{ github.sha }} \
          --wait

  # ── JOB 6: Deploy Production (approval + concurrency control) ─────────────
  deploy-prod:
    name: Deploy to Production
    runs-on: ubuntu-latest
    needs: deploy-staging
    environment:
      name: production
      url: https://my-app.example.com
    concurrency:
      group: production-deployment    # only one production deploy at a time
      cancel-in-progress: false       # don't cancel running deploy if new one triggered

    steps:
    - uses: actions/checkout@v4
    - uses: azure/login@v2
      with:
        client-id:       ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    - uses: azure/aks-set-context@v3
      with:
        resource-group: my-rg
        cluster-name: my-aks-prod
    - run: |
        helm upgrade --install my-app ./helm-chart \
          --namespace my-app \
          --set image.tag=${{ github.sha }} \
          --wait --timeout 10m
```

### 4.3 Reusable Workflows (DRY — Don't Repeat Yourself)

```yaml
# .github/workflows/reusable-deploy.yml — the shared workflow
on:
  workflow_call:                     # this is a reusable workflow
    inputs:
      environment:
        required: true
        type: string
      image-tag:
        required: true
        type: string
      cluster-name:
        required: true
        type: string
    secrets:
      AZURE_CLIENT_ID:
        required: true
      AZURE_TENANT_ID:
        required: true
      AZURE_SUBSCRIPTION_ID:
        required: true

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    steps:
    - uses: actions/checkout@v4
    - uses: azure/login@v2
      with:
        client-id:       ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id:       ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    - run: |
        helm upgrade --install my-app ./helm-chart \
          --set image.tag=${{ inputs.image-tag }}

---
# Calling the reusable workflow (in another file):
jobs:
  deploy-dev:
    uses: ./.github/workflows/reusable-deploy.yml
    with:
      environment: dev
      image-tag: ${{ github.sha }}
      cluster-name: my-aks-dev
    secrets:
      AZURE_CLIENT_ID:       ${{ secrets.AZURE_CLIENT_ID }}
      AZURE_TENANT_ID:       ${{ secrets.AZURE_TENANT_ID }}
      AZURE_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

### 4.4 Matrix Builds

```yaml
# Test across multiple OS, Node versions, or environments in parallel
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
        node: ['18', '20', '22']
        exclude:
          - os: windows-latest
            node: '18'   # don't test Node 18 on Windows
      fail-fast: false    # continue other matrix jobs even if one fails

    runs-on: ${{ matrix.os }}
    steps:
    - uses: actions/setup-node@v4
      with:
        node-version: ${{ matrix.node }}
    - run: npm test

# Build Docker images for multiple platforms
  docker-multi-arch:
    steps:
    - uses: docker/setup-buildx-action@v3
    - uses: docker/build-push-action@v6
      with:
        platforms: linux/amd64,linux/arm64
        push: true
        tags: my-app:latest
```

### 4.5 Self-Hosted Runners — ARC on Kubernetes

```yaml
# Actions Runner Controller — run GitHub Actions on your own Kubernetes cluster
# Required for: private clusters, custom tools, compliance, cost savings at scale

# Install ARC operator
helm install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  -n arc-systems

# Create runner scale set (auto-scales 0 to N runners)
helm install my-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --namespace arc-runners \
  --set githubConfigUrl="https://github.com/myorg" \
  --set githubConfigSecret.github_token="ghp_..." \
  --set minRunners=0 \
  --set maxRunners=10

# Use in workflow:
jobs:
  build:
    runs-on: my-runners       # ← runs on your Kubernetes cluster
    steps:
    - run: echo "Running on self-hosted ARC runner"
```

---

## 5. Secrets Management in Pipelines

### GitHub Actions Secrets

```yaml
# Three levels of secrets:
# Repository:    Settings → Secrets → Actions → Repository secrets
# Environment:   Settings → Environments → <env> → Environment secrets
# Organization:  Used across all repos in the org

# In workflow:
env:
  DB_PASSWORD: ${{ secrets.DB_PASSWORD }}    # from repository secrets
  API_KEY:     ${{ secrets.API_KEY }}        # from environment secrets (if in a job with environment:)

# Security: secrets are masked in logs (show as ***)
# Never print secrets: echo $DB_PASSWORD → shows ***
```

### Jenkins Credentials

```groovy
// Jenkins stores secrets in its own credential store

// Username + Password:
withCredentials([usernamePassword(
    credentialsId: 'my-creds',
    usernameVariable: 'USER',
    passwordVariable: 'PASS'
)]) {
    sh 'curl -u $USER:$PASS https://api.example.com'
}

// Secret text:
withCredentials([string(credentialsId: 'api-key', variable: 'API_KEY')]) {
    sh 'curl -H "Authorization: Bearer $API_KEY" https://api.example.com'
}

// File:
withCredentials([file(credentialsId: 'kubeconfig', variable: 'KUBECONFIG_FILE')]) {
    sh 'kubectl --kubeconfig=$KUBECONFIG_FILE get pods'
}

// SSH key:
withCredentials([sshUserPrivateKey(
    credentialsId: 'deploy-key',
    keyFileVariable: 'SSH_KEY'
)]) {
    sh 'ssh -i $SSH_KEY user@server deploy.sh'
}
```

### Vault Integration (enterprise secret management)

```yaml
# GitHub Actions — HashiCorp Vault Action
- name: Import secrets from Vault
  uses: hashicorp/vault-action@v3
  with:
    url: https://vault.example.com
    method: jwt
    path: jwt                        # JWT auth using OIDC token
    role: github-actions
    secrets: |
      secret/data/production/db password | DB_PASSWORD ;
      secret/data/production/api key     | API_KEY

# Secrets are now available as env vars: $DB_PASSWORD, $API_KEY
```

---

## 6. Pipeline Optimisation Techniques

### Caching

```yaml
# GitHub Actions — cache node_modules
- uses: actions/cache@v4
  with:
    path: ~/.npm
    key: ${{ runner.os }}-node-${{ hashFiles('**/package-lock.json') }}
    restore-keys: |
      ${{ runner.os }}-node-

# Jenkins — cache Maven .m2 (with Kubernetes agents)
# Mount PVC as the .m2 directory across builds
volumes:
  - name: maven-cache
    persistentVolumeClaim:
      claimName: maven-cache-pvc

# Azure DevOps — cache pip packages
- task: Cache@2
  inputs:
    key: 'pip | "$(Agent.OS)" | requirements.txt'
    restoreKeys: 'pip | "$(Agent.OS)"'
    path: $(PIP_CACHE_DIR)

# Docker layer caching (all platforms)
# Use BuildKit + registry cache or GitHub Actions cache
docker build --cache-from my-app:latest -t my-app:new .
```

### Parallelism

```yaml
# GitHub Actions — parallel jobs
jobs:
  lint:
    runs-on: ubuntu-latest
    steps: ...

  unit-test:
    runs-on: ubuntu-latest
    steps: ...

  security-scan:
    runs-on: ubuntu-latest
    steps: ...

  # All three run in parallel (no 'needs:' relationship)
  # docker only runs after all three pass:
  docker:
    needs: [lint, unit-test, security-scan]

# Jenkins Declarative — parallel stages
stage('Test') {
    parallel {
        stage('Unit')        { steps { sh 'npm test' } }
        stage('Integration') { steps { sh 'npm run test:integration' } }
        stage('Lint')        { steps { sh 'npm run lint' } }
    }
}
```

---

## 7. Comparison Table

| Feature | Jenkins Freestyle | Jenkins Declarative | Azure DevOps YAML | GitHub Actions |
|---|---|---|---|---|
| **Config location** | Jenkins UI | Git repo (Jenkinsfile) | Git repo (yaml) | Git repo (.github/) |
| **Version controlled** | No | Yes | Yes | Yes |
| **Language** | GUI | Groovy DSL | YAML | YAML |
| **Parallelism** | No | Yes (parallel block) | Yes (jobs in stage) | Yes (jobs) |
| **Reusability** | No | Shared Libraries | Templates | Reusable Workflows |
| **Approval gates** | No | input{} block | Environments UI | Environments |
| **Cloud integration** | Plugins | Plugins | Native Azure | Actions marketplace |
| **Self-hosted agents** | Yes | Yes | Yes | Yes (ARC) |
| **OIDC/keyless auth** | No | Limited | Yes (Azure) | Yes (Azure/AWS/GCP) |
| **Free tier** | Self-host only | Self-host only | 1,800 min/month | 2,000 min/month |
| **Best for** | Legacy migration | Enterprise K8s | Azure-centric orgs | GitHub-centric orgs |

---

## 8. Interview Questions

### Q: What is the difference between Scripted and Declarative Jenkins Pipeline?

**Scripted Pipeline:**
- Full Groovy code. Uses `node {}` blocks.
- Maximum flexibility — any Groovy logic (loops, dynamic variables, try/catch).
- More verbose. Error handling is manual (try/finally for post-actions).
- No structural validation before run — syntax errors found at runtime.

**Declarative Pipeline:**
- Structured DSL. Uses `pipeline {}` block with fixed sections (agent, stages, post).
- Jenkins validates structure before execution — catches config errors early.
- Built-in `post {}` block (success/failure/always) without manual try/catch.
- `input {}` block for approval gates built in.
- `parallel {}` block for parallel stages.
- `when {}` conditions for conditional stages.
- Preferred for: new pipelines, team collaboration, readability.

**My preference:** Declarative. Enforced structure means any team member can read and maintain it. For complex dynamic logic, use `script {}` block inside Declarative — best of both worlds.

---

### Q: How do you handle secrets in CI/CD pipelines?

**Never in code/YAML** — plaintext secrets committed to Git are permanent (even if deleted later, git history retains them).

Levels of security (best to worst):

1. **OIDC/Keyless federation (best):** GitHub Actions/Azure DevOps requests short-lived token from identity provider. No stored secret at all. Used for Azure, AWS, GCP authentication.

2. **Secret management tool:** Vault, AWS Secrets Manager, Azure Key Vault. Pipeline fetches secret at runtime. Audit log of every access. Rotation without updating pipelines.

3. **CI/CD platform secrets:** GitHub Secrets, Jenkins Credentials, Azure DevOps variable groups. Encrypted at rest. Masked in logs. Not visible after creation. Acceptable for most secrets.

4. **Environment variables from CI/CD platform:** Same as above but easier to pass to scripts.

5. **Never:** committing .env files, hardcoding API keys in Jenkinsfile, passing secrets as pipeline parameters (parameters are logged).

---

### Q: How do you implement zero-downtime deployment in a pipeline?

**Strategy 1 — Rolling update (Kubernetes):**
```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1          # add 1 extra pod during update
    maxUnavailable: 0    # never reduce below desired count
```
Pipeline: `helm upgrade` → Kubernetes rolls pods one by one → no downtime.

**Strategy 2 — Blue/Green:**
Pipeline deploys new version to Green (inactive). Runs smoke tests. Shifts load balancer traffic from Blue to Green. Blue kept warm for rollback.

**Strategy 3 — Canary:**
Pipeline deploys new version. Shifts 5% traffic. Monitors error rate/latency for 10 min. If healthy, increases to 20% → 50% → 100%. Automated rollback on threshold breach.

**Critical requirements for all strategies:** readiness probes, PodDisruptionBudgets, and `--wait` flag in Helm so pipeline fails fast if deployment is unhealthy.

---

### Q: A developer pushes to main — 47 minutes later, tests fail. How do you fix slow pipelines?

Root causes and fixes:

1. **Missing caching:** `npm ci` downloading 500MB on every run → add `actions/cache` or Maven/npm/pip cache. **Typical saving: 5–10 min.**

2. **Sequential tests that should be parallel:** unit tests, integration tests, linting, security scan all running in sequence → split into parallel jobs/stages. **Typical saving: 15–20 min.**

3. **Docker rebuild from scratch every time:** no layer caching → use BuildKit registry cache or `cache-from: type=gha`. **Typical saving: 5–8 min.**

4. **All tests running on every PR:** run unit tests on PR, run full integration + E2E only on main branch. Filter by file path changes (`paths:` trigger).

5. **Slow test suite:** profile test execution → parallelize tests within the test runner (`pytest -n auto`, `jest --runInBand=false`).

6. **Oversized agent/runner:** downloading 2GB base image on every build → use custom runner with tools pre-installed.

---

### Q: How do you prevent a bad deployment without breaking the pipeline?

**Smoke tests after deploy:**
```bash
# In pipeline, after helm deploy
kubectl wait --for=condition=ready pod -l app=my-app --timeout=120s
curl -f https://my-app.dev.example.com/health || exit 1
```

**Automated rollback on failure:**
```yaml
- name: Deploy
  run: |
    helm upgrade my-app ./chart --set image.tag=${{ github.sha }} --wait
  continue-on-error: false   # pipeline fails if helm fails

- name: Rollback on failure
  if: failure()
  run: helm rollback my-app 0   # 0 = previous revision
```

**Deployment gates (Azure DevOps):**
Pre/post-deployment gates that query: Prometheus error rate, App Insights availability, Azure Monitor alerts. If any gate fails, deployment is auto-rejected.

**Argo Rollouts (Kubernetes-native):**
Progressive delivery with automatic rollback. Define success criteria (error rate < 5%, latency < 200ms). Argo automatically promotes or rolls back.

---

### Q: Jenkins vs GitHub Actions — when do you choose each?

**Choose Jenkins:**
- Existing large Jenkins investment (shared libraries, plugins, hundreds of jobs)
- Complex workflows requiring full Groovy programming logic
- Specific plugins not available in GitHub Actions (legacy tools, proprietary systems)
- On-prem only (air-gapped, no internet access)
- Very large scale (1,000+ concurrent builds) where cost of GitHub Actions hosted runners is prohibitive

**Choose GitHub Actions:**
- New greenfield projects — zero setup, runs immediately
- GitHub-centric teams — PRs, security alerts, Dependabot, Deployments UI all integrated
- Cloud workloads (Azure/AWS/GCP) — OIDC integration is native and clean
- Open-source projects — free unlimited minutes on public repos
- Team with YAML skills but not Groovy expertise
- Need marketplace actions (2,000+ available — Sonar, Trivy, Terraform, Helm, etc.)

**At Voya:** Migrated 3,000+ repos from Jenkins to GitHub Actions (ARC on OpenShift). GitHub Actions chosen because: OIDC to Azure (eliminated all stored credentials), ARC enabled self-hosted runners on existing OpenShift cluster, YAML pipeline as code in same repo as application.

---

## Quick Reference

```
Jenkins Declarative structure:
  pipeline {
    agent {}          ← WHERE (node, docker, kubernetes)
    environment {}    ← VARS
    parameters {}     ← USER INPUTS
    triggers {}       ← WHEN (push, schedule, webhook)
    options {}        ← timeout, log rotation, timestamps
    stages {
      stage('name') {
        when {}        ← conditional (branch, expression)
        parallel {}    ← run sub-stages in parallel
        input {}       ← human approval gate
        steps {}       ← actual work
        post {}        ← success/failure/always per stage
      }
    }
    post {}            ← pipeline-level success/failure/always
  }

Azure DevOps YAML structure:
  trigger / pr / schedules
  variables / parameters
  stages:
    stage:
      jobs:
        job:            ← normal job (steps execute sequentially)
          pool:
          steps: [task, script, template]
        deployment:     ← for environments + strategies
          environment:
          strategy: runOnce / canary / rolling

GitHub Actions structure:
  on: (triggers)
  permissions:
  env:
  jobs:
    job-name:
      runs-on:
      needs: []         ← job dependencies
      environment:      ← approval gates
      strategy.matrix:  ← parallel matrix
      steps:
        - uses: action@v
        - run: shell command

Key differences:
  Jenkins:   Groovy, Plugin ecosystem, self-hosted, Shared Libraries
  Azure DevOps: YAML Templates, Environments UI, Service Connections, classic release
  GitHub Actions: Actions marketplace, OIDC native, ARC self-hosted, Reusable Workflows
```
