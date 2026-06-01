# CDN — Content Delivery Network Interview Guide

**Covers:** How CDN works, AWS CloudFront, Azure Front Door, Azure CDN Classic,
cache strategies, security, and interview Q&A.

---

## 1. What is a CDN and Why Does It Exist?

### The Problem CDN Solves

```
Without CDN:
  User in Mumbai → request → origin server in us-east-1 (Virginia)
  Round-trip distance: ~14,000 km
  Network latency: 150–250ms (just for the TCP handshake + TLS)
  Every user on the planet hits your single origin server
  Flash sale with 1M concurrent users → origin overloaded

With CDN:
  User in Mumbai → request → CDN edge server in Mumbai (~5km away)
  Latency: 2–5ms
  If content is cached at edge → origin never contacted
  Flash sale with 1M users → CDN absorbs ~90% of traffic, origin sees ~100K
```

### How CDN Works

```
CDN global network:
  PoPs (Points of Presence):  Data centres at 50–400+ locations worldwide
                               Each PoP has edge servers with large SSD caches
  Regional Edge Caches:       Fewer, larger caches between edge PoPs and origin
                               (CloudFront-specific — second-level cache)

Request flow:
  1. User requests: https://cdn.example.com/images/logo.png

  2. DNS resolves cdn.example.com → Anycast IP of nearest PoP
     Anycast: multiple PoPs share the SAME IP
              routers automatically direct traffic to nearest PoP
              no geographic DNS needed

  3. Edge server checks its cache:
     HIT:  Return content directly from edge (sub-5ms)
     MISS: Fetch from origin (or regional edge cache first)
           Cache the response for future requests
           Return content to user

  4. Cache key: usually URL path + optional headers/cookies

  ┌──────────────────────────────────────────────────────────────────────┐
  │                        CDN Global Network                            │
  │                                                                      │
  │  User (Mumbai) ──► Edge PoP (Mumbai)                                │
  │                         │                                            │
  │                         │ cache miss                                 │
  │                         ▼                                            │
  │                    Regional Cache (Singapore)                        │
  │                         │                                            │
  │                         │ cache miss                                 │
  │                         ▼                                            │
  │                    Origin (us-east-1: ALB → EC2/EKS)               │
  └──────────────────────────────────────────────────────────────────────┘
```

### Cache-Control Headers — The Foundation

CDN behaviour is primarily controlled by HTTP response headers from your origin:

```http
# Cache everything for 1 day at CDN and browser
Cache-Control: public, max-age=86400

# Cache at CDN for 1 hour, browser for 5 minutes
Cache-Control: public, s-maxage=3600, max-age=300
  s-maxage: CDN TTL (overrides max-age for shared caches)
  max-age:  Browser TTL

# Never cache (dynamic, user-specific content)
Cache-Control: private, no-store
  private:   only browser can cache, NOT CDN
  no-store:  don't cache anywhere

# Cache but must revalidate when stale
Cache-Control: public, max-age=3600, must-revalidate

# Stale-while-revalidate (serve stale content while fetching fresh)
Cache-Control: public, max-age=600, stale-while-revalidate=86400

ETag: "abc123"                      # unique identifier for content version
Last-Modified: Wed, 01 Jan 2025 00:00:00 GMT

# Vary — cache different versions by header value
Vary: Accept-Encoding              # separate cache for gzip vs br vs none
Vary: Accept-Language              # separate cache per language
# CAUTION: Vary: Cookie → almost always disables caching (too many variants)
```

### What to Cache vs What NOT to Cache

```
Cache (static, shared content):
  ✓ Images, CSS, JavaScript files           → long TTL (1 year + cache busting)
  ✓ Fonts, videos, PDFs                     → long TTL
  ✓ API responses with public, stable data  → short TTL (60-300s)
  ✓ HTML pages for marketing/static sites   → medium TTL (1-24h)

Do NOT cache (dynamic, user-specific):
  ✗ Authenticated API responses             → Cache-Control: private
  ✗ Shopping cart, user preferences         → private
  ✗ Payment pages                           → no-store
  ✗ Admin pages                             → no-store
  ✗ Real-time data (stock prices, chat)     → private

Cache busting strategy for static assets:
  logo.abc123def456.png  ← hash in filename
  main.bundle.1.2.3.js   ← version in filename
  Set TTL = 1 year → when file changes, new URL → new cache entry
```

---

## 2. AWS CloudFront

### CloudFront Architecture

```
Distribution: the top-level CloudFront resource (has a domain: xxxxx.cloudfront.net)
Origins:      backend servers (S3, ALB, API Gateway, custom HTTP)
Behaviors:    rules mapping URL path patterns to origins + cache settings
Edge Locations: 400+ globally (actual CDN servers serving users)
Regional Edge Caches: ~13 globally (second-level cache, larger, slower to evict)

┌─────────────────────────────────────────────────────────────────────────┐
│                     CloudFront Distribution                              │
│                                                                          │
│  Behaviors (ordered, first match wins):                                  │
│    Path: /api/*          → Origin: ALB (no cache, forward all headers)  │
│    Path: /images/*       → Origin: S3  (cache 1 year)                  │
│    Path: /static/*       → Origin: S3  (cache 1 year)                  │
│    Path: * (default)     → Origin: ALB (cache 60s for public pages)    │
│                                                                          │
│  Origins:                                                                │
│    S3 bucket:    my-assets.s3.amazonaws.com                             │
│    ALB:          my-alb-123456.us-east-1.elb.amazonaws.com             │
│    API Gateway:  xxxxx.execute-api.us-east-1.amazonaws.com             │
│    Custom HTTP:  any HTTP/HTTPS endpoint                                │
└─────────────────────────────────────────────────────────────────────────┘
```

### Origins Deep Dive

#### S3 Origin

```
Two ways to connect S3 to CloudFront:

1. S3 Website Endpoint (Legacy):
   Origin: my-bucket.s3-website-us-east-1.amazonaws.com
   Bucket must be public
   Supports redirect rules and custom error pages
   Does NOT support Origin Access Control

2. S3 REST API + Origin Access Control (OAC) — Recommended:
   Origin: my-bucket.s3.amazonaws.com
   Bucket is PRIVATE (not public)
   CloudFront signs requests to S3 using SigV4
   S3 bucket policy only allows CloudFront service principal

   # S3 Bucket Policy (OAC):
   {
     "Statement": [{
       "Effect": "Allow",
       "Principal": {
         "Service": "cloudfront.amazonaws.com"
       },
       "Action": "s3:GetObject",
       "Resource": "arn:aws:s3:::my-bucket/*",
       "Condition": {
         "StringEquals": {
           "AWS:SourceArn": "arn:aws:cloudfront::123456789:distribution/ABCDEFG"
         }
       }
     }]
   }

   Benefit: S3 bucket never needs to be public. CloudFront is the only entry point.
```

#### ALB Origin (Dynamic Content)

```yaml
# CloudFront behavior for API traffic
CacheBehavior:
  PathPattern: /api/*
  TargetOriginId: alb-origin
  CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad  # Managed-CachingDisabled
  OriginRequestPolicyId: b689b0a8-53d0-40ab-baf2-68738e2966ac  # Managed-AllViewer
  AllowedMethods: [GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE]
  ViewerProtocolPolicy: redirect-to-https
  Compress: true

# For APIs:
  CachingDisabled: never cache (each request goes to ALB)
  AllowedMethods: include POST/PUT/DELETE (mutations)
  Forward headers: Host (so ALB knows which application)
                   Authorization (so app gets auth token)
```

### Cache Behaviors and Policies

```
Cache Policy controls:
  TTL: minimum, default, maximum (origin Cache-Control headers override within these bounds)
  Cache key: what makes two requests "the same" for caching purposes
             Default: just the URL path
             Can add: query strings, headers, cookies

  IMPORTANT: Adding cookies/headers to cache key reduces cache hit rate
             Each unique value creates a separate cache entry
             Session cookies in cache key → no caching (every user has different session)

Cache key examples:
  URL only:               /products → one cache entry for all users
  URL + country header:   /products + CloudFront-Viewer-Country → separate per country
  URL + language cookie:  /products + lang=en/fr/de → separate per language
  URL + auth cookie:      /products + session=abc123 → never hits cache (unique per user)

Origin Request Policy controls:
  What to FORWARD to origin (does not affect cache key):
  - Query strings: forward for API, don't forward for static assets
  - Headers: forward Host (always), Authorization (for protected APIs)
  - Cookies: forward session cookie for authenticated pages, not for static

Built-in managed policies:
  CachingOptimized:         TTL 1 day, compress, no cookies/headers
  CachingDisabled:          TTL 0 (all requests go to origin)
  CachingOptimizedForUncompressedObjects: for binary assets
  AllViewerExceptHostHeader: forward everything except Host
```

### Cache Invalidation

```bash
# Invalidate specific paths (takes 10-30 seconds to propagate globally)
aws cloudfront create-invalidation \
  --distribution-id ABCDEFG123456 \
  --paths "/images/logo.png" "/css/*"

# Invalidate everything (use sparingly — costs $0.005 per path, first 1000/month free)
aws cloudfront create-invalidation \
  --distribution-id ABCDEFG123456 \
  --paths "/*"

# Better approach: versioned file names (no invalidation needed)
# Instead of: /main.js       (invalidate when updated)
# Use:        /main.abc123.js (new URL = new cache entry automatically)
```

### Signed URLs and Signed Cookies

```
Use case: private content (paid video streaming, software downloads, user-specific files)

Signed URL:
  One URL grants access to ONE specific file for a limited time
  URL contains: expiry timestamp + signature (signed with CloudFront key pair)
  Use: download links, time-limited access to specific file

  # Python — generate signed URL
  from botocore.signers import CloudFrontSigner
  import rsa, datetime

  def rsa_signer(message):
      private_key = open('cf-private-key.pem', 'rb').read()
      return rsa.sign(message, rsa.PrivateKey.load_pkcs1(private_key), 'SHA-1')

  cf_signer = CloudFrontSigner(key_id='K1234', rsa_signer=rsa_signer)
  signed_url = cf_signer.generate_presigned_url(
      'https://cdn.example.com/video.mp4',
      date_less_than=datetime.datetime.now() + datetime.timedelta(hours=1)
  )

Signed Cookie:
  One cookie grants access to MULTIPLE files matching a path pattern
  User sets cookie once (at login) → access to entire /premium/* section
  Use: paid streaming service (all videos in /premium/*), subscription content
```

### Lambda@Edge vs CloudFront Functions

```
                  Lambda@Edge             CloudFront Functions
──────────────────────────────────────────────────────────────────
Runtime           Node.js 18, Python 3.12  JavaScript (ES5.1)
Trigger points    All 4 (see below)        Viewer req/response only
Max duration      5s (viewer), 30s (origin) 1ms
Max memory        128MB (viewer), 10GB      2MB
Cost              $0.0000001/req + duration $0.0000001/req (cheaper)
Network access    Yes (can call external)   No
File system       No                        No
Deployment        Regional (us-east-1 only) Edge (all PoPs, instant)
Use case          Complex logic, A/B tests  Header manipulation, URL rewrite

Four trigger points:
  Viewer Request:  after CloudFront receives request, before cache check
  Origin Request:  after cache miss, before forwarding to origin
  Origin Response: after origin responds, before caching
  Viewer Response: after cache (or origin), before sending to user

Lambda@Edge use cases:
  Viewer Request:   Authentication (validate JWT), geographic redirect
  Origin Request:   Rewrite URLs, add headers, select origin based on content
  Origin Response:  Add security headers, modify response
  Viewer Response:  Add CORS headers, A/B testing cookie

CloudFront Functions use cases (simpler, cheaper, faster):
  URL normalisation (lowercase, remove trailing slash)
  HTTP 301/302 redirects
  Add security headers (X-Frame-Options, CSP, HSTS)
  URL rewriting (/old → /new)
  Simple request throttling

Example — Add security headers via CloudFront Function:
  function handler(event) {
      var response = event.response;
      var headers = response.headers;
      headers['x-frame-options'] = {value: 'DENY'};
      headers['x-content-type-options'] = {value: 'nosniff'};
      headers['strict-transport-security'] = {value: 'max-age=31536000; includeSubdomains'};
      headers['content-security-policy'] = {value: "default-src 'self'"};
      return response;
  }
```

### CloudFront + WAF Integration

```
Attach AWS WAF WebACL to CloudFront distribution:
  Rate limiting:      block IPs sending > N requests/5min (DDoS protection)
  IP blocklist:       block known bad IPs, geographic blocks
  OWASP rules:        SQL injection, XSS detection (AWS Managed Rules)
  Bot control:        detect/block scrapers, credential stuffing bots
  Custom rules:       block specific User-Agents, path patterns

# CloudFront WAF is always us-east-1 (global) even if origin is in another region
# Must create the WebACL in us-east-1 for CloudFront

WAF rule example (Terraform):
resource "aws_wafv2_web_acl" "cloudfront_waf" {
  provider = aws.us_east_1   # MUST be us-east-1 for CloudFront
  scope    = "CLOUDFRONT"
  rule {
    name     = "RateLimitRule"
    priority = 1
    action { block {} }
    statement {
      rate_based_statement {
        limit              = 2000          # block after 2000 req/5min per IP
        aggregate_key_type = "IP"
      }
    }
  }
  rule {
    name     = "AWSManagedRulesCommon"
    priority = 2
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config { cloudwatch_metrics_enabled = true ... }
  }
}
```

### CloudFront Price Classes

```
Price Class All:    All 400+ edge locations (best performance)      Most expensive
Price Class 200:    US, Europe, Asia, Africa, Middle East           Medium
Price Class 100:    US and Europe only (cheapest)                   Cheapest

Use Price Class 100 for: EU/US focused applications with cost constraints
Use Price Class All for: global applications, latency-sensitive

Cost model:
  HTTPS requests:  $0.01 per 10,000 requests (US/Europe)
  Data transfer:   $0.085 per GB (first 10TB/month from US edge)
  Free tier:       50GB data + 2M HTTP/S requests per month (12 months)
```

### Origin Shield

```
Origin Shield = an additional caching layer between Regional Edge Caches and origin.
All Regional Edge Caches forward misses to ONE Origin Shield region.
Origin gets far fewer requests.

Without Origin Shield:
  Origin receives requests from 13 Regional Edge Caches
  13 concurrent cache fills for same file = 13 origin hits

With Origin Shield:
  All 13 Regional Edge Caches → Origin Shield (1 region) → origin
  Origin gets 1 request (cache fill) → serves all regions

Use when: origin is bandwidth-limited, expensive API calls, streaming origin
Cost: $0.008–$0.010 per 10,000 requests to Origin Shield
```

---

## 3. Azure CDN and Azure Front Door

### Two Different Products (Common Confusion)

```
Azure CDN Classic:       Traditional CDN — static content delivery
                         Tiers: Microsoft (built-in), Verizon, Akamai
                         Simple: upload to Blob Storage → CDN distributes
                         No WAF. No global load balancing. No traffic routing.
                         Being retired: migrate to Azure Front Door by Sept 2027

Azure Front Door:        Global HTTP load balancer + CDN + WAF + DDoS in one
                         Replaces: Azure CDN + Traffic Manager + App Gateway (global)
                         Use for: modern applications needing all three capabilities
                         Two tiers: Standard (CDN + routing) and Premium (WAF + Private Link)

Rule of thumb:
  New projects:          Always use Azure Front Door
  Static website only:   Azure Front Door Standard (cheap, simple)
  Dynamic API + CDN:     Azure Front Door Standard or Premium
  Legacy:                Azure CDN Classic (migrate to Front Door by 2027)
```

### Azure Front Door Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │           Azure Front Door                   │
                        │                                               │
  User (Mumbai) ──────► │  Anycast PoP (Mumbai)                       │
  User (London) ──────► │  Anycast PoP (London)                       │
  User (NY)     ──────► │  Anycast PoP (New York)    ← 192 PoPs       │
                        │                                               │
                        │  ┌─────────────┐                             │
                        │  │ WAF Policy  │ (Premium tier)              │
                        │  └─────────────┘                             │
                        │                                               │
                        │  ┌────────────────────────────────────────┐  │
                        │  │            Routing Rules                │  │
                        │  │  /api/*    → Origin Group: API         │  │
                        │  │  /static/* → Origin Group: Storage      │  │
                        │  │  /*        → Origin Group: AKS          │  │
                        │  └────────────────────────────────────────┘  │
                        └─────────────────────────────────────────────┘
                                      │
              ┌───────────────────────┼──────────────────────┐
              │                       │                       │
       ┌──────▼──────┐        ┌───────▼──────┐       ┌───────▼──────┐
       │ Azure Blob  │        │  AKS (West   │       │  AKS (East   │
       │ Storage     │        │   Europe)    │       │   US)        │
       │ (static)    │        └──────────────┘       └──────────────┘
       └─────────────┘
```

### Front Door Key Concepts

```
Endpoint:       The CDN endpoint URL (xxxx.z01.azurefd.net or your custom domain)

Route:          Maps incoming URL patterns to origin groups
                Path: /api/* → forward to API origin group
                Path: /static/* → forward to Storage origin, enable caching

Origin:         Backend server (AKS service, App Service, Storage Account, custom HTTP)
Origin Group:   Group of origins with load balancing + health probe settings

Routing Methods (within an origin group):
  Latency:      Route to lowest-latency origin (measured by Front Door)
  Priority:     Primary origin first, fail over to backup (active-passive DR)
  Weighted:     Distribute traffic by weight (canary: 10% to new, 90% to stable)
  Session Affinity: always send same user to same origin (cookie-based)

Health Probes:
  Front Door sends HTTP probes to all origins
  Failing origin removed from rotation automatically
  Configurable: path, interval, protocol, probe method
```

### Front Door Route Configuration (Caching)

```json
{
  "route": {
    "name": "static-assets-route",
    "patternsToMatch": ["/static/*", "/images/*", "/js/*", "/css/*"],
    "cacheConfiguration": {
      "queryStringCachingBehavior": "IgnoreQueryString",
      "compressionSettings": {
        "isCompressionEnabled": true,
        "contentTypesToCompress": [
          "text/html", "text/css", "application/javascript",
          "application/json", "image/svg+xml"
        ]
      },
      "cacheDuration": "7.00:00:00"    // 7 days
    },
    "forwardingProtocol": "HttpsOnly",
    "httpsRedirect": "Enabled"
  }
}
```

```bicep
// Bicep - Front Door Route with caching
resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2023-05-01' = {
  name: 'static-route'
  properties: {
    originGroup: { id: staticOriginGroup.id }
    patternsToMatch: ['/static/*']
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    cacheConfiguration: {
      queryStringCachingBehavior: 'IgnoreQueryString'
      compressionSettings: {
        isCompressionEnabled: true
      }
    }
  }
}
```

### Front Door Rules Engine

```
Rules Engine = server-side request/response manipulation (like Lambda@Edge but simpler)

Actions available:
  Route override:           change origin or cache settings per condition
  URL redirect:             301/302 redirect to new URL
  URL rewrite:              change path before forwarding to origin
  Modify request headers:   add/remove/override request headers
  Modify response headers:  add/remove/override response headers

Conditions available:
  Request URL path         /api/v1/* → rewrite to /api/v2/*
  Request method           POST → don't cache
  Request header           User-Agent: curl → block
  Query string             ?preview=true → route to staging origin
  Country                  CN → redirect to Chinese site

Example — Add security headers:
  Condition: Always
  Action: Add response header
    X-Frame-Options: DENY
    X-Content-Type-Options: nosniff
    Strict-Transport-Security: max-age=31536000; includeSubdomains
    Content-Security-Policy: default-src 'self'

Example — Redirect HTTP to HTTPS (simpler via httpsRedirect on route):
  Condition: Request protocol == HTTP
  Action: URL Redirect (301) to HTTPS
```

### Front Door WAF (Premium Tier)

```
Azure Front Door WAF = Azure WAF running at the CDN edge (not regional).
Requests blocked at the nearest PoP — blocked traffic never reaches your origin.

WAF Policy attached to Front Door endpoint:
  Prevention mode: block requests that match rules
  Detection mode:  log only, don't block (for tuning)

Rule sets:
  Microsoft_DefaultRuleSet_2.1: OWASP-based rules (SQL injection, XSS, RCE)
  Microsoft_BotManagerRuleSet_1.1: bot detection and management
  Custom rules: your own IP blocks, rate limits, geo-blocks

Custom rule example:
{
  "name": "RateLimitByIP",
  "priority": 100,
  "ruleType": "RateLimitRule",
  "rateLimitDurationInMinutes": 1,
  "rateLimitThreshold": 100,
  "matchConditions": [
    {"matchVariable": "RemoteAddr", "operator": "IPMatch", "matchValue": ["0.0.0.0/0"]}
  ],
  "action": "Block"
}

Geographic filtering:
  Block all traffic except from allowed countries
  Or: redirect certain countries to regional site
{
  "name": "GeoBlock",
  "priority": 10,
  "matchConditions": [
    {"matchVariable": "RemoteAddr", "operator": "GeoMatch", "matchValue": ["CN", "RU"]}
  ],
  "action": "Block"
}
```

### Front Door Private Link Origins (Premium)

```
Connect Front Door to origins without public internet exposure:
  Origin (AKS, App Service, Storage) has NO public endpoint
  Front Door connects via Azure Private Link
  Traffic stays on Microsoft network end-to-end

Use cases: financial services, healthcare, regulated industries
  User → Front Door PoP → Private Link → Private AKS Service → pods

Configuration:
  Origin: AKS Internal Load Balancer Service
  Enable Private Link: true
  Private Link resource ID: /subscriptions/.../loadbalancers/my-ilb
  Request message: "front-door-connection"

  # AKS Internal LB service
  apiVersion: v1
  kind: Service
  metadata:
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
  spec:
    type: LoadBalancer
```

### Front Door Standard vs Premium

| Feature | Standard | Premium |
|---|---|---|
| CDN (static content) | Yes | Yes |
| HTTP load balancing | Yes | Yes |
| Custom domains + TLS | Yes | Yes |
| Rules Engine | Yes | Yes |
| Bot protection | No | Yes |
| WAF (DRS + custom rules) | No | Yes |
| Private Link origins | No | Yes |
| Security reports | No | Yes |
| Price | ~$35/month base | ~$330/month base |

---

## 4. CDN for Static Website Hosting

### AWS: S3 + CloudFront

```
Architecture:
  S3 Bucket (private) → CloudFront Distribution → Users worldwide

Setup:
1. Create S3 bucket (block all public access)
2. Enable S3 static website hosting or use REST API (see OAC below)
3. Create CloudFront distribution:
   - Origin: S3 REST API endpoint
   - Origin Access Control: enabled (CloudFront signs S3 requests)
   - Default root object: index.html
   - Custom error pages: /404.html for 404s
4. Update S3 bucket policy (allow CloudFront OAC)
5. Point custom domain to CloudFront (Route 53 CNAME or Alias)

SPA (React/Vue/Angular) — handle client-side routing:
  Custom error response:
    HTTP 403 (S3 access denied = missing file) → serve /index.html with 200
    HTTP 404 → serve /index.html with 200
  This lets React Router handle /about, /profile etc.
```

### Azure: Blob Storage + Front Door

```
Architecture:
  Storage Account (Static Website enabled) → Front Door → Users

Setup:
1. Storage Account → Static website → Enable
   Primary endpoint: https://account.z6.web.core.windows.net/
   Upload: index.html, 404.html, build/ assets

2. Create Front Door (Standard):
   Origin: Storage Account $web endpoint
   Route: /* → origin, enable caching for /static/*
   Custom domain: example.com → Front Door endpoint

3. Custom domain HTTPS: Front Door manages certificate automatically
   (Azure-managed cert, auto-renewed)

# Azure CLI setup
az storage blob service-properties update \
  --account-name my-storage \
  --static-website \
  --index-document index.html \
  --404-document 404.html
```

---

## 5. CDN Caching Strategies — Patterns

### Pattern 1: Long TTL + Cache Busting

```
Best for: static assets (JS, CSS, images)

File naming with content hash:
  main.js           → main.a3f9c2b1.js
  styles.css        → styles.7d4e8f2a.css
  logo.png          → logo.b82c4d91.png

Cache-Control: public, max-age=31536000, immutable   ← 1 year TTL

Benefits:
  → CDN serves file from cache for up to 1 year
  → New deploy = new hash = new URL = new cache entry (no invalidation needed)
  → Old URL still serves old file (safe for users in the middle of a session)

# Webpack/Vite generate hashed filenames automatically
```

### Pattern 2: Short TTL for Frequently Updated Content

```
For: API responses with public data (product catalog, prices)

Cache-Control: public, s-maxage=60, max-age=0
  s-maxage=60:   CDN caches for 60 seconds
  max-age=0:     browser doesn't cache (always fetches from CDN)

On update: wait up to 60 seconds for cache to refresh
          OR trigger CloudFront/Front Door invalidation
```

### Pattern 3: Stale-While-Revalidate

```
For: content that should never appear slow, slight staleness acceptable

Cache-Control: public, max-age=300, stale-while-revalidate=86400
  max-age=300:              serve fresh for 5 min
  stale-while-revalidate:   after 5 min, serve stale AND fetch fresh in background
                            user always gets instant response
                            next request gets fresh content

Not supported by all CDNs (CloudFront: partial, Front Door: yes)
```

### Pattern 4: Vary by Content Type (Accept-Encoding)

```
For: text content served in gzip or brotli

Vary: Accept-Encoding

CDN stores separate versions:
  /styles.css + Accept-Encoding: br    → brotli compressed version
  /styles.css + Accept-Encoding: gzip  → gzip compressed version
  /styles.css (no encoding)            → uncompressed

Always enable compression in CDN:
  CloudFront: Compress objects automatically = Yes (in cache behavior)
  Front Door: compressionSettings.isCompressionEnabled = true
```

---

## 6. CDN for APIs — Dynamic Acceleration

Even non-cacheable API traffic benefits from CDN:

```
Benefits for dynamic/non-cached traffic:
  1. TCP connection reuse:
     User → CDN PoP: short TCP connection (5ms)
     CDN PoP → origin: persistent TCP connection (already open)
     No TCP handshake to origin per request

  2. TLS termination at edge:
     TLS handshake (expensive) happens at nearest PoP
     CDN maintains warm TLS connections to origin
     Saves ~100ms per new connection

  3. HTTP/2 multiplexing:
     Multiple API requests over one TCP connection

  4. Route optimisation:
     CDN has optimised private backbone routes between PoPs and origin
     Faster than public internet routing

  5. Geographic load balancing:
     Route to nearest healthy origin region automatically
```

---

## 7. AWS CloudFront vs Azure Front Door — Side by Side

| Feature | CloudFront | Azure Front Door |
|---|---|---|
| **Edge locations** | 400+ PoPs | 192 PoPs (192 cities, 90+ countries) |
| **Anycast** | Yes | Yes |
| **CDN caching** | Yes | Yes |
| **WAF** | AWS WAF (attach separately) | Built-in (Premium tier) |
| **DDoS protection** | AWS Shield Standard (free) / Advanced ($3K/month) | DDoS Protection included |
| **SSL certificate** | ACM (free managed cert) | Azure-managed cert (free) |
| **Custom origins** | Any HTTP/HTTPS endpoint | Any HTTP/HTTPS endpoint |
| **S3/Blob native** | Yes (OAC for S3) | Yes (Azure Blob Storage) |
| **Lambda@Edge** | Yes | No (Rules Engine instead) |
| **Functions at edge** | CloudFront Functions | Rules Engine actions |
| **Private origin** | VPC Origin (preview) | Private Link (Premium) |
| **Websocket** | Yes | Yes |
| **HTTP/3 (QUIC)** | Yes | Yes |
| **Real-time logs** | Kinesis Data Streams | Azure Monitor, Event Hub |
| **Price model** | Pay per request + data transfer | Monthly base + data transfer |
| **Free tier** | 50GB + 2M requests/month (12mo) | None |
| **Geo-blocking** | Via WAF or Lambda@Edge | Built-in (Standard tier) |
| **A/B testing** | Lambda@Edge | Rules Engine |
| **Best for** | AWS-native workloads | Azure-native workloads |

---

## 8. Common CDN Misconceptions

### "CDN only helps for static files"

```
False. CDN helps for ALL traffic:
  Static files: full caching (100% cache hit for repeated content)
  Dynamic APIs: TCP/TLS acceleration, routing optimisation, WAF at edge
  Streaming:    adaptive bitrate, edge-based encoding
  WebSockets:   persistent connection management at edge
```

### "CDN makes you lose control of your data"

```
False. You control:
  What gets cached (Cache-Control headers)
  Who can access it (Signed URLs, WAF IP blocks, geo-restrictions)
  How long it's cached (TTL settings)
  What headers are forwarded to origin
```

### "Invalidating CDN cache is instant"

```
False.
  CloudFront invalidation: 10-30 seconds to propagate globally (not instant)
  Front Door invalidation: can take up to 10 minutes
  
  During invalidation: edge PoPs still serving old content
  
  Better approach: versioned URLs (never need to invalidate)
  Or: short TTL for content that changes (60-300 seconds)
```

### "Set cache TTL as high as possible"

```
Wrong for dynamic content. Right approach:
  Truly static (hash in filename): max TTL (1 year)
  Semi-static (product data):      short TTL (60-300s)
  User-specific (cart, account):   no-cache (private)
  Real-time (live scores):         no-store
```

---

## 9. Interview Questions

### Q: Explain how a CDN works end-to-end for a first-time request vs a repeat request.

**First request (cache miss):**
1. User requests `https://cdn.example.com/image.jpg`
2. DNS resolves to CDN's Anycast IP → nearest edge PoP handles the request
3. Edge PoP checks local cache → not found (MISS)
4. Edge forwards request to origin (S3 bucket or ALB) — may check regional edge cache first
5. Origin returns `image.jpg` with `Cache-Control: public, max-age=86400`
6. Edge caches the file for 24 hours
7. Edge returns file to user — total latency includes origin RTT (~150ms if origin is far)

**Repeat request (cache hit):**
1. Next user requests same URL
2. Same PoP handles request → file found in edge cache (HIT)
3. Returned directly from edge — total latency ~2-5ms (no origin contact)
4. `Cache-Control: max-age` ticking down from 86400 → 0

After TTL expires: next request is a MISS → origin contacted again.

---

### Q: What is the difference between CloudFront Behaviors and Origins?

**Origins:** define WHERE content comes from (S3 bucket, ALB, API Gateway).
An origin has an ID, domain name, and authentication config (OAC for S3).

**Behaviors:** define HOW requests are handled based on URL path pattern.
A behavior maps a path pattern to an origin AND specifies cache policy, allowed methods, compression.

Example: Single distribution with 2 origins + 2 behaviors:
- Behavior 1: `/static/*` → S3 Origin (cache 1 year, GET only)
- Behavior 2: `/api/*` → ALB Origin (no cache, all methods, forward Authorization header)
- Default behavior: `*` → ALB Origin (cache 60s for GET, bypass for POST)

Behaviors are evaluated in order. First match wins. Default `*` is the fallback.

---

### Q: How do you serve a React SPA (single-page application) through CloudFront without 403/404 errors on direct URL access?

React Router uses client-side routing — `/about` is not a file in S3, it's handled by `index.html`.

**Problem:** User visits `https://example.com/about` directly → CloudFront requests `/about` from S3 → S3 returns 403 (object doesn't exist) or 404 → user sees error.

**Solution:** CloudFront custom error responses.
```
Error Code 403 → Response Page: /index.html → HTTP Status: 200
Error Code 404 → Response Page: /index.html → HTTP Status: 200
```

CloudFront converts the 403/404 to 200 and serves `index.html`. React Router reads the URL and renders the correct component client-side. User sees the correct page, no error.

---

### Q: Azure Front Door vs Application Gateway — what is the difference?

| | Azure Front Door | Application Gateway |
|---|---|---|
| Scope | Global (all Azure regions) | Regional (one region) |
| Layer | L7 HTTP globally | L7 HTTP regionally |
| CDN | Yes | No |
| WAF | Yes (global) | Yes (regional) |
| Anycast | Yes | No |
| SSL offload | At 192 PoPs worldwide | In one region |
| Use case | Multi-region apps, CDN, global WAF | Single-region load balancing, path routing to AKS |

**Typical stack:** Front Door (global CDN + WAF + routing) → Application Gateway (regional WAF + path-based routing to AKS services)

When to use Application Gateway WITHOUT Front Door:
- Internal application (no internet users)
- Single-region deployment
- Complex path-based routing within one region (10+ services on different paths)

---

### Q: How do you handle cache invalidation when you deploy new code?

**Option 1 — Versioned filenames (best, no invalidation needed):**
Build tools (webpack, vite) generate `main.a3f9c2b1.js` with content hash.
New deploy → new hash → new URL → CDN serves both old and new.
Old URL auto-expires after TTL.

**Option 2 — Explicit invalidation (for HTML files without hash):**
```bash
# After every deploy, invalidate HTML files
aws cloudfront create-invalidation --distribution-id XYZ --paths "/*.html" "/index.html"
# Azure Front Door
az afd endpoint purge --profile-name my-frontdoor --endpoint-name my-endpoint \
  --content-paths "/*.html"
```

**Option 3 — Short TTL for HTML (auto-expires quickly):**
`Cache-Control: public, max-age=300` on HTML → at most 5 minutes of stale content.
No manual invalidation needed.

**At Voya:** All static assets use versioned filenames (hash in URL) with 1-year TTL.
HTML files use 60-second TTL. Result: deploy takes effect within 1 minute with no invalidation overhead.

---

### Q: How does CDN help with DDoS attacks?

**Layer 3/4 DDoS (volumetric — flood of packets):**
CloudFront has AWS Shield Standard built in — absorbs volumetric attacks at the edge.
Anycast distributes attack traffic across 400+ PoPs — no single PoP overwhelmed.
Origin never sees Layer 3/4 packets — only HTTP/S requests reach origin.

**Layer 7 DDoS (HTTP flood — many requests):**
WAF rate limiting: block IPs after >2,000 requests/5 min
WAF Bot Control: detect automated attack patterns
Front Door/CloudFront absorbs requests before reaching origin

**Key principle:** CDN puts layers between attackers and your origin.
Even if CDN is overwhelmed at one PoP, Anycast spreads load across other PoPs.
Origin is protected by OAC/Private Link — direct-to-origin attacks require knowing the origin IP.

---

## Quick Reference

```
CDN fundamentals:
  Anycast:       multiple PoPs share same IP, routers pick nearest
  Cache hit:     served from edge (~2-5ms), no origin contact
  Cache miss:    fetched from origin, then cached at edge
  TTL:           how long CDN keeps the cached copy
  Invalidation:  force-expire cache entries before TTL

Cache-Control cheat sheet:
  public, max-age=31536000, immutable    → 1 year (static assets with hash)
  public, s-maxage=60, max-age=0        → 60s CDN, no browser cache
  private, no-store                     → no CDN cache, no browser cache
  public, max-age=300, stale-while-revalidate=86400  → serve stale, refresh async

CloudFront key concepts:
  Distribution   → top-level resource
  Origin         → backend (S3, ALB, API GW)
  Behavior       → path pattern → origin + cache policy
  OAC            → keeps S3 private, CloudFront signs requests
  Signed URL     → time-limited access to one file
  Signed Cookie  → time-limited access to path pattern (e.g., /premium/*)
  Lambda@Edge    → code at edge, 4 trigger points, Node/Python
  CloudFront Fn  → lightweight JS, viewer req/resp only, 1ms max

Azure Front Door key concepts:
  Endpoint       → CDN URL (xxxx.azurefd.net)
  Route          → path pattern → origin group + cache settings
  Origin         → backend server
  Origin Group   → backends with health probe + load balancing
  Rules Engine   → request/response manipulation at edge
  WAF Policy     → security rules (Premium tier)
  Private Link   → private origin connection (Premium tier)

AWS CDN: CloudFront → must attach AWS WAF separately, Lambda@Edge for logic
Azure CDN: Front Door → WAF built-in (Premium), Rules Engine for logic
```
