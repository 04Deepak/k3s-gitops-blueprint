# Architecture Overview

This document describes the full production stack for a multi-environment web application running on a single-node K3s cluster. The system serves a Node.js/Express backend and a Vite/React frontend behind Traefik, with PostgreSQL, Redis, PgBouncer, ArgoCD for GitOps, and Infisical for secrets management.

## System Diagram

```
                            Internet
                               │
                         ┌─────┴─────┐
                         │  DNS (A)  │
                         │ GoDaddy   │
                         └─────┬─────┘
                               │
                    ┌──────────┴──────────┐
                    │   Hostinger KVM8    │
                    │  203.0.113.10     │
                    │  32GB / 8 vCPU      │
                    │  Ubuntu + K3s       │
                    └──────────┬──────────┘
                               │
              ┌────────────────┴────────────────┐
              │         Traefik (K3s)           │
              │   :80 (redirect) / :443 (TLS)   │
              │   Let's Encrypt certResolver    │
              └───────┬────────────┬────────────┘
                      │            │
         ┌────────────┴──┐   ┌────┴────────────┐
         │ IngressRoute  │   │  IngressRoute   │
         │ /api/* → BE   │   │  /* → FE        │
         └───────┬───────┘   └────┬────────────┘
                 │                │
    ┌────────────┴───┐   ┌───────┴────────┐
    │   Backend      │   │   Frontend     │
    │   (2-8 pods)   │   │   (1 pod)      │
    │   Express/Node │   │   Nginx + SPA  │
    │   HPA: CPU 80% │   │   /api proxy   │
    └───┬────┬───┬───┘   └────────────────┘
        │    │   │
   ┌────┘    │   └────────┐
   │         │            │
   ▼         ▼            ▼
┌──────┐  ┌──────┐  ┌──────────┐
│Redis │  │PgBnc │  │Infisical │
│:6379 │  │:6432 │  │ Operator │
│shared│  │(2x)  │  │  60s     │
└──┬───┘  └──┬───┘  └────┬─────┘
   │         │            │
   │    ┌────┴────┐  ┌────┴─────────┐
   │    │Postgres │  │  Infisical   │
   │    │:5432    │  │  Backend     │
   │    │shared   │  │  :30080      │
   │    │(1 pod)  │  └──────────────┘
   │    └─────────┘
   │
   └─── SSE pub/sub + rate-limit counters
```

## Component Inventory

| Component | Namespace | Purpose | Replicas |
|-----------|-----------|---------|----------|
| Backend (Express/Node) | `acme` | API server, business logic | 2-8 (HPA) |
| Frontend (Nginx + SPA) | `acme` | Static files, SPA routing, /api proxy | 1 |
| PgBouncer | `acme` | Connection pooling for Postgres | 2 |
| PostgreSQL 16 | `shared` | Primary data store | 1 (StatefulSet) |
| Redis 7 | `shared` | SSE fan-out, rate-limit counters | 1 |
| ArgoCD | `argocd` | GitOps continuous delivery | 1 |
| Infisical | `infisical` | Secret management + K8s operator | 1 |
| Traefik | `kube-system` | Ingress controller, TLS termination | 1 (K3s bundled) |
| 6 CronJobs | `acme` | Scheduled tasks (TAT, cleanup, backup) | 0-1 per schedule |
| Backup CronJob | `acme` | pg_dump → S3 | 0-1 per schedule |

Staging mirrors prod in `acme-staging` with identical components at lower resource limits.

## Namespace Layout

```
kube-system/        K3s internals + Traefik
shared/             PostgreSQL StatefulSet + Redis Deployment (shared by all apps)
acme/                Production: backend, frontend, PgBouncer, CronJobs, backup
acme-staging/        Staging: identical layout, lower resources, separate DB
communityapp/       Separate project: 5 microservices sharing Postgres + Redis
argocd/             ArgoCD server + controllers
infisical/          Infisical backend + secrets-operator
```

Namespaces isolate workloads logically. There are no NetworkPolicies enforced — all pods can reach all pods across namespaces. Cross-namespace database access uses the fully-qualified DNS name (`redis.shared.svc.cluster.local`).

## Traffic Flow

### User Request Path

```
User (browser)
  → DNS A record (app.example.com → 203.0.113.10)
  → Traefik :443 (TLS termination via Let's Encrypt)
  → IngressRoute rules:
      PathPrefix(/api)  → backend-service:5000 (ClusterIP)
      PathPrefix(/)     → frontend-service:80 (ClusterIP)
  → Frontend pod (nginx):
      /api/*            → proxy_pass http://backend-service:5000/api/
      /*                → try_files $uri $uri/ /index.html (SPA fallback)
  → Backend pod:
      req.headers.authorization → JWT verified
      → PgBouncer :6432 → PostgreSQL :5432
      → Redis :6379 (rate-limit check, SSE publish)
```

Two layers resolve `/api` requests: Traefik routes `/api` to the backend Service directly, and nginx inside the frontend pod also proxies `/api` to the backend. The Traefik route takes precedence; the nginx proxy serves as a fallback for SPA-embedded API calls.

### WebSocket / SSE Path

SSE (Server-Sent Events) connections from the browser reach the backend via the same `/api` IngressRoute. The backend uses Redis Pub/Sub to fan out events across all backend replicas — when pod A publishes a notification, pods B through H receive it and push to their connected SSE clients.

## Deploy Flow

```
Developer pushes to GitHub
  │
  ├─ Push to `dev` branch → CI deploys to STAGING
  └─ Push to `main` branch → CI deploys to PRODUCTION
  │
  ▼
GitHub Actions workflow:
  1. test        → npm ci → typecheck → lint → test → build
  2. integration → Postgres in Docker → prisma migrate → integration tests
  3. build-push  → Docker Buildx → push to GHCR (ghcr.io/org/app-be:<sha>)
  4. deploy      → Clone devops repo
                 → sed -i update image tag in deployment.yaml
                 → git pull --rebase + git push (3 retries for race protection)
                 → ArgoCD detects change → auto-sync
  │
  ▼
ArgoCD sync pipeline:
  1. PreSync hook  → Job: prisma migrate deploy (against DIRECT_URL, bypassing PgBouncer)
  2. Sync          → Rolling update of Deployment (new image tag)
  3. PostSync hook → Job: prisma seed (upsert reference data)
  │
  ▼
Kubernetes rolling update:
  - New pods start with updated image
  - Readiness probe passes → old pods terminate
  - HPA adjusts replica count based on CPU
```

### GitOps Push Race Protection

When backend and frontend CI run concurrently, both try to push image tag updates to the same devops repo. Without protection, the second push fails (non-fast-forward) or silently reverts the first push's change.

The solution: each deploy step does `git pull --rebase` before pushing, with a 3-attempt retry loop. If all 3 attempts fail, the job exits with code 1 (not silently).

```bash
for attempt in 1 2 3; do
  git pull --rebase origin main
  if git push origin main; then
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    echo "ERROR: All 3 push attempts failed"
    exit 1
  fi
  sleep $((attempt * 2))
done
```

## Secrets Flow

```
Infisical UI (browser)
  │
  │  Secrets stored per project + environment + path
  │  e.g., project "acme-platform", env "prod", path "/"
  │
  ▼
Infisical Secrets Operator (in-cluster)
  │
  │  Watches InfisicalSecret CRDs
  │  Authenticates via machine identity (clientId + clientSecret)
  │  Polls every 60 seconds
  │
  ▼
Kubernetes Secret (e.g., "backend-secrets" in namespace "acme")
  │
  │  envFrom: secretRef: backend-secrets  (in Deployment spec)
  │
  ▼
Pod environment variables
  │
  │  DATABASE_URL, JWT_SECRET, AWS_ACCESS_KEY_ID, REDIS_URL, etc.
  │
  ▼
Application reads process.env.*
```

### Auto-Reload

Deployments carry the annotation `secrets.infisical.com/auto-reload: "true"`. When the operator detects a secret value change in Infisical, it updates the K8s Secret and triggers a rolling restart of annotated Deployments. No manual restart needed.

### Secret Organization

Secrets are organized by Infisical path within each project:

| Path | K8s Secret | Used By |
|------|-----------|---------|
| `/` | `backend-secrets` | Backend Deployment + CronJobs |
| `/pgbouncer` | `acme-prod-svc-cred` | PgBouncer auth |
| `/backup` | `backup-secrets` | Backup CronJob (S3 credentials) |

This separation ensures the backup job cannot read application secrets, and PgBouncer auth is isolated from the main application secret bundle.

## Environment Parity

Staging mirrors production with these differences:

| Aspect | Production | Staging |
|--------|-----------|---------|
| Namespace | `acme` | `acme-staging` |
| Domain | `app.example.com` | `staging.example.com` |
| Database | `acme_platform` | `acme_platform_staging` |
| Infisical env | `prod` | `staging` |
| Backend resources | 250m-1500m / 384Mi-1536Mi | 250m-1500m / 384Mi-1536Mi |
| Frontend resources | 50m-200m / 64Mi-128Mi | 25m-100m / 32Mi-64Mi |
| HPA | 2-8 replicas | 2-8 replicas |
| Deploy trigger | Push to `main` | Push to `dev` |

Both environments use the same Docker images, just different tags. Staging gets the image first (from `dev` branch), production gets it after promotion (`main` branch).

## Key Design Decisions

1. **Single-node K3s over managed K8s** — Cost. A single Hostinger VPS at ~$25/mo vs $200+/mo for EKS/GKE. The trade-off is no built-in HA — a node failure takes everything down. Mitigated by automated backups and a documented recovery procedure.

2. **ArgoCD over kubectl-apply CI** — GitOps gives an audit trail, self-healing (drift correction), and a UI for the team. The devops repo IS the cluster state — no "what's actually running?" questions.

3. **Infisical over K8s Secrets in git** — Secrets in git (even encrypted/sealed) are a liability. Infisical gives a UI, audit log, rotation, and the operator syncs to K8s automatically.

4. **PgBouncer over direct connections** — With 2-8 backend replicas, each opening Prisma's default 10 connections, you'd exhaust a 100-connection PostgreSQL budget fast. PgBouncer's transaction pooling multiplexes 1000 client connections over 12 server connections.

5. **Shared PostgreSQL instance** — One StatefulSet serves 4 databases (prod, staging, community, infisical). Cost-efficient but creates a blast radius — a Postgres restart affects everything. Mitigated by scoped users with connection limits.

6. **ClusterIP over NodePort** — NodePort exposes services on every node's IP at a high port, bypassing TLS. ClusterIP restricts access to in-cluster traffic, forcing everything through Traefik's TLS termination.
