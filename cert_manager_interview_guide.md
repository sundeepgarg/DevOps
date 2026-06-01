# cert-manager Interview Guide

**Target Role:** Principal Platform Engineer / SRE / OpenShift Architect
**Background:** cert-manager deployed on OpenShift with Vault PKI and Let's Encrypt at Voya

---

## 1. What is cert-manager?

cert-manager is a Kubernetes-native X.509 certificate controller. It automates:
- Issuing TLS certificates from multiple sources (ACME/Let's Encrypt, Vault, AWS ACM, self-signed, custom CAs)
- Renewing certificates before they expire (default: 30 days before expiry)
- Storing certificates as Kubernetes Secrets
- Injecting CA bundles into pods and webhooks (via cainjector)

**Without cert-manager:**
```
Manual process:
  openssl genrsa -out tls.key 2048
  openssl req -new -key tls.key -out tls.csr
  Send CSR to CA → wait → get cert
  kubectl create secret tls my-cert --cert=tls.crt --key=tls.key
  Set calendar reminder to renew in 90 days
  Repeat for every service, every cluster, every environment

Problems:
  - Humans forget to renew → outage
  - No consistency across teams
  - No audit trail
  - Manual is unscalable (100+ certs in large platform)
```

**With cert-manager:**
```yaml
# Declare what you need → cert-manager handles everything
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-tls
spec:
  secretName: api-tls-secret
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - api.example.com
# cert-manager: issues, stores, watches, renews automatically
```

---

## 2. Architecture

```
                        Kubernetes API Server
                               │
              ┌────────────────┼────────────────┐
              │                │                │
     ┌────────▼────────┐  ┌────▼────┐  ┌───────▼────────┐
     │  cert-manager   │  │ webhook │  │  cainjector    │
     │  controller     │  │ server  │  │                │
     │                 │  │         │  │                │
     │  Watches CRDs:  │  │ Validates│  │ Injects CA     │
     │  Certificate    │  │ CRD      │  │ bundles into:  │
     │  Issuer         │  │ creation │  │ - ValidatingWebhooks
     │  ClusterIssuer  │  │          │  │ - MutatingWebhooks
     │  CertRequest    │  └─────────┘  │ - CRDs         │
     │  Order          │               └───────────────-─┘
     │  Challenge      │
     └────────┬────────┘
              │ talks to
     ┌────────▼────────────────────────────┐
     │           External Issuers           │
     │  ACME (Let's Encrypt, ZeroSSL)      │
     │  Vault PKI                           │
     │  AWS ACM PCA                         │
     │  Venafi                              │
     │  Self-Signed                         │
     │  CA (internal CA from a Secret)      │
     └──────────────────────────────────────┘
```

### cert-manager Controller

The main control loop. Watches Certificate, Issuer, ClusterIssuer, CertificateRequest CRDs.
When a Certificate object is created/updated:
1. Reads the spec (issuer reference, DNS names, duration, etc.)
2. Creates a CertificateRequest → sends to Issuer
3. Issuer signs and returns the certificate
4. Controller stores cert + key in the named Kubernetes Secret
5. Watches expiry — triggers renewal when `renewBefore` threshold is reached

### Webhook Server

Validates CRD creation/updates before they're written to etcd.
Prevents invalid Certificate objects (wrong field combinations, missing required fields).
**Must be running** — if webhook pod is down, you cannot create any cert-manager resources.

### cainjector

Reads `cert-manager.io/inject-ca-from` annotations on webhook configurations and CRDs.
Automatically injects the CA bundle so Kubernetes API server trusts the webhook.

```yaml
# cainjector reads this annotation
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  annotations:
    cert-manager.io/inject-ca-from: cert-manager/cert-manager-webhook-ca
  # cainjector automatically populates the caBundle field below:
webhooks:
  - caBundle: <BASE64-CA-CERT>  ← injected automatically
```

---

## 3. Core CRDs

### Issuer and ClusterIssuer

```
Issuer:        Namespace-scoped — only issues certs in the same namespace
ClusterIssuer: Cluster-scoped   — issues certs in ANY namespace

Use ClusterIssuer for: shared infrastructure CAs, Let's Encrypt (used everywhere)
Use Issuer for: team-specific CAs, namespace-isolated PKI

Certificate requesting from a ClusterIssuer:
  issuerRef:
    kind: ClusterIssuer
    name: my-cluster-issuer

Certificate requesting from a namespace Issuer:
  issuerRef:
    kind: Issuer
    name: my-issuer
    # must be in the same namespace as the Certificate
```

### Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-cert
  namespace: production
spec:
  # Where to store the issued cert + key
  secretName: example-tls

  # How long the cert is valid (default: 90 days)
  duration: 2160h  # 90 days

  # Renew when this much time remains (default: 30 days before expiry)
  renewBefore: 720h  # 30 days

  # Subject fields
  subject:
    organizations:
      - Example Corp

  # DNS names on the certificate (SAN)
  dnsNames:
    - example.com
    - www.example.com

  # IP addresses (for internal services)
  ipAddresses:
    - 10.0.0.1

  # URI SANs (for SPIFFE/service mesh)
  uriSANs:
    - spiffe://cluster.local/ns/production/sa/web

  # Which issuer to use
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
    group: cert-manager.io

  # Key type and size
  privateKey:
    algorithm: ECDSA   # or RSA
    size: 256          # ECDSA P-256 (or RSA: 2048, 4096)
    rotationPolicy: Always  # Always generate new key on renewal
```

### CertificateRequest (internal object)

Created automatically by cert-manager when processing a Certificate.
You rarely create these manually. Contains the CSR (Certificate Signing Request).

```yaml
# Created by cert-manager controller, not by user
apiVersion: cert-manager.io/v1
kind: CertificateRequest
metadata:
  name: example-cert-xyz123
spec:
  request: <BASE64-ENCODED-CSR>
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
status:
  conditions:
  - type: Ready
    status: "True"
  certificate: <BASE64-SIGNED-CERT>
```

### Order and Challenge (ACME only)

```
Certificate → CertificateRequest → Order → Challenge(s)

Order:      Represents an ACME order for a certificate from Let's Encrypt
Challenge:  Represents one domain validation challenge (http-01 or dns-01)

For a cert with 3 DNS names:
  1 Order with 3 Challenges (one per domain)
  All challenges must pass before cert is issued
```

---

## 4. Issuer Types

### 4.1 ACME (Let's Encrypt)

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    # Let's Encrypt production server
    server: https://acme-v02.api.letsencrypt.org/directory

    # Your email (for expiry notifications)
    email: admin@example.com

    # Store the ACME account key in this Secret
    privateKeySecretRef:
      name: letsencrypt-prod-key

    solvers:
    # HTTP-01 challenge solver
    - http01:
        ingress:
          class: nginx  # or openshift-default, traefik, etc.

    # DNS-01 challenge solver (for wildcards)
    - dns01:
        route53:
          region: us-east-1
          accessKeyIDSecretRef:
            name: route53-credentials
            key: access-key-id
          secretAccessKeySecretRef:
            name: route53-credentials
            key: secret-access-key
```

**Staging vs Production:**
```
Staging:    https://acme-staging-v02.api.letsencrypt.org/directory
            Rate limits: NONE → use for testing
            Certs: NOT trusted by browsers (fake CA)

Production: https://acme-v02.api.letsencrypt.org/directory
            Rate limits: 50 certs/domain/week, 5 failures/hour
            Certs: Trusted by all browsers

Always test with staging first → switch to production when working.
```

### 4.2 HTTP-01 Challenge (how ACME validates you own the domain)

```
cert-manager needs to prove to Let's Encrypt that you control example.com

HTTP-01 process:
  1. Let's Encrypt gives cert-manager a random token
  2. cert-manager creates a temporary Ingress/Route serving:
     GET http://example.com/.well-known/acme-challenge/<token>
     → returns: <token>.<account-key-thumbprint>
  3. Let's Encrypt HTTP-fetches that URL
  4. If response matches → domain ownership proven → cert issued
  5. cert-manager deletes the temporary Ingress

Requirements:
  - Port 80 must be reachable from the internet
  - DNS must point to your cluster's ingress
  - Cannot issue wildcard certificates (*.example.com)

On OpenShift: use ingress class "openshift-default" or create a dedicated
  ChallengeRoute via the openshift solver
```

### 4.3 DNS-01 Challenge (for wildcards and private clusters)

```
cert-manager creates a DNS TXT record to prove domain ownership

DNS-01 process:
  1. Let's Encrypt gives cert-manager a random token
  2. cert-manager creates DNS TXT record:
     _acme-challenge.example.com → <token-hash>
  3. Let's Encrypt queries DNS for that TXT record
  4. If found → domain proven → cert issued
  5. cert-manager deletes the TXT record

Supported DNS providers:
  Route53, CloudFlare, Azure DNS, Google Cloud DNS,
  DigitalOcean, RFC2136 (bind), Akamai, and 20+ others via webhooks

Advantages over HTTP-01:
  → Works for PRIVATE/airgapped clusters (no public port 80 needed)
  → Supports WILDCARD certificates (*.example.com)
  → Can be solved even before DNS propagates to cluster

Used at Voya: DNS-01 with Route53 for internal certificates
```

### 4.4 Vault PKI Issuer

```yaml
# Vault token-based auth
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-issuer
spec:
  vault:
    # Vault PKI mount path
    path: pki_int/sign/my-role
    server: https://vault.example.com

    # CA bundle for Vault's TLS certificate
    caBundle: <BASE64-VAULT-CA>

    auth:
      # Option 1: Vault token (simple but non-rotating)
      tokenSecretRef:
        name: vault-token
        key: token

      # Option 2: Kubernetes Service Account Auth (recommended)
      kubernetes:
        role: cert-manager-role
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager
```

**Vault PKI setup for cert-manager:**
```bash
# Enable PKI secrets engine
vault secrets enable -path=pki pki
vault secrets tune -max-lease-ttl=87600h pki

# Generate root CA
vault write pki/root/generate/internal \
  common_name="Root CA" \
  ttl=87600h

# Enable intermediate PKI
vault secrets enable -path=pki_int pki
vault secrets tune -max-lease-ttl=43800h pki_int

# Generate intermediate CSR
vault write pki_int/intermediate/generate/internal \
  common_name="Intermediate CA" \
  ttl=43800h

# Sign intermediate with root
vault write pki/root/sign-intermediate csr=@int.csr format=pem_bundle

# Create a role (controls what certs can be issued)
vault write pki_int/roles/my-role \
  allowed_domains="example.com,svc.cluster.local" \
  allow_subdomains=true \
  max_ttl=720h \
  key_type=ec \
  key_bits=256

# Create Kubernetes auth role for cert-manager
vault write auth/kubernetes/role/cert-manager-role \
  bound_service_account_names=cert-manager \
  bound_service_account_namespaces=cert-manager \
  policies=pki-policy \
  ttl=24h
```

### 4.5 Self-Signed Issuer

```yaml
# Issues certs signed by their own private key (no CA)
# Use only for: bootstrapping, internal services, development
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
```

### 4.6 CA Issuer (sign with a cert stored in a Secret)

```yaml
# Uses a CA keypair stored in a Kubernetes Secret
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: internal-ca
spec:
  ca:
    secretName: internal-ca-keypair  # must contain tls.crt, tls.key, ca.crt

# Create the CA Secret first:
kubectl create secret tls internal-ca-keypair \
  --cert=ca.crt \
  --key=ca.key \
  -n cert-manager
```

---

## 5. Ingress / Route Integration

### Kubernetes Ingress (automatic cert via annotation)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  annotations:
    # cert-manager sees this annotation and creates a Certificate automatically
    cert-manager.io/cluster-issuer: letsencrypt-prod
    # or for namespace-scoped Issuer:
    cert-manager.io/issuer: my-issuer
spec:
  tls:
  - hosts:
    - example.com
    secretName: example-tls   # cert-manager creates/maintains this Secret
  rules:
  - host: example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-service
            port:
              number: 80
```

### OpenShift Route (with cert-manager Route annotation)

```yaml
# OpenShift Routes need the openshift-routes integration
# Install: cert-manager-openshift-routes controller separately

apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: web-route
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  host: example.apps.cluster.example.com
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  to:
    kind: Service
    name: web-service
    weight: 100
  port:
    targetPort: 8080
```

---

## 6. Certificate Lifecycle

```
User creates Certificate CR
         │
         ▼
cert-manager checks if Secret exists
         │
    ┌────┴────┐
    │ No      │ Yes — check if renewal needed
    ▼         ▼
  Issue     ┌─────────────────────────────┐
  new cert  │ expires in > renewBefore?   │
    │       │ No → do nothing             │
    │       │ Yes → trigger renewal       │
    │       └─────────────────────────────┘
    │
    ▼
Create CertificateRequest
         │
         ▼
Generate private key
         │
         ▼
Build CSR (Certificate Signing Request)
         │
         ▼
Submit to Issuer (ACME / Vault / CA)
         │
         ▼ (ACME only: solve challenge)
         │
         ▼
Receive signed certificate
         │
         ▼
Store in Kubernetes Secret
  tls.crt = certificate chain
  tls.key = private key
  ca.crt  = CA bundle (if available)
         │
         ▼
Certificate status → Ready=True
         │
         ▼
Watch for renewal (check every ~8 hours)
```

### Certificate Renewal

```
By default: cert-manager renews when 2/3 of certificate lifetime has passed
OR when `renewBefore` threshold is reached (whichever is sooner)

90-day cert with renewBefore=30d:
  Issue time: Day 0
  Renewal trigger: Day 60 (30 days before expiry)
  New cert issued: Day 60 (in background, no downtime)
  Old cert still valid until: Day 90

Private key rotation: controlled by privateKey.rotationPolicy
  Never:  reuse the same private key on renewal (default)
  Always: generate a new private key on every renewal (more secure)
```

---

## 7. Inspecting Certificates

```bash
# List all Certificates in all namespaces
kubectl get certificate -A

# Check if a certificate is ready
kubectl get certificate example-cert -n production
# NAME          READY   SECRET       AGE
# example-cert  True    example-tls  2d

# Describe for full details and events
kubectl describe certificate example-cert -n production
# Shows: Conditions, Events, renewal time, issuer reference

# Check the actual TLS secret
kubectl get secret example-tls -n production -o yaml

# Decode and inspect the certificate
kubectl get secret example-tls -n production \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Check expiry specifically
kubectl get secret example-tls -n production \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -enddate

# Check all Orders (ACME)
kubectl get order -A

# Check all Challenges (ACME)
kubectl get challenge -A
# If a challenge is stuck: describe it for the error
kubectl describe challenge <name> -n <namespace>

# Check CertificateRequests
kubectl get certificaterequest -A
```

---

## 8. Common Issues and Debugging

### Challenge Stuck / Pending

```
Symptom: Certificate stays NotReady, Challenge in Pending state

Causes:
  HTTP-01: Port 80 not reachable from internet
           Wrong ingress class
           Ingress controller not handling .well-known path
           DNS not pointing to cluster

  DNS-01:  Wrong AWS/CloudFlare credentials
           IAM permissions missing for Route53
           TXT record propagation delay (up to 10 min)
           Wrong hosted zone ID

Debug:
  kubectl describe challenge <name> -n <namespace>
  # Check "Reason" field in status
  # Check events for specific errors

  # For HTTP-01: manually test the challenge URL
  curl http://example.com/.well-known/acme-challenge/<token>

  # For DNS-01: check if TXT record was created
  dig TXT _acme-challenge.example.com
```

### Certificate Not Renewing

```
Symptom: Certificate expired or close to expiry, not renewing

Check:
  kubectl describe certificate <name>
  # Look for: "Failed to renew" events

Common causes:
  - cert-manager controller pod is down
  - Issuer credentials expired (Vault token, Route53 API key)
  - Rate limit hit (Let's Encrypt: 5 failures/account/hour)
  - Certificate object deleted and recreated (cert-manager loses track)

Force manual renewal:
  kubectl annotate certificate <name> \
    cert-manager.io/renew-before-expiry="99h"
  # or delete the CertificateRequest to trigger re-issue
  kubectl delete certificaterequest <name>-<hash>
```

### Wrong Certificate in Secret

```
Symptom: Secret has old or wrong cert

Debug:
  # Check when the secret was last updated
  kubectl get secret <name> -o jsonpath='{.metadata.resourceVersion}'

  # Force cert-manager to re-check and re-issue
  kubectl delete secret <secretName>
  # cert-manager will detect missing secret and re-issue immediately
```

### Webhook Errors

```
Symptom: "Error from server (InternalError): error when creating Certificate"

Cause: cert-manager webhook pod not running or not ready

Check:
  kubectl get pods -n cert-manager
  kubectl logs -n cert-manager deploy/cert-manager-webhook

Fix: Ensure webhook pod is running. If cluster is bootstrapping,
     there's a chicken-and-egg problem — cert-manager's own webhook
     needs a cert to start. Use --dry-run or wait for initial install.
```

---

## 9. cert-manager on OpenShift

### SecurityContextConstraints (SCCs)

cert-manager pods need specific SCCs on OpenShift:

```yaml
# cert-manager needs: restricted or restricted-v2 SCC
# cainjector may need elevated permissions for webhook injection

# Check SCC assigned
oc get pod -n cert-manager cert-manager-xxx -o yaml | grep scc

# If pods are failing with SCC errors:
oc adm policy add-scc-to-user restricted \
  -z cert-manager -n cert-manager
```

### OpenShift Routes vs Ingress

OpenShift does not use standard Kubernetes Ingress by default (uses Routes).
Two options:

**Option 1:** Enable Kubernetes Ingress on OpenShift
```
OpenShift 4.x automatically creates Routes from Ingress objects
Annotation: cert-manager.io/cluster-issuer works on Ingress objects
```

**Option 2:** Install cert-manager-openshift-routes
```bash
# Separate controller that handles Route annotations
helm install cert-manager-openshift-routes \
  cert-manager/cert-manager-openshift-routes \
  -n cert-manager
```

### Cert-manager Operator on OpenShift (Red Hat supported)

```yaml
# Install via OperatorHub
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  channel: stable-v1
  name: cert-manager
  source: redhat-operators
  sourceNamespace: openshift-marketplace
```

Red Hat's cert-manager operator is production-supported and integrates with
OpenShift's OLM (Operator Lifecycle Manager).

---

## 10. cert-manager with Service Mesh (Istio/Maistra mTLS)

```yaml
# Issue certificates for Istio SPIFFE identity
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istiod-cert
  namespace: istio-system
spec:
  secretName: istiod-tls
  duration: 720h
  renewBefore: 24h
  isCA: false
  privateKey:
    algorithm: ECDSA
    size: 256
    rotationPolicy: Always
  uriSANs:
    - spiffe://cluster.local/ns/istio-system/sa/istiod
  dnsNames:
    - istiod.istio-system.svc
    - istiod.istio-system.svc.cluster.local
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
```

---

## 11. Interview Questions

### Q: What happens when a Certificate object is created in cert-manager?

1. cert-manager controller watches for Certificate objects via Kubernetes informers.
2. On creation, it checks if the referenced Secret already exists and is valid.
3. If not, it creates a CertificateRequest containing a CSR (Certificate Signing Request).
4. The CertificateRequest is sent to the referenced Issuer or ClusterIssuer.
5. For ACME: cert-manager creates an Order, then Challenge(s) to prove domain ownership.
6. Once challenges pass (or for non-ACME issuers immediately), the signed certificate is returned.
7. cert-manager stores `tls.crt` (cert chain), `tls.key` (private key), `ca.crt` (CA bundle) in the named Secret.
8. Certificate status is updated to `Ready=True`.
9. cert-manager watches the certificate expiry — at `renewBefore` threshold, the cycle repeats.

---

### Q: What is the difference between Issuer and ClusterIssuer?

`Issuer` is namespace-scoped — it can only issue certificates for resources in the same namespace.
`ClusterIssuer` is cluster-scoped — it can issue certificates for any namespace in the cluster.

Use `ClusterIssuer` for shared infrastructure (Let's Encrypt, Vault) where multiple teams
across namespaces need certificates from the same CA.

Use `Issuer` for team/namespace isolation — each team manages their own issuer and CA.

---

### Q: HTTP-01 vs DNS-01 challenge — when to use each?

**HTTP-01:** Simpler. Requires port 80 reachable from internet. Cannot issue wildcards.
Good for: public-facing clusters with internet ingress.

**DNS-01:** Requires DNS provider API credentials. Works for private/airgapped clusters.
Supports wildcard certificates (*.example.com). Takes slightly longer (DNS propagation).
Good for: private clusters, wildcard certs, internal PKI, OpenShift on-prem.

At Voya: DNS-01 with Route53 because the cluster is behind a firewall and internal
services need wildcard certs for ease of management.

---

### Q: How does cert-manager renew certificates without downtime?

cert-manager renews certificates before they expire (default: 30 days before).
The renewal process:
1. Generates a new private key (if `rotationPolicy: Always`)
2. Issues new certificate from the same issuer
3. Writes the new cert and key to the existing Secret — atomic update
4. Applications using `volume mounts` pick up the new cert at the next reload
   (Nginx, Envoy watch the mounted files and reload without restarting)
5. Applications using environment variables need a pod restart (cert-manager does NOT do this — you need a tool like Reloader or wave)

**Zero-downtime requirement:** Use cert-manager + Reloader or configure your app to watch
the cert file and reload on change. Envoy/Istio handle this automatically.

---

### Q: How do you handle certificate rotation in a service mesh (Istio)?

Istio manages mTLS certificates for service-to-service traffic via its own `istiod`
certificate authority. The rotation happens automatically:
- `istiod` issues short-lived certs (24h by default) to each sidecar proxy
- Envoy proxy requests cert renewal at 50% of lifetime
- New cert pushed via gRPC SDS (Secret Discovery Service) — no pod restart needed

For the istiod CA certificate itself (which signs all workload certs):
- Can use cert-manager to issue the istiod certificate from Vault
- When istiod cert rotates, it automatically re-issues all workload certs

---

### Q: How would you debug a Certificate that's stuck as NotReady?

```bash
# Step 1: Check Certificate status and events
kubectl describe certificate <name> -n <ns>
# Look for: Last Failure Time, Renewal Time, condition messages

# Step 2: Check CertificateRequest
kubectl get certificaterequest -n <ns>
kubectl describe certificaterequest <name>-<hash> -n <ns>

# Step 3: For ACME, check Order and Challenge
kubectl get order,challenge -n <ns>
kubectl describe challenge <name> -n <ns>
# Error messages are usually specific (DNS not found, port 80 blocked, rate limit)

# Step 4: Check cert-manager controller logs
kubectl logs -n cert-manager deploy/cert-manager -f
# Filter: kubectl logs -n cert-manager deploy/cert-manager | grep <domain>

# Step 5: Check issuer status
kubectl describe clusterissuer <issuer-name>
# Vault issuers: check if Vault token is expired
```

---

## Quick Reference

| Resource | Scope | Created by |
|---|---|---|
| `Issuer` | Namespace | User |
| `ClusterIssuer` | Cluster | User |
| `Certificate` | Namespace | User |
| `CertificateRequest` | Namespace | cert-manager controller |
| `Order` | Namespace | cert-manager (ACME only) |
| `Challenge` | Namespace | cert-manager (ACME only) |

| Issuer type | Use case | Key requirement |
|---|---|---|
| ACME HTTP-01 | Public certs, no wildcard | Port 80 open, DNS pointing to cluster |
| ACME DNS-01 | Wildcards, private clusters | DNS provider API credentials |
| Vault PKI | Enterprise internal PKI | Vault cluster + auth configured |
| CA | Simple internal certs | CA keypair in Kubernetes Secret |
| Self-Signed | Bootstrapping only | Nothing — no trust chain |
