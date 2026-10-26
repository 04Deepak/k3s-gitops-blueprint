# 07 — TLS & DNS Setup

Configure domain names and automatic Let's Encrypt TLS certificates via Traefik.

**Time:** ~15 minutes (plus DNS propagation wait)

---

## Step 1: Create DNS records

Go to your DNS provider (GoDaddy, Cloudflare, Route53, etc.) and create **A records** pointing to your server IP:

| Record | Type | Name | Value | TTL |
|--------|------|------|-------|-----|
| App (prod) | A | `app` | `{{SERVER_IP}}` | 600 |
| App (staging) | A | `staging` | `{{SERVER_IP}}` | 600 |
| ArgoCD | A | `argocd` | `{{SERVER_IP}}` | 600 |
| Infisical | A | `infisical` | `{{SERVER_IP}}` | 600 |

> If using Cloudflare, set proxy status to **DNS only** (grey cloud) — Traefik needs direct TCP access for Let's Encrypt ACME challenges.

**Verify DNS propagation:**

```bash
dig +short app.{{DOMAIN}}
dig +short staging.{{DOMAIN}}
dig +short argocd.{{DOMAIN}}
dig +short infisical.{{DOMAIN}}
```

Each should return `{{SERVER_IP}}`. If not, wait — DNS propagation can take 5–30 minutes.

## Step 2: Understand Traefik TLS in K3s

K3s's bundled Traefik supports automatic Let's Encrypt certificates via the ACME protocol:

1. A request arrives at `https://app.example.com`
2. Traefik sees the IngressRoute has `certResolver: letsencrypt`
3. Traefik requests a certificate from Let's Encrypt
4. Let's Encrypt issues an HTTP-01 challenge (hits `http://app.example.com/.well-known/acme-challenge/...`)
5. Traefik responds to the challenge
6. Certificate is issued and stored in `acme.json`
7. All subsequent requests use the certificate
8. Traefik auto-renews before expiry (30 days before)

## Step 3: Configure Traefik for Let's Encrypt

K3s configures Traefik via a HelmChartConfig resource. Create it:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |
    additionalArguments:
      - "--certificatesresolvers.letsencrypt.acme.email=your@email.com"
      - "--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json"
      - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
EOF
```

> **Replace `your@email.com`** with a real email — Let's Encrypt sends expiry warnings to it.

Wait for Traefik to restart:

```bash
kubectl -n kube-system rollout status deploy/traefik
```

## Step 4: Apply IngressRoutes

The templates should already have the IngressRoutes. They look like this:

**Production app** (`ingress.yaml`):

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app-web
  namespace: {{NAMESPACE}}
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`{{DOMAIN}}`)
      kind: Rule
      middlewares:
        - name: redirect-https
          namespace: {{NAMESPACE}}
      services:
        - name: {{PROJECT_NAME}}-frontend
          port: 80
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: app-websecure
  namespace: {{NAMESPACE}}
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{DOMAIN}}`) && PathPrefix(`/api`)
      kind: Rule
      services:
        - name: {{PROJECT_NAME}}-backend
          port: 5000
    - match: Host(`{{DOMAIN}}`)
      kind: Rule
      services:
        - name: {{PROJECT_NAME}}-frontend
          port: 80
  tls:
    certResolver: letsencrypt
    domains:
      - main: {{DOMAIN}}
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: {{NAMESPACE}}
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

Apply all IngressRoutes:

```bash
kubectl apply -f templates/ingress.yaml
kubectl apply -f templates/admin-ingress/
```

## Step 5: Verify TLS

Wait 1–2 minutes for Let's Encrypt to issue certificates, then:

```bash
# Check from your machine
curl -sI https://{{DOMAIN}} | head -5
```

Expected:

```
HTTP/2 200
...
```

Detailed certificate check:

```bash
echo | openssl s_client -connect {{DOMAIN}}:443 -servername {{DOMAIN}} 2>/dev/null | openssl x509 -noout -subject -dates -issuer
```

Expected:

```
subject=CN = app.example.com
notBefore=Sep  4 ...
notAfter=Dec  3 ...
issuer=C = US, O = Let's Encrypt, CN = R11
```

Check all domains:

```bash
for d in {{DOMAIN}} {{STAGING_DOMAIN}} {{ARGOCD_DOMAIN}} {{INFISICAL_DOMAIN}}; do
  echo -n "$d: "
  echo | openssl s_client -connect $d:443 -servername $d 2>/dev/null | \
    openssl x509 -noout -enddate 2>/dev/null || echo "FAILED"
done
```

## Step 6: Verify HTTP → HTTPS redirect

```bash
curl -sI http://{{DOMAIN}} | head -3
```

Expected:

```
HTTP/1.1 301 Moved Permanently
Location: https://{{DOMAIN}}/
```

---

## Troubleshooting

### Certificate not issued (still self-signed)

Check Traefik logs:

```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --tail=50 | grep -i acme
```

Common causes:
- **DNS not propagated:** `dig +short {{DOMAIN}}` must return your server IP
- **Port 80 blocked:** Let's Encrypt HTTP-01 challenge needs port 80 open
- **Rate limited:** Let's Encrypt limits 5 duplicate certs per week. Wait or use a different domain
- **Wrong email:** The `acme.email` must be valid

### "connection refused" on port 443

Traefik isn't listening. Check:

```bash
kubectl -n kube-system get svc traefik
ss -tlnp | grep ':443'
```

### Where are certificates stored?

Inside the Traefik pod at `/data/acme.json`. K3s persists this via a PVC or hostPath.

```bash
# Check on the server
ls -la /var/lib/rancher/k3s/server/manifests/
```

### Certificate expiry monitoring

The health check script (setup later in [11-security-hardening.md](./11-security-hardening.md)) includes TLS cert expiry checking. Certificates auto-renew 30 days before expiry.

---

## What you have now

- All domains pointing to your server
- Automatic Let's Encrypt TLS certificates
- HTTP → HTTPS redirect
- Traefik routing:
  - `/api/*` → backend
  - `/*` → frontend (SPA)
  - Admin subdomains → ArgoCD and Infisical

**Next:** [08-pgbouncer.md](./08-pgbouncer.md) — set up connection pooling.
