# Security

Defense in depth for a K3s production cluster. Each layer limits the blast radius of the one above it failing.

## TLS Everywhere

All external traffic is encrypted via Let's Encrypt certificates managed by Traefik's built-in ACME resolver:

```yaml
# Traefik IngressRoute
spec:
  tls:
    certResolver: letsencrypt
    domains:
      - main: app.example.com
```

Traefik handles certificate issuance, renewal, and storage automatically. Certificates are stored in `acme.json` on the node. Renewal happens 30 days before expiry.

The `web` entrypoint (port 80) redirects all HTTP traffic to HTTPS via a middleware:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

Internal cluster traffic (pod-to-pod, pod-to-service) is **not** encrypted — Kubernetes networking is trusted within the cluster. This is standard for single-node deployments; multi-node clusters with untrusted networks should add a service mesh (Linkerd/Istio) for mTLS.

## ClusterIP Over NodePort

Every application service uses `type: ClusterIP`, making it reachable **only inside the cluster**. Traffic enters exclusively through Traefik IngressRoutes.

### Why Not NodePort

NodePort exposes a service on every node at a static port (30000–32767). This means:

- The service is reachable from the public internet at `SERVER_IP:PORT`
- No TLS — traffic is cleartext
- No middleware — no rate limiting, no auth, no headers
- Bypasses Traefik entirely — your ingress security controls don't apply

### The Migration

An earlier deployment of this stack used NodePort services. A security review flagged it as critical: the backend API was answering cleartext HTTP requests on a NodePort, including `POST /api/auth/login`.

The fix was straightforward:

```yaml
# Before
spec:
  type: NodePort
  ports:
    - port: 5000
      nodePort: 30500

# After
spec:
  type: ClusterIP
  ports:
    - port: 5000
```

**Verification before flipping:**
1. Confirm the IngressRoute covers 100% of the app's routes (the backend mounts everything under `/api`)
2. Confirm no webhook/callback endpoints need direct access
3. Confirm no client hardcodes the NodePort
4. Flip the Service type
5. Verify app still serves via the domain
6. Verify the NodePort no longer answers: `curl http://SERVER_IP:30500` → connection refused

## WireGuard VPN for Admin Consoles

### The Problem

ArgoCD and Infisical have web UIs that, on a default K3s install, are exposed via NodePort on the public internet. Password-only authentication on admin consoles that control deploy authority (ArgoCD) and every secret in the system (Infisical) is insufficient.

### The Solution

WireGuard creates a private tunnel between your devices and the server. Admin consoles are accessible only through this tunnel.

```
[Laptop/Phone] ──WireGuard──▶ [Server wg0: 10.8.0.1]
                                    │
                              ┌─────┴─────┐
                              │  Traefik   │
                              │ ipAllowList│
                              │ 10.8.0.0/24│
                              └─────┬─────┘
                                    │
                         ┌──────────┼──────────┐
                    [ArgoCD UI] [Infisical UI] [App ─ public]
```

**Configuration:**

```ini
# /etc/wireguard/wg0.conf on server
[Interface]
Address = 10.8.0.1/24
ListenPort = 51820
PrivateKey = <server-private-key>

[Peer]  # Laptop
PublicKey = <laptop-public-key>
AllowedIPs = 10.8.0.2/32

[Peer]  # Phone
PublicKey = <phone-public-key>
AllowedIPs = 10.8.0.3/32
```

### Split-DNS — Required

Without split-DNS, VPN clients resolve admin hostnames (e.g., `argocd.example.com`) to the server's **public IP**. WireGuard excludes its own endpoint from the tunnel (otherwise it would loop), so traffic to the public IP routes **around** the tunnel. Traefik sees your ISP IP, not your VPN IP, and the allowlist blocks you. Silent failure.

**Fix:** Configure VPN clients to resolve admin hostnames to `10.8.0.1` (the server's WireGuard address). On macOS/iOS this is in the WireGuard client DNS settings. On Linux, use `resolvconf` or systemd-resolved split-dns.

### Traefik ipAllowList

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: vpn-only
  namespace: argocd
spec:
  ipAllowList:
    sourceRange:
      - "10.8.0.0/24"
```

Attach to admin IngressRoutes:

```yaml
spec:
  routes:
    - match: Host(`argocd.example.com`)
      middlewares:
        - name: vpn-only
      services:
        - name: argocd-server
          port: 80
```

**Important:** Set `externalTrafficPolicy: Local` on the Traefik Service so it sees real client IPs instead of SNAT'd node IPs.

### Port Closure

Close admin NodePorts in the **hosting provider's firewall UI**, not with `ufw`. On K3s, NodePort traffic is DNAT'd in `nat PREROUTING` → `KUBE-SERVICES` and routed via `FORWARD`. `ufw` operates on the `INPUT` chain — it never sees this traffic.

```
# Ports to close in hosting provider firewall:
30138  (ArgoCD HTTP)
30443  (ArgoCD HTTPS)
30080  (Infisical)

# Port to open:
UDP 51820  (WireGuard)

# Keep open:
22     (SSH — lockout escape hatch)
80     (Traefik HTTP → redirect to HTTPS)
443    (Traefik HTTPS — public app traffic)
```

## Container Registry Authentication

Private GHCR images require an `imagePullSecret` in each namespace:

```bash
kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=YOUR_USER \
  --docker-password=YOUR_PAT \
  -n your-namespace
```

Referenced in every Deployment:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: ghcr-secret
```

If missing, pods show `ImagePullBackOff` with "unauthorized" in the event.

## Database Access Control

### Scoped Users

Never give the application the superuser password. Create scoped users with limited permissions and connection budgets:

```sql
CREATE USER app_prod WITH LOGIN PASSWORD 'strong-password' CONNECTION LIMIT 50;
GRANT CONNECT ON DATABASE my_project TO app_prod;
GRANT USAGE ON SCHEMA public TO app_prod;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO app_prod;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO app_prod;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO app_prod;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO app_prod;
```

`CONNECTION LIMIT` prevents a runaway application from exhausting PostgreSQL's `max_connections` (default 100) and locking out other databases on the shared instance.

### Restricted SSH Tunnel

For remote database access, create a locked-down SSH user that can **only** port-forward to the database ClusterIP:

```bash
adduser --disabled-password --shell /usr/sbin/nologin dbtunnel
```

In `~dbtunnel/.ssh/authorized_keys`:

```
restrict,port-forwarding,permitopen="10.43.100.100:5432" ssh-ed25519 AAAA... user@laptop
```

This allows:

```bash
ssh -L 5432:10.43.100.100:5432 dbtunnel@server-ip
# Then: psql -h localhost -U app_prod -d my_project
```

But prevents: shell access, command execution, forwarding to any other host/port.

### PgBouncer as Gatekeeper

PgBouncer sits between the application and PostgreSQL, enforcing:
- Connection pooling (prevents connection exhaustion under HPA scaling)
- Auth verification (separate userlist.txt)
- Transaction-mode isolation (connections returned to pool after each transaction)

The application's `DATABASE_URL` points at PgBouncer. Only migrations use `DIRECT_URL` to connect directly (Prisma's migration advisory lock requires session-mode connections).

## Application Security

### NODE_ENV Pinning

`NODE_ENV` is set as an **explicit env var** in the Deployment manifest, not through `envFrom`:

```yaml
env:
  - name: NODE_ENV
    value: "production"
```

This is deliberate — explicit `env` entries override values from `envFrom: secretRef`. If someone accidentally removes `NODE_ENV` from Infisical, the application still runs in production mode. The Dockerfile also pins it:

```dockerfile
ENV NODE_ENV=production
```

Belt and suspenders. The application validates `NODE_ENV` at startup and refuses to start if it's missing or unexpected. `NODE_ENV !== "production"` gates: dev OTP exposure in API responses, Swagger UI, OTP logging, error stack traces.

### Rate Limiting

Rate limiting uses Redis as a shared store across all HPA replicas:

```
Key pattern: rl:{scope}:{identifier}
Examples:   rl:auth:192.168.1.1
            rl:otp:+919876543210
            rl:api:user-uuid
```

This is **app-level** rate limiting, not Traefik-level. Why:
- Per-user and per-destination limits need application context (user ID, phone number)
- Traefik rate limiting is per-IP only — insufficient for authenticated APIs
- The shared Redis store ensures limits are consistent across replicas (in-memory `MemoryStore` gives each replica its own counter — at 8 replicas, the effective limit is 8x)

### Nginx Security Headers

```nginx
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
add_header Content-Security-Policy-Report-Only "default-src 'self'; ..." always;
```

| Header | Purpose |
|--------|---------|
| `X-Frame-Options: SAMEORIGIN` | Prevents clickjacking via iframes |
| `X-Content-Type-Options: nosniff` | Prevents MIME-type sniffing attacks |
| `Referrer-Policy` | Limits referrer leakage to other origins |
| `HSTS` | Forces HTTPS for 1 year, including subdomains |
| `Permissions-Policy` | Blocks access to device APIs (camera, mic, geolocation) |
| `CSP (Report-Only)` | Logs CSP violations without blocking — start here, enforce later |

## Secret Management Security

Infisical provides:
- **Audit log** — every secret read/write is logged with actor, timestamp, and IP
- **Machine identity scoping** — the `cli-admin` identity can be scoped to specific projects
- **Versioning** — every secret change creates a version, rollback is possible
- **Operator sync** — secrets never pass through CI pipelines; the operator pulls directly from Infisical to K8s

The secrets operator authenticates via machine identity (clientId + clientSecret stored as a K8s Secret). The operator runs inside the cluster and syncs every 60 seconds.

## What's NOT Done Yet

These are known gaps, ordered by impact:

| Gap | Risk | Why Not Yet |
|-----|------|-------------|
| **NetworkPolicies** | Pods in any namespace can reach any other namespace | Requires per-namespace policy design; single-node reduces blast radius |
| **Separate node pools** | A compromised staging pod shares the node with prod | Requires multi-node cluster — budget constraint |
| **Security contexts** | Containers run as root | Needs per-image testing (some images require root for port binding) |
| **Pod security standards** | No enforcement of privilege restrictions | Depends on security contexts being set first |
| **Image scanning** | No automated CVE scanning of container images | Trivy or Snyk integration in CI — straightforward to add |
| **Network egress filtering** | Pods can reach any external IP | Requires NetworkPolicies or a service mesh |

These are documented as future work, not accepted risks. Each should be addressed as the team and infrastructure mature.
