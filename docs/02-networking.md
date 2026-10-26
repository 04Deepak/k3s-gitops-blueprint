# Networking

## Traefik — K3s Bundled Ingress Controller

K3s ships with Traefik as the default ingress controller. It runs as a DaemonSet in `kube-system`, binding to ports 80 and 443 on the host via klipper-lb (a lightweight service load balancer that creates hostPort pods).

Traefik handles:
- TLS termination (Let's Encrypt ACME)
- HTTP → HTTPS redirect
- Request routing via IngressRoute CRDs
- Middleware (rate limiting, IP allowlists, basic auth, headers)

No separate nginx-ingress or HAProxy is needed — Traefik covers all ingress duties.

### Traefik Configuration

K3s configures Traefik via a HelmChartConfig in `/var/lib/rancher/k3s/server/manifests/`. Key settings:

```yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |
    additionalArguments:
      - "--certificatesresolvers.letsencrypt.acme.email=admin@example.com"
      - "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
    ports:
      web:
        redirectTo:
          port: websecure
```

The `certResolver: letsencrypt` in IngressRoutes triggers automatic certificate provisioning.

## IngressRoute Pattern

Traefik uses its own CRD (`IngressRoute`) instead of the standard Kubernetes `Ingress` resource. This gives more expressive routing.

### Production IngressRoute

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app-web
  namespace: acme
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`app.example.com`)
      kind: Rule
      services:
        - name: frontend-service
          port: 80
      middlewares:
        - name: redirect-https
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app-websecure
  namespace: acme
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`app.example.com`) && PathPrefix(`/api`)
      kind: Rule
      priority: 100
      services:
        - name: backend-service
          port: 5000
    - match: Host(`app.example.com`) && PathPrefix(`/api-docs`)
      kind: Rule
      priority: 90
      services:
        - name: backend-service
          port: 5000
    - match: Host(`app.example.com`)
      kind: Rule
      priority: 10
      services:
        - name: frontend-service
          port: 80
  tls:
    certResolver: letsencrypt
    domains:
      - main: app.example.com
```

**Key points:**
- `web` entrypoint (port 80) redirects all traffic to `websecure` (port 443)
- `websecure` splits traffic: `/api` and `/api-docs` go to backend, everything else to frontend
- `priority` controls match order — higher numbers match first
- `certResolver: letsencrypt` triggers automatic TLS certificate provisioning

### Redirect Middleware

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: acme
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

## TLS with Let's Encrypt

Traefik's ACME integration handles certificate lifecycle automatically:

1. A new IngressRoute with `certResolver: letsencrypt` triggers a certificate request
2. Traefik creates an HTTP-01 challenge (responds to `/.well-known/acme-challenge/`)
3. Let's Encrypt validates domain ownership and issues the certificate
4. Traefik stores the certificate in `/data/acme.json` (persistent volume)
5. Certificates auto-renew 30 days before expiry

**Requirements:**
- DNS A record must point to the server IP
- Port 80 must be open (HTTP-01 challenge)
- The domain in the IngressRoute must match the DNS record

**Checking certificate status:**
```bash
# From outside the cluster
echo | openssl s_client -connect app.example.com:443 -servername app.example.com 2>/dev/null | openssl x509 -noout -dates

# Days until expiry
echo | openssl s_client -connect app.example.com:443 -servername app.example.com 2>/dev/null | \
  openssl x509 -noout -enddate | cut -d= -f2 | xargs -I{} date -d "{}" +%s | \
  xargs -I{} echo $(( ({} - $(date +%s)) / 86400 )) days
```

## DNS Setup

All domains use A records pointing to the server IP. Managed via GoDaddy (or any DNS provider).

| Domain | Purpose | Record |
|--------|---------|--------|
| `app.example.com` | Production app | A → server IP |
| `staging.example.com` | Staging app | A → server IP |
| `argocd.example.com` | ArgoCD UI | A → server IP |
| `infisical.example.com` | Infisical UI | A → server IP |

All four domains resolve to the same IP. Traefik uses the `Host()` matcher in IngressRoutes to route each domain to the correct backend service.

**TTL:** Set DNS TTL to 300s (5 minutes) during initial setup, increase to 3600s (1 hour) once stable.

## Service Types

### ClusterIP (Preferred)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-service
  namespace: acme
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - port: 5000
      targetPort: 5000
```

ClusterIP services are only reachable from within the cluster. All external traffic must go through Traefik, which enforces TLS. This is the correct default for application services.

### NodePort (Avoid for applications)

```yaml
apiVersion: v1
kind: Service
spec:
  type: NodePort
  ports:
    - port: 8080
      targetPort: 8080
      nodePort: 30080
```

NodePort exposes the service on every node's IP at the specified port (30000-32767). Traffic arrives in cleartext (no TLS), bypassing Traefik entirely. Use only when there is no alternative (e.g., initial ArgoCD setup before IngressRoute exists).

**Why ClusterIP over NodePort:**
- NodePort bypasses TLS — credentials sent in cleartext
- NodePort bypasses all Traefik middleware (rate limiting, IP allowlists)
- NodePort ports are reachable from the public internet unless firewalled
- NodePort limits: only ports 30000-32767, max 2768 services

### Port Mapping Reference

| Service | Internal Port | Service Port | Access Method |
|---------|--------------|-------------|---------------|
| Backend | 5000 | 5000 | ClusterIP → Traefik IngressRoute |
| Frontend (nginx) | 80 | 80 | ClusterIP → Traefik IngressRoute |
| PostgreSQL | 5432 | 5432 | ClusterIP (pinned IP) |
| PgBouncer | 6432 | 6432 | ClusterIP |
| Redis | 6379 | 6379 | ClusterIP |
| ArgoCD | 8080 | 80 | ClusterIP → Traefik IngressRoute |
| Infisical | 8080 | 8080 | ClusterIP → Traefik IngressRoute |

## Security Headers

The frontend nginx configuration adds security headers to all responses:

```nginx
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header Content-Security-Policy "..." always;  # Report-Only recommended initially
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
```

| Header | Value | Purpose |
|--------|-------|---------|
| X-Frame-Options | SAMEORIGIN | Prevents clickjacking via iframes |
| X-Content-Type-Options | nosniff | Prevents MIME-type sniffing |
| Referrer-Policy | strict-origin-when-cross-origin | Controls referer header leakage |
| HSTS | max-age=31536000; includeSubDomains | Forces HTTPS for 1 year |
| Permissions-Policy | geolocation=(), microphone=(), camera=() | Disables browser APIs |

## Cross-Namespace Service Access

Kubernetes DNS resolves services across namespaces using fully-qualified names:

```
<service-name>.<namespace>.svc.cluster.local
```

Examples:
```
redis.shared.svc.cluster.local:6379        # Redis from any namespace
postgres.shared.svc.cluster.local:5432     # PostgreSQL from any namespace
infisical-backend.infisical.svc.cluster.local:8080  # Infisical API
```

For convenience, you can create an ExternalName Service that aliases a cross-namespace service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: acme
spec:
  type: ExternalName
  externalName: redis.shared.svc.cluster.local
```

This lets pods in `acme` connect to `redis:6379` instead of the full FQDN. However, the FQDN works fine in environment variables and is more explicit — either approach is valid.

## Admin Ingress (ArgoCD + Infisical)

Admin services get their own IngressRoutes with separate domains:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-ingress
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`argocd.example.com`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
  tls:
    certResolver: letsencrypt
```

**Securing admin consoles** (recommended):

Add a Traefik `ipAllowList` middleware that restricts access to a VPN subnet:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: vpn-only
  namespace: argocd
spec:
  ipAllowList:
    sourceRange:
      - "10.8.0.0/24"  # WireGuard VPN subnet
```

Then attach it to the IngressRoute:

```yaml
routes:
  - match: Host(`argocd.example.com`)
    kind: Rule
    services:
      - name: argocd-server
        port: 80
    middlewares:
      - name: vpn-only
```

See [09-security.md](./09-security.md) for the full WireGuard setup.
