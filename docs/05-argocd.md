# ArgoCD — GitOps Continuous Delivery

## GitOps Philosophy

The devops repository is the single source of truth for cluster state. Every Kubernetes resource — Deployments, Services, CronJobs, IngressRoutes, InfisicalSecrets — is defined as YAML in git. ArgoCD watches the repo and continuously reconciles the cluster to match.

**Rules:**
1. Never `kubectl apply` a manifest that ArgoCD manages — ArgoCD will revert it on the next sync (selfHeal)
2. To change cluster state, commit to git → ArgoCD syncs automatically
3. `kubectl` is for read-only diagnostics unless explicitly stated otherwise
4. Resources not tracked by any ArgoCD Application are unmanaged — changes to them stick

## Installation

ArgoCD is installed via its official manifests:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### Initial Admin Password

```bash
# Get the auto-generated admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

Change this password immediately after first login. Consider disabling the local admin account entirely once SSO is configured.

### Insecure Mode (Traefik Terminates TLS)

ArgoCD's server runs in insecure mode because Traefik handles TLS termination:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
data:
  server.insecure: "true"
```

This means:
- ArgoCD serves HTTP (not HTTPS) on port 8080
- Traefik's IngressRoute terminates TLS and proxies to ArgoCD
- CLI access requires `--plaintext` flag

```bash
# CLI login (via kubectl exec, in-cluster)
kubectl exec -n argocd deploy/argocd-server -- \
  argocd login localhost:8080 --plaintext --username admin --password "$ARGOCD_PASSWORD"
```

## Application CRDs

Each tracked component gets its own ArgoCD Application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: acme-platform-backend
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:org/project-devops.git
    targetRevision: main
    path: backend
  destination:
    server: https://kubernetes.default.svc
    namespace: acme
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Application Inventory

| Application | Source Path | Namespace | Purpose |
|------------|-----------|-----------|---------|
| `acme-platform-backend` | `backend/` | `acme` | Prod backend + PgBouncer + CronJobs + backup |
| `acme-platform-frontend` | `frontend/` | `acme` | Prod frontend |
| `acme-staging-backend` | `staging/backend/` | `acme-staging` | Staging backend |
| `acme-staging-frontend` | `staging/frontend/` | `acme-staging` | Staging frontend |
| `acme-staging-infra` | `staging/` | `acme-staging` | Staging namespace, secrets, ingress |
| `acme-admin-ingress` | `admin-ingress/` | `argocd` | ArgoCD + Infisical IngressRoutes |
| `community-app` | `communityapp/` | `communityapp` | Community microservices |

### Application-Per-Component Pattern

Why separate Applications instead of one monolith:
- **Independent sync:** Frontend can sync without touching backend
- **Granular status:** "backend is degraded, frontend is healthy"
- **Selective rollback:** Revert backend without affecting frontend
- **Path-based:** Each Application watches a specific directory in the devops repo

## Sync Policy

### Automated Sync

```yaml
syncPolicy:
  automated:
    prune: true      # Delete resources removed from git
    selfHeal: true   # Revert manual kubectl changes
```

- **prune: true** — If you remove a YAML file from the devops repo, ArgoCD deletes the corresponding K8s resource. Without this, removed resources linger forever.
- **selfHeal: true** — If someone runs `kubectl edit` or `kubectl apply` on a managed resource, ArgoCD detects the drift and reverts it within ~3 minutes. This guarantees git = cluster.

### What selfHeal Means in Practice

```bash
# This change WILL be reverted by ArgoCD:
kubectl -n acme set image deployment/backend backend=ghcr.io/org/app-be:manual-tag

# Within ~3 minutes, ArgoCD syncs and restores the image tag from git
```

To make a change stick, commit it to the devops repo. ArgoCD watches for changes every 3 minutes (configurable) and syncs automatically.

## Hooks — PreSync and PostSync

ArgoCD hooks run Jobs at specific points in the sync lifecycle.

### PreSync — Database Migrations

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: backend-migrate
  namespace: acme
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  activeDeadlineSeconds: 600
  template:
    spec:
      containers:
        - name: migrate
          image: ghcr.io/org/app-be:latest  # Same image as the Deployment
          command: ["npx", "prisma", "migrate", "deploy"]
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: backend-secrets
                  key: DIRECT_URL  # Bypass PgBouncer for migrations
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { cpu: 500m, memory: 512Mi }
      restartPolicy: Never
```

**Why PreSync:** Migrations must complete BEFORE new pods start. If new code expects a column that doesn't exist yet, requests fail. PreSync guarantees the schema is ready before the rolling update begins.

**Why DIRECT_URL:** Prisma migrations use advisory locks that require a persistent connection. PgBouncer's transaction pooling releases connections between transactions, breaking the lock. DIRECT_URL connects straight to PostgreSQL.

### PostSync — Database Seeding

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: backend-seed
  namespace: acme
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  activeDeadlineSeconds: 120
  template:
    spec:
      containers:
        - name: seed
          command: ["npx", "tsx", "prisma/seed.ts"]
          # ... same env pattern as migrate
      restartPolicy: Never
```

**Why PostSync:** Seeding runs after the new code is deployed. It upserts reference data (roles, default config) that the new code expects. Running it PreSync would fail if the seed script references new models.

### hook-delete-policy: BeforeHookCreation

This annotation tells ArgoCD to delete the old Job before creating a new one on the next sync. Without it, the Job from the previous sync lingers, and the new sync either fails (name conflict) or skips the hook.

### Sync Flow with Hooks

```
1. CI pushes new image tag to devops repo
2. ArgoCD detects change (polling or webhook)
3. PreSync: backend-migrate Job runs
   - Applies pending migrations against DIRECT_URL
   - Must exit 0 to proceed (exit 1 = sync fails, rollout aborted)
4. Sync: Rolling update
   - New pods start with updated image
   - Old pods terminate after readiness check
5. PostSync: backend-seed Job runs
   - Upserts reference data
   - Failure here doesn't roll back the deployment
```

## CLI Access

ArgoCD CLI operates via `kubectl exec` from within the cluster:

```bash
# Login
kubectl exec -n argocd deploy/argocd-server -- \
  argocd login localhost:8080 --plaintext --username admin --password "$PASS"

# Trigger a sync
kubectl exec -n argocd deploy/argocd-server -- \
  argocd app sync acme-platform-backend

# Sync and wait for health
kubectl exec -n argocd deploy/argocd-server -- \
  argocd app sync acme-platform-backend --timeout 300

# Check app status
kubectl exec -n argocd deploy/argocd-server -- \
  argocd app get acme-platform-backend

# List all apps
kubectl exec -n argocd deploy/argocd-server -- \
  argocd app list
```

### From CI

The deploy step in GitHub Actions uses the same pattern via SSH:

```bash
ssh server "kubectl exec -n argocd deploy/argocd-server -- \
  argocd login localhost:8080 --plaintext --username admin --password \$ARGOCD_PASSWORD && \
  argocd app sync acme-platform-backend --timeout 300"
```

Some deployments rely on ArgoCD's auto-sync instead of an explicit sync command. The frontend, for example, just pushes the image tag update to git and lets ArgoCD pick it up within 3 minutes.

## Troubleshooting

### Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| App stuck in "Progressing" | Pod can't pull image or crashes | `kubectl -n acme describe pod <name>` |
| App shows "OutOfSync" but won't sync | Webhook/admission controller rejecting | `argocd app sync <name> --force` |
| Hook Job failed | Migration error or timeout | `kubectl -n acme logs job/backend-migrate` |
| Manual change reverted | selfHeal is working correctly | Commit the change to git instead |
| Resource not tracked | Not in an Application's path | Add to the correct directory in the devops repo |

### Useful Commands

```bash
# Check sync status of all apps
kubectl exec -n argocd deploy/argocd-server -- argocd app list --plaintext

# View sync history
kubectl exec -n argocd deploy/argocd-server -- argocd app history acme-platform-backend --plaintext

# View differences between git and cluster
kubectl exec -n argocd deploy/argocd-server -- argocd app diff acme-platform-backend --plaintext

# Hard refresh (re-read git)
kubectl exec -n argocd deploy/argocd-server -- argocd app get acme-platform-backend --refresh --plaintext
```

## Unmanaged Resources

Resources not covered by any ArgoCD Application are "unmanaged" — ArgoCD doesn't track or sync them. Changes via `kubectl apply` stick permanently.

In this setup, the following are typically unmanaged:
- `shared/` namespace resources (Postgres, Redis) — if not tracked by an Application
- GHCR pull secrets (`ghcr-secret` per namespace)
- PgBouncer auth secrets
- Namespace resources themselves (if `CreateNamespace=true` isn't set)

**Recommendation:** Track everything possible under an ArgoCD Application. Unmanaged resources are the "git says one thing, cluster says another" class of problems.
