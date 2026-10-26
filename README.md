# K3s GitOps Blueprint

Production-style K3s infrastructure blueprint with working templates, architecture docs, and step-by-step setup guides: bare VPS to a GitOps-driven cluster with TLS, secrets management, connection pooling, autoscaling and backups.

The patterns come from running self-hosted K3s + ArgoCD clusters, including fixes for real problems: cleartext NodePort traffic, rate limiting behind a proxy, hardcoded build secrets and race conditions in GitOps pushes.

All names, domains and IPs here are fictional examples (`acme`, `example.com`, `203.0.113.10`). Replace them in `templates/vars.env`.

## What's Inside

| Directory | Purpose | Count |
|-----------|---------|-------|
| `docs/` | Architecture documentation — how everything works and why | 12 docs |
| `setup/` | Step-by-step guides — bare VPS to production cluster | 13 guides |
| `templates/` | Working K8s manifests + CI/CD with `{{PLACEHOLDER}}` tokens | 42 files |
| `overlay/` | Prisma/Express/Vite-specific patterns and Dockerfiles | 6 files |

## Quick Start

1. **Clone this repo**
2. **Fill in your values** in `templates/vars.env`
3. **Run `templates/init.sh`** — generates a ready-to-use `output/` directory (needs bash 4+; on macOS: `brew install bash`)
4. **Follow `setup/` guides in order** (00 → 12) to stand up infrastructure
5. **Push `output/`** as your project's devops repo — ArgoCD takes it from there

## Stack

| Component | Technology | Purpose |
|-----------|-----------|---------|
| Orchestration | K3s | Lightweight Kubernetes (single-node production) |
| Ingress | Traefik | L7 routing, TLS termination (bundled with K3s) |
| GitOps | ArgoCD | Automated sync from git, PreSync/PostSync hooks |
| Secrets | Infisical | Self-hosted, UI, audit log, K8s operator sync |
| Database | PostgreSQL 16 + PgBouncer | Persistent storage + connection pooling |
| Cache/Pub-Sub | Redis 7 | SSE fan-out, rate-limit counters |
| CI/CD | GitHub Actions → GHCR | Build, test, push images, GitOps manifest update |
| Backup | pg_dump → S3 | Object Lock, isolated IAM, Glacier archival |
| Scaling | HPA + PDB | CPU-based autoscaling with disruption budgets |
| Monitoring | Prometheus + Grafana + Alertmanager | Metrics, dashboards, Slack alerts (kube-prometheus-stack) |
| Security | WireGuard + ClusterIP + scoped DB users | Defense in depth |

## Architecture at a Glance

```
                    ┌─────────────────────────────────────────────────┐
                    │                    Internet                     │
                    └────────────────────┬────────────────────────────┘
                                         │ :443 / :80
                    ┌────────────────────▼────────────────────────────┐
                    │              Traefik (K3s)                      │
                    │         TLS termination · L7 routing            │
                    │    Let's Encrypt certResolver (auto-renew)      │
                    └──────┬──────────────────────────┬───────────────┘
                           │ PathPrefix(/api)         │ fallback (/)
                    ┌──────▼──────┐            ┌──────▼──────┐
                    │   Backend   │            │  Frontend   │
                    │  (2-8 pods) │            │ (1 pod,     │
                    │  Node.js    │            │  nginx SPA) │
                    │  HPA + PDB  │            └─────────────┘
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
       ┌──────▼──────┐ ┌──▼───┐ ┌──────▼──────┐
       │  PgBouncer   │ │Redis │ │     S3      │
       │ (2 replicas) │ │  7   │ │  (uploads)  │
       │  txn pooling │ └──────┘ └─────────────┘
       └──────┬───────┘
              │
       ┌──────▼──────┐
       │ PostgreSQL   │     ┌─────────────────────────────────────┐
       │  16-alpine   │     │           GitOps Flow               │
       │ (StatefulSet)│     │                                     │
       └──────────────┘     │  git push → GitHub Actions          │
                            │    → Docker build → GHCR            │
                            │    → update image tag in devops repo│
                            │    → ArgoCD auto-sync → K8s         │
                            │                                     │
                            │  Infisical ──operator──→ K8s Secret │
                            │    → envFrom: secretRef → pod env   │
                            └─────────────────────────────────────┘
```

## Template Placeholders

All templates use `{{PLACEHOLDER}}` syntax. Edit `templates/vars.env` — it's the single source of truth. Run `templates/init.sh` to replace all tokens and generate your output.

See [`templates/vars.env`](templates/vars.env) for the full variable list with descriptions.

## Docs Index

| # | Doc | Covers |
|---|-----|--------|
| 01 | [Architecture Overview](docs/01-architecture-overview.md) | System diagram, component map, data flow |
| 02 | [Networking](docs/02-networking.md) | Traefik, IngressRoutes, TLS, DNS |
| 03 | [Databases](docs/03-databases.md) | PostgreSQL, PgBouncer, backup strategy |
| 04 | [Redis](docs/04-redis.md) | Config, key conventions, shared usage |
| 05 | [ArgoCD](docs/05-argocd.md) | GitOps flow, apps, hooks, sync |
| 06 | [Infisical](docs/06-infisical.md) | Secrets, operator, machine identity |
| 07 | [CI/CD](docs/07-cicd.md) | GitHub Actions → GHCR → GitOps → ArgoCD |
| 08 | [Scaling](docs/08-scaling.md) | HPA, PDB, resource budgets |
| 09 | [Security](docs/09-security.md) | TLS, WireGuard, rate limiting, hardening |
| 10 | [CronJobs](docs/10-cronjobs.md) | CLI runner pattern, backup, scheduling |
| 11 | [Monitoring](docs/11-monitoring.md) | Health checks, metrics, alerting, what is planned |
| 12 | [Alternatives](docs/12-alternatives.md) | Technology choices and when to pick differently |

## Setup Guides Index

| # | Guide | What You Get |
|---|-------|-------------|
| 00 | [Prerequisites](setup/00-prerequisites.md) | Tools installed, accounts ready |
| 01 | [K3s Install](setup/01-k3s-install.md) | Running Kubernetes cluster |
| 02 | [Shared Services](setup/02-shared-services.md) | PostgreSQL + Redis deployed |
| 03 | [ArgoCD Install](setup/03-argocd-install.md) | GitOps controller running |
| 04 | [Infisical Install](setup/04-infisical-install.md) | Secret management operational |
| 05 | [App Deploy](setup/05-app-deploy.md) | First application live |
| 06 | [CI/CD Setup](setup/06-cicd-setup.md) | Automated build + deploy pipeline |
| 07 | [TLS & DNS](setup/07-tls-dns.md) | HTTPS with Let's Encrypt |
| 08 | [PgBouncer](setup/08-pgbouncer.md) | Connection pooling active |
| 09 | [Backup](setup/09-backup.md) | Automated S3 backups running |
| 10 | [Scaling](setup/10-scaling.md) | HPA + PDB configured |
| 11 | [Security Hardening](setup/11-security-hardening.md) | VPN, firewall, access control |
| 12 | [Monitoring](setup/12-monitoring.md) | Prometheus, Grafana, Slack alerts |

## Overlay

The `overlay/` directory adds patterns specific to **Prisma + Express + Vite React** projects:

- Enhanced Dockerfiles (backend with Prisma, frontend with Vite + Nginx)
- Nginx config with SPA routing + API proxy + security headers
- CronJob CLI runner pattern documentation
- GitOps push pattern documentation

These are optional — the base templates work for any containerized web application.

## License

MIT. See [LICENSE](LICENSE). Provided as-is: review every manifest and harden it for your own environment before using it in production.
