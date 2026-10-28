# 07 — TLS & DNS Setup

Configure domain names and automatic Let's Encrypt TLS certificates via Traefik.

**Time:** ~15 minutes (plus DNS propagation wait)

---

## Step 1: Create DNS records

Go to your DNS provider (GoDaddy, Cloudflare, Route53, etc.) and create **A records** pointing to your server IP:

| Record | Type | Name | Value | TTL |
|--------|------|------|-------|-----|
| App (prod) | A | `app` | `{{SERVER_IP}}` | 300 |
| App (staging) | A | `staging` | `{{SERVER_IP}}` | 300 |
| ArgoCD | A | `argocd` | `{{SERVER_IP}}` | 300 |
| Infisical | A | `infisical` | `{{SERVER_IP}}` | 300 |
| Grafana | A | `grafana` | `{{SERVER_IP}}` | 300 |

Use a short TTL while you are setting up, then raise it once certificates are issued.

> **Cloudflare users:** set proxy status to **DNS only** (grey cloud). Traefik needs direct TCP
> access for the ACME challenge, and an orange-cloud record breaks it.

> **Do not add AAAA records.** Your VPS probably has a global IPv6 address, but K3s runs
> single-stack IPv4 by default, so Traefik never listens on IPv6. An AAAA record sends every
> IPv6-capable browser to a port nothing is listening on — they get a connection refused while
> IPv4-only visitors see a perfectly healthy site. That is a miserable bug to track down. Check
> what your server has with `ip -6 addr show scope global`; having an address is not the same as
> serving on it.

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

### First, the thing that will bite you

K3s's bundled Traefik mounts `/data` as an **emptyDir**. Check your own cluster:

```bash
kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.template.spec.volumes}'; echo
```

If you see `{"emptyDir":{},"name":"data"}`, then `acme.json` — the file holding every certificate
Traefik has been issued — **lives only in the pod's memory-backed scratch space and is destroyed
every time the pod restarts.**

That is not a rare event. A node reboot, a K3s upgrade, an OOM kill, or editing this very
HelmChartConfig all restart Traefik. Each restart makes Traefik request its certificates again,
and Let's Encrypt enforces a limit of **5 duplicate certificates per week** for an identical set
of domains. Five restarts in a week and issuance starts failing — for a full week, with no valid
certificate, and nothing in the Traefik log that says "you are rate limited" in those words.

So configure persistence **and** the resolver together, in one HelmChartConfig. `init.sh` renders
this for you from `templates/shared/traefik-config.yaml`, using `LETSENCRYPT_EMAIL` from
`vars.env`:

```bash
cat output/shared/traefik-config.yaml     # read it before applying
kubectl apply -f output/shared/traefik-config.yaml
```

> **Set `LETSENCRYPT_EMAIL` in `vars.env` first** and re-run `./init.sh`. Use a mailbox somebody reads — Let's Encrypt sends expiry warnings
> there, and it is the only notice you get if auto-renewal silently stops.

K3s re-reconciles the bundled chart when this changes. Give it a minute:

```bash
sleep 45
kubectl -n kube-system rollout status deploy/traefik --timeout=180s
```

**Verify persistence actually took:**

```bash
kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.template.spec.volumes}'; echo
kubectl -n kube-system get pvc
kubectl -n kube-system exec deploy/traefik -- sh -c 'touch /data/.w && echo writable && rm /data/.w'
```

Expected: the `data` volume is now a `persistentVolumeClaim`, a `traefik` PVC is `Bound`, and the
write test prints `writable`. If the write test fails, `fsGroup` did not apply.

> **Use the staging ACME server while you experiment.** Its rate limits are far looser and its
> certificates are untrusted by browsers, which is exactly what you want until the plumbing is
> proven. The `caServer:` line is already in `templates/shared/traefik-config.yaml`, commented
> out — uncomment it, re-run `./init.sh`, re-apply, and confirm a certificate is issued. Then
> comment it out again, re-apply, and delete `/data/acme.json` so Traefik re-issues against
> production:
>
> ```bash
> kubectl -n kube-system exec deploy/traefik -- rm -f /data/acme.json
> kubectl -n kube-system rollout restart deploy/traefik
> ```

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
- **Rate limited:** Let's Encrypt allows 5 duplicate certificates per week for an identical set of
  domains. There is no way to lift it and no reset button — you wait out the rolling week. This is
  the failure mode that non-persistent `acme.json` walks you into, because every Traefik restart
  spends one of the five. The log line is a 429 from `acme-v02.api.letsencrypt.org`; it does not
  use the phrase "rate limit", so grep for `429` or `too many`:

  ```bash
  kubectl -n kube-system logs -l app.kubernetes.io/name=traefik --tail=200 \
    | grep -iE '429|too many|urn:ietf:params:acme:error'
  ```

  If you are already rate limited, add a temporary extra subdomain to the IngressRoute so the
  certificate covers a *different* domain set, or switch to the staging CA until the week rolls.
- **Wrong email:** The `acme.email` must be valid

### "connection refused" on port 443

Traefik isn't listening. Check:

```bash
kubectl -n kube-system get svc traefik
ss -tlnp | grep ':443'
```

### Where are certificates stored?

Inside the Traefik pod at `/data/acme.json` — **and by default K3s does not persist it.** The
bundled chart mounts `/data` as an emptyDir, so every certificate Traefik holds is destroyed when
the pod restarts. Step 3 configures a PVC to fix this; verify yours actually has one:

```bash
kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.template.spec.volumes}'; echo
kubectl -n kube-system exec deploy/traefik -- ls -l /data/acme.json
```

You want to see `persistentVolumeClaim` in the first command and a file of a few KB in the second.
A `0`-byte or missing `acme.json` after a successful issuance means Traefik could not write to the
volume — almost always the `fsGroup` from Step 3 being absent, leaving the PVC root-owned.

Nothing useful lives in `/var/lib/rancher/k3s/server/manifests/` for this — that directory holds
K3s's bundled chart definitions, not certificate data.

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
