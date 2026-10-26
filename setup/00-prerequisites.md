# 00 — Prerequisites

Everything you need before you start. Complete this checklist first — every later guide assumes these are in place.

---

## VPS Requirements

| Tier | vCPU | RAM | Disk | Use case |
|------|------|-----|------|----------|
| **Minimum** | 4 | 8 GB | 50 GB SSD | Small app, ≤2 replicas, no staging |
| **Recommended** | 8 | 16 GB | 100 GB SSD | Prod + staging, HPA scaling |
| **Production** | 8 | 32 GB | 200 GB+ SSD | Multi-app, full monitoring stack |

Tested providers: Hostinger KVM, Hetzner, DigitalOcean, Linode. Any KVM-based VPS running **Ubuntu 22.04+** works.

> **Avoid OpenVZ/LXC containers** — K3s needs kernel features (cgroups v2, iptables, mount namespaces) that container-based VPS providers don't expose.

## Checklist

### 1. Server access

- [ ] VPS provisioned with Ubuntu 22.04+ (or Debian 12+)
- [ ] Root SSH access working: `ssh root@YOUR_SERVER_IP`
- [ ] SSH key pair generated locally:

```bash
# Generate if you don't have one
ssh-keygen -t ed25519 -C "your@email.com" -f ~/.ssh/id_ed25519_project

# Copy to server
ssh-copy-id -i ~/.ssh/id_ed25519_project root@YOUR_SERVER_IP
```

- [ ] Add to `~/.ssh/config` for convenience:

```
Host myserver
  HostName YOUR_SERVER_IP
  User root
  IdentityFile ~/.ssh/id_ed25519_project
  IdentitiesOnly yes
```

Verify: `ssh myserver 'hostname && uname -r'`

### 2. Domain names

- [ ] At least one domain purchased (e.g., `example.com`)
- [ ] DNS provider access (GoDaddy, Cloudflare, Route53, etc.)
- [ ] Plan your subdomains:

| Subdomain | Purpose |
|-----------|---------|
| `app.example.com` | Production app |
| `staging.example.com` | Staging environment |
| `argocd.example.com` | ArgoCD dashboard |
| `infisical.example.com` | Secret management UI |

Don't create DNS records yet — that comes in [07-tls-dns.md](./07-tls-dns.md).

### 3. GitHub setup

- [ ] GitHub account with access to create private repos
- [ ] Three repos created:

| Repo | Purpose |
|------|---------|
| `your-org/app-backend` | Backend application code + CI |
| `your-org/app-frontend` | Frontend application code + CI |
| `your-org/app-devops` | K8s manifests (ArgoCD watches this) |

- [ ] Personal Access Token (PAT) created with `repo` + `write:packages` scopes:
  - Go to GitHub → Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens
  - Or classic token with `repo`, `write:packages`, `read:packages`
  - Save it — you'll need it for CI and GHCR

### 4. AWS / S3 access

- [ ] AWS account (or S3-compatible: MinIO, Backblaze B2, Wasabi)
- [ ] IAM user with programmatic access for backups (we'll create a scoped policy later in [09-backup.md](./09-backup.md))
- [ ] Note your target region (e.g., `ap-south-1`)

### 5. Local tools

Install these on your **local machine** (the one you develop on):

**macOS (Homebrew):**

```bash
# Kubernetes CLI
brew install kubectl

# Helm (package manager for K8s)
brew install helm

# GitHub CLI
brew install gh

# Infisical CLI
brew install infisical/get-cli/infisical

# Optional but recommended
brew install jq yq
```

**Linux (apt):**

```bash
# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# GitHub CLI
(type -p wget >/dev/null || (sudo apt update && sudo apt-get install wget -y)) \
  && sudo mkdir -p -m 755 /etc/apt/keyrings \
  && out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  && cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
  && sudo apt update \
  && sudo apt install gh -y

# Infisical CLI
curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.deb.sh' | sudo -E bash
sudo apt-get update && sudo apt-get install -y infisical

# jq + yq
sudo apt-get install -y jq
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq
```

**Verify all tools:**

```bash
kubectl version --client -o yaml | head -3
helm version --short
gh --version
infisical --version
jq --version
```

Expected output (versions may differ):

```
clientVersion:
  major: "1"
  minor: "31"
v3.16.3+g3...
gh version 2.x.x
infisical version 0.x.x
jq-1.7
```

### 6. Authenticate GitHub CLI

```bash
gh auth login
# Select: GitHub.com → HTTPS → Paste your PAT

# Verify
gh api user --jq '.login'
```

### 7. Docker (for building images locally)

Only needed for the first manual deploy. After CI is set up, CI builds images.

```bash
# macOS
brew install --cask docker
# Then open Docker Desktop

# Linux
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Log out and back in
```

Verify: `docker run --rm hello-world`

---

## What's next

Once every checkbox above is ticked, proceed to [01-k3s-install.md](./01-k3s-install.md).
