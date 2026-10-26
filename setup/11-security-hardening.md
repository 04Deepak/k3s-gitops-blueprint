# 11 — Security Hardening

Post-deployment hardening: VPN for admin consoles, firewall lockdown, restricted database access, and image pull secrets. Do this after the application is deployed and working — breaking access to admin consoles before you have VPN access locks you out.

---

## Overview

| Layer | What | Why |
|-------|------|-----|
| WireGuard VPN | Admin consoles (ArgoCD, Infisical) behind VPN | Password-only auth on the public internet is one credential away from compromise |
| Firewall | Close NodePort bypass ports | NodePorts let anyone skip TLS and hit services directly |
| dbtunnel SSH user | Restricted port-forward-only access to Postgres | Developers get DB access without root shell on the server |
| GHCR secrets | Image pull authentication | Private container images require credentials |
| NODE_ENV | Explicit environment variable in Deployment | Prevents silent fallback to development mode in production |

---

## Part 1: WireGuard VPN

### The Problem

ArgoCD and Infisical admin consoles are on the public internet. Anyone who can reach the login page can brute-force credentials, exploit a zero-day, or use leaked/default passwords. The consoles control deploy authority and every secret in the system.

### Step 1: Install WireGuard on the Server

```bash
ssh {{SSH_HOST}}

apt update && apt install -y wireguard

# Generate server keys
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key

# Note the public key — clients need it
cat /etc/wireguard/server_public.key
```

### Step 2: Server Configuration

```bash
cat > /etc/wireguard/wg0.conf << 'WGEOF'
[Interface]
PrivateKey = PASTE_SERVER_PRIVATE_KEY_HERE
Address = 10.8.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# Laptop
PublicKey = PASTE_LAPTOP_PUBLIC_KEY_HERE
AllowedIPs = 10.8.0.2/32

[Peer]
# Phone
PublicKey = PASTE_PHONE_PUBLIC_KEY_HERE
AllowedIPs = 10.8.0.3/32
WGEOF

chmod 600 /etc/wireguard/wg0.conf
```

Replace `eth0` with your server's primary interface if different (`ip route show default` shows it).

### Step 3: Generate Client Keys

On your laptop:

```bash
# Install WireGuard
# macOS: brew install wireguard-tools  (or use the WireGuard app from App Store)
# Linux: apt install wireguard-tools

wg genkey | tee laptop_private.key | wg pubkey > laptop_public.key
cat laptop_public.key  # Paste this into the server's [Peer] section
```

Create the client config:

```ini
# Save as /etc/wireguard/my-server.conf (Linux) or import into WireGuard app (macOS/iOS)
[Interface]
PrivateKey = PASTE_LAPTOP_PRIVATE_KEY_HERE
Address = 10.8.0.2/24
DNS = 10.8.0.1

[Peer]
PublicKey = PASTE_SERVER_PUBLIC_KEY_HERE
Endpoint = {{SERVER_IP}}:51820
AllowedIPs = 10.8.0.0/24
PersistentKeepalive = 25
```

For a phone, repeat with a separate key pair and `Address = 10.8.0.3/24`. Import via QR code in the WireGuard mobile app:

```bash
# Generate QR code for phone config
apt install qrencode  # on server
qrencode -t ansiutf8 < phone.conf
```

### Step 4: Start WireGuard

Server:

```bash
# Start now
wg-quick up wg0

# Enable on boot
systemctl enable wg-quick@wg0

# Verify
wg show
```

Expected output:

```
interface: wg0
  public key: <server_public_key>
  private key: (hidden)
  listening port: 51820

peer: <laptop_public_key>
  allowed ips: 10.8.0.2/32
  latest handshake: 12 seconds ago
  transfer: 1.24 KiB received, 832 B sent
```

Client:

```bash
# Linux
wg-quick up my-server

# macOS app: toggle the tunnel on

# Verify
ping 10.8.0.1  # Should reach the server
```

### Step 5: Split-DNS (CRITICAL)

**This step is required. Without it, the VPN silently fails to protect admin consoles.**

**Why:** VPN clients resolve `argocd.example.com` via public DNS → the server's **public** IP. WireGuard excludes its own endpoint from the tunnel (to avoid routing loops), so traffic to the public IP goes **around** the tunnel. Traefik sees your ISP's IP, the ipAllowList blocks you. Everything looks connected, but you can't reach the consoles.

**Fix:** VPN clients must resolve admin hostnames to `10.8.0.1` (the server's WireGuard address).

**Option A — dnsmasq on the server (recommended):**

```bash
apt install dnsmasq

cat > /etc/dnsmasq.d/admin-consoles.conf << EOF
address=/{{ARGOCD_DOMAIN}}/10.8.0.1
address=/{{INFISICAL_DOMAIN}}/10.8.0.1
EOF

systemctl restart dnsmasq
```

The client config already sets `DNS = 10.8.0.1`, so VPN clients query dnsmasq for all DNS. dnsmasq intercepts admin hostnames and returns `10.8.0.1`; everything else forwards to the upstream resolver.

**Option B — /etc/hosts on each client (simpler, less maintainable):**

```bash
# Add to /etc/hosts on laptop (and phone if possible)
10.8.0.1 {{ARGOCD_DOMAIN}}
10.8.0.1 {{INFISICAL_DOMAIN}}
```

This bypasses DNS entirely. Downside: you must update every client when adding a new admin domain.

### Step 6: Traefik ipAllowList Middleware

Create a middleware that allows only VPN traffic:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: vpn-only
  namespace: argocd  # Or wherever your admin IngressRoutes live
spec:
  ipAllowList:
    sourceRange:
      - 10.8.0.0/24
```

Update admin IngressRoutes to use it:

```yaml
# admin-ingress/argocd-ingress.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-ingress
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`{{ARGOCD_DOMAIN}}`)
      kind: Rule
      middlewares:
        - name: vpn-only    # <-- Add this
      services:
        - name: argocd-server
          port: 80
  tls:
    certResolver: letsencrypt
```

Repeat for the Infisical IngressRoute.

### Step 7: Preserve Real Client IPs

By default, kube-proxy may SNAT traffic, and Traefik sees internal cluster IPs instead of the VPN client's `10.8.0.x`. Fix:

```bash
kubectl patch svc traefik -n kube-system \
  -p '{"spec":{"externalTrafficPolicy":"Local"}}'
```

Verify by checking Traefik access logs:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=20
# Look for 10.8.0.x in the client IP field
```

> **Warning on multi-node clusters:** `externalTrafficPolicy: Local` means traffic arriving on a node is served only by pods on that node. On a single-node cluster this is fine. On multi-node, ensure Traefik runs on every node (DaemonSet) or traffic may be dropped.

### Step 8: Verify Access Control

From **outside** the VPN (disconnect first):

```bash
# Should timeout or return 403
curl -m 10 -k https://{{ARGOCD_DOMAIN}}
curl -m 10 -k https://{{INFISICAL_DOMAIN}}
```

From **inside** the VPN (reconnect):

```bash
# Should return HTML (ArgoCD UI) / 200
curl -k https://{{ARGOCD_DOMAIN}}
curl -k https://{{INFISICAL_DOMAIN}}
```

### Step 9: Close Ports in Hosting Provider Firewall

> **IMPORTANT:** Use the hosting provider's firewall UI (Hostinger, Hetzner, DigitalOcean, etc.), **NOT** `ufw`.
>
> **Why ufw fails here:** NodePort traffic is DNAT'd by kube-proxy in the `nat PREROUTING` chain → `KUBE-SERVICES`, then routed via `FORWARD`. It never reaches the `INPUT` chain where ufw rules live. `ufw deny 30138` silently blocks nothing.

**Ports to close** (remove allow-rules in the hosting UI):

| Port | Was | Close? |
|------|-----|--------|
| 30138 | ArgoCD HTTP bypass | Yes |
| 30443 | ArgoCD HTTPS bypass | Yes |
| 30080 | Infisical bypass | Yes |

**Ports to open/keep:**

| Port | Purpose | Keep? |
|------|---------|-------|
| 22/TCP | SSH | Yes — lockout escape hatch |
| 80/TCP | Traefik HTTP (redirects to HTTPS) | Yes |
| 443/TCP | Traefik HTTPS | Yes |
| 51820/UDP | WireGuard | Yes (new) |

> **Leave SSH open.** If the VPN breaks, SSH is your only way back in. Never close port 22 unless you have out-of-band console access (IPMI, hosting provider's web console).

---

## Part 2: Restricted SSH User (dbtunnel pattern)

Give developers database access without giving them a root shell.

### Create the User

```bash
ssh {{SSH_HOST}}

# Create user with no password (SSH key only)
adduser --disabled-password --gecos "DB tunnel only" dbtunnel

# Create .ssh directory
mkdir -p /home/dbtunnel/.ssh
```

### Add SSH Keys with Restrictions

```bash
cat >> /home/dbtunnel/.ssh/authorized_keys << 'EOF'
restrict,port-forwarding,permitopen="{{POSTGRES_CLUSTERIP}}:5432" ssh-ed25519 AAAA... developer-name@laptop
EOF
```

The `restrict` keyword disables shell, agent forwarding, X11, PTY — everything except what you explicitly re-enable. `port-forwarding` re-enables port forwarding. `permitopen` limits forwarding to exactly one destination.

Set permissions:

```bash
chown -R dbtunnel:dbtunnel /home/dbtunnel/.ssh
chmod 700 /home/dbtunnel/.ssh
chmod 600 /home/dbtunnel/.ssh/authorized_keys
```

Set no-login shell:

```bash
usermod -s /usr/sbin/nologin dbtunnel
```

### Developer Usage

```bash
# Open the tunnel (runs in foreground, Ctrl+C to stop)
ssh -L 5432:{{POSTGRES_CLUSTERIP}}:5432 dbtunnel@{{SERVER_IP}}

# In another terminal, connect to the database
psql -h localhost -p 5432 -U {{DB_USER}} -d {{DB_NAME}}
```

### Adding More Developers

Append their public key to the same `authorized_keys` file, each on its own line with the same `restrict,port-forwarding,permitopen=...` prefix.

### Revoking Access

Remove their line from `authorized_keys`. No service restart needed — takes effect on next SSH connection.

---

## Part 3: GHCR imagePullSecret

Private container images on GitHub Container Registry need a pull secret in every namespace that runs pods.

```bash
# Create in each namespace
for NS in {{NAMESPACE}} {{STAGING_NAMESPACE}}; do
  kubectl create secret docker-registry ghcr-secret \
    --docker-server=ghcr.io \
    --docker-username=YOUR_GH_USERNAME \
    --docker-password=YOUR_GHCR_PAT \
    -n "$NS"
done
```

The PAT needs `read:packages` scope (not the full `repo` scope).

Deployments reference it:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: ghcr-secret
```

> **Note:** This secret is **not** managed by Infisical — it's created once per namespace via kubectl. If you rotate the PAT, recreate the secret (delete + create, or `kubectl create ... --dry-run=client -o yaml | kubectl apply -f -`).

---

## Part 4: NODE_ENV Hardening

Set `NODE_ENV=production` explicitly in the Deployment manifest, **not** via `envFrom`:

```yaml
env:
  - name: NODE_ENV
    value: "production"  # Explicit — survives envFrom changes
```

**Why:** If `NODE_ENV` comes from Infisical via `envFrom: secretRef: backend-secrets` and the key is accidentally deleted or the secret sync fails, the app falls back to `development` mode. In development mode:

- Swagger/API docs are publicly accessible
- OTPs may be exposed in API responses
- Error stacks leak internal paths
- Debug logging may include sensitive data

An explicit `env` entry in the Deployment YAML takes precedence over `envFrom` and cannot be silently removed by a secret management change.

---

## Security Checklist

Run through before calling the deployment production-ready:

- [ ] WireGuard installed and running on server
- [ ] Client configs distributed (laptop + phone)
- [ ] Split-DNS configured (dnsmasq or /etc/hosts)
- [ ] ipAllowList middleware applied to admin IngressRoutes
- [ ] externalTrafficPolicy: Local on Traefik service
- [ ] Admin consoles unreachable without VPN (verified from outside)
- [ ] Admin consoles reachable with VPN (verified from inside)
- [ ] NodePort bypass ports closed in hosting provider firewall
- [ ] UDP 51820 open in hosting provider firewall
- [ ] SSH port 22 still open (lockout prevention)
- [ ] dbtunnel user created with restricted port-forwarding
- [ ] GHCR imagePullSecret created in all app namespaces
- [ ] NODE_ENV set explicitly (not via envFrom) in all Deployments
- [ ] All application services using ClusterIP (not NodePort)
- [ ] Nginx security headers configured (X-Frame-Options, HSTS, CSP)
- [ ] Database users scoped with CONNECTION LIMIT
- [ ] No default/seeded passwords active in production

---

**Done.** The cluster is hardened. Review the [Architecture Overview](../docs/01-architecture-overview.md) and [Security doc](../docs/09-security.md) for the full security model.
