# Infisical — Secret Management

## Why Infisical

Kubernetes Secrets are base64-encoded (not encrypted at rest by default), and storing them in git — even sealed — creates operational risk. Infisical provides:

- **Web UI** for non-terminal users to view and edit secrets
- **Audit log** showing who changed what and when
- **Environment separation** (dev/staging/prod) within a single project
- **Kubernetes operator** that syncs secrets to K8s Secrets automatically
- **Machine identity** for programmatic access (CI, scripts)
- **Secret versioning** with rollback

## Self-Hosted Installation

Infisical is deployed via Helm in its own namespace:

```bash
# Add the Helm repo
helm repo add infisical https://dl.infisical.com/helm-charts
helm repo update

# Create namespace
kubectl create namespace infisical

# Install Infisical backend
helm install infisical infisical/infisical \
  --namespace infisical \
  --set backend.replicaCount=1 \
  --set backend.resources.limits.memory=1Gi \
  --values infisical-values.yaml

# Install secrets operator
helm install secrets-operator infisical/secrets-operator \
  --namespace infisical
```

### infisical-values.yaml (key settings)

```yaml
backend:
  replicaCount: 1
  resources:
    limits:
      memory: 1Gi
  env:
    - name: ENCRYPTION_KEY
      value: "<generated-32-byte-hex>"      # openssl rand -hex 16
    - name: AUTH_SECRET
      value: "<generated-jwt-secret>"       # openssl rand -base64 32
    - name: DB_CONNECTION_URI
      value: "postgresql://user:pass@postgres.shared.svc.cluster.local:5432/infisical"
    - name: REDIS_URL
      value: "redis://redis-master.infisical.svc.cluster.local:6379"

mongodb:
  enabled: true  # Legacy from Helm chart — Infisical uses Postgres, but chart still deploys MongoDB

redis:
  enabled: true  # Infisical's own Redis for queues/cache
```

**Critical:** Save the `ENCRYPTION_KEY` and `AUTH_SECRET` somewhere secure (password manager, not git). Losing them means losing access to all encrypted secrets.

### Infisical Database

Infisical stores its metadata in a PostgreSQL database. Create it on the shared instance:

```sql
CREATE DATABASE infisical;
```

Infisical manages its own schema migrations on startup.

## Secrets Operator

The secrets operator watches for `InfisicalSecret` Custom Resources and syncs secrets from the Infisical API to Kubernetes Secrets.

### How It Works

```
InfisicalSecret CRD (in namespace acme)
  │
  │  Operator reads: project, environment, path
  │  Authenticates via machine identity
  │
  ▼
Infisical API → returns secrets for that path
  │
  ▼
Operator creates/updates K8s Secret "backend-secrets"
  │
  │  Every 60 seconds: re-fetch and reconcile
  │
  ▼
Pod reads via envFrom: secretRef: backend-secrets
```

### Resync Interval

The operator polls Infisical every 60 seconds. A secret change in the UI takes at most 60 seconds to reach K8s. The `auto-reload` annotation on Deployments then triggers a rolling restart.

The full secret-change-to-pod-restart latency is approximately:
- 0-60s: Operator detects change
- 0-30s: Operator updates K8s Secret
- 0-60s: Deployment controller detects annotation trigger
- 10-30s: New pod starts and becomes ready
- **Total: 10s to ~3 minutes**

## Machine Identity

Machine identities provide programmatic access to Infisical without user credentials.

### Setup

1. In Infisical UI: **Organization Settings → Machine Identities → Create**
2. Name: `cli-admin`, Auth method: Universal Auth
3. Note the `clientId` and `clientSecret`
4. Grant the identity access to each project

### Kubernetes Secret for the Operator

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: infisical-machine-identity
  namespace: acme
type: Opaque
stringData:
  clientId: "your-client-id"
  clientSecret: "your-client-secret"
```

Create this secret in every namespace that has InfisicalSecret CRDs. The operator uses it to authenticate with the Infisical API.

```bash
# Create in each app namespace
kubectl create secret generic infisical-machine-identity \
  --namespace acme \
  --from-literal=clientId="xxx" \
  --from-literal=clientSecret="yyy"

kubectl create secret generic infisical-machine-identity \
  --namespace acme-staging \
  --from-literal=clientId="xxx" \
  --from-literal=clientSecret="yyy"
```

### CLI Access

```bash
# Login with machine identity
infisical login --method=universal-auth \
  --client-id="xxx" \
  --client-secret="yyy" \
  --domain="https://infisical.example.com/api"

# List secrets
infisical secrets list --env=prod --projectId="project-uuid"

# Get a specific secret
infisical secrets get DATABASE_URL --env=prod --projectId="project-uuid"
```

## InfisicalSecret CRD

The CRD tells the operator which secrets to sync and where:

```yaml
apiVersion: secrets.infisical.com/v1alpha1
kind: InfisicalSecret
metadata:
  name: acme-backend-secrets
  namespace: acme
spec:
  hostAPI: http://infisical-backend.infisical.svc.cluster.local:8080/api
  resyncInterval: 60
  authentication:
    universalAuth:
      secretsScope:
        projectSlug: acme-platform-x1y2z
        envSlug: prod
        secretsPath: "/"
      credentialsRef:
        secretName: infisical-machine-identity
        secretNamespace: acme
  managedSecretReference:
    secretName: backend-secrets
    secretNamespace: acme
    creationPolicy: Owner
```

### Fields Explained

| Field | Purpose |
|-------|---------|
| `hostAPI` | Infisical API endpoint (in-cluster URL) |
| `resyncInterval` | Seconds between re-fetches (60 = poll every minute) |
| `projectSlug` | Infisical project identifier |
| `envSlug` | Environment: `dev`, `staging`, or `prod` |
| `secretsPath` | Path within the project (`/`, `/pgbouncer`, `/backup`) |
| `credentialsRef` | Points to the K8s Secret holding machine identity credentials |
| `managedSecretReference` | The K8s Secret to create/update |
| `creationPolicy: Owner` | Operator owns the Secret — deleting the CRD deletes the Secret |

### Secret Organization by Path

Use paths to scope secrets for different consumers:

| Path | K8s Secret | Consumer | Contains |
|------|-----------|----------|----------|
| `/` | `backend-secrets` | Backend Deployment + CronJobs | DATABASE_URL, JWT_SECRET, AWS keys, REDIS_URL, etc. |
| `/pgbouncer` | `acme-prod-svc-cred` | PgBouncer | Database user credentials for PgBouncer auth |
| `/backup` | `backup-secrets` | Backup CronJob | AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_BUCKET |

**Why paths:** The backup CronJob should not have access to JWT_SECRET. PgBouncer should not have access to AWS keys. Paths enforce least-privilege at the secret-management level.

## Auto-Reload Annotation

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  annotations:
    secrets.infisical.com/auto-reload: "true"
```

When the operator updates the `backend-secrets` K8s Secret (because a value changed in Infisical), it checks for Deployments with this annotation and triggers a rolling restart.

**Without this annotation:** Pods keep running with stale secrets until manually restarted. The K8s Secret is updated, but running pods don't re-read environment variables.

**With this annotation:** The operator patches the Deployment's pod template (typically adding/updating a hash annotation), triggering a rolling restart that picks up the new values.

## Project/Environment Organization

### Recommended Structure

```
Infisical Organization
├── Project: "my-platform"
│   ├── Environment: dev
│   │   ├── / (root)          → 18 secrets (all app secrets)
│   │   ├── /pgbouncer        → 2 secrets (DB user for PgBouncer)
│   │   └── /backup           → 3 secrets (S3 credentials)
│   ├── Environment: staging
│   │   ├── /                  → 18 secrets (staging values)
│   │   ├── /pgbouncer        → 2 secrets
│   │   └── /backup           → 3 secrets
│   └── Environment: prod
│       ├── /                  → 18 secrets (production values)
│       ├── /pgbouncer        → 2 secrets
│       └── /backup           → 3 secrets
└── Project: "community-app"
    └── Environment: prod
        ├── /user-svc          → service-specific secrets
        ├── /chat-svc
        ├── /forum-svc
        ├── /notif-svc
        └── /admin
```

### Naming Conventions

- **Project slug:** `my-platform-xxx` (auto-generated, stable)
- **Environment slug:** `dev`, `staging`, `prod` (match K8s namespace intent)
- **Secret names:** SCREAMING_SNAKE_CASE (`DATABASE_URL`, `JWT_SECRET`)
- **Paths:** kebab-case with leading slash (`/pgbouncer`, `/backup`)

## Alternatives Comparison

| Feature | Infisical | Sealed Secrets | External Secrets Operator |
|---------|-----------|---------------|--------------------------|
| UI | Yes (web) | No | No |
| Audit log | Yes | No | Via provider (AWS SM, etc.) |
| Self-hosted | Yes | Yes | Yes |
| Secret rotation | Manual via UI/API | Re-encrypt and commit | Via provider |
| K8s integration | Native operator | Controller + kubeseal CLI | Controller + provider |
| Cost (self-hosted) | Free (open source) | Free | Free + provider costs |
| Learning curve | Low (UI-driven) | Medium (CLI + git workflow) | Medium (provider config) |
| External dependency | PostgreSQL + Redis | None (in-cluster only) | Cloud provider (AWS SM, Vault) |

**When to choose Infisical:** Team needs a UI, audit logging, and doesn't want to manage a Vault cluster. Good for small-to-medium teams where operational simplicity matters.

**When to choose Sealed Secrets:** Git-native workflow is paramount. No external dependencies. Team is comfortable with CLI-only secret management.

**When to choose External Secrets Operator:** Already using AWS Secrets Manager, HashiCorp Vault, or Google Secret Manager. Want to centralize secrets across K8s and non-K8s workloads.

## Troubleshooting

```bash
# Check operator logs
kubectl logs -n infisical deploy/secrets-operator-controller-manager -f

# Check if InfisicalSecret is syncing
kubectl get infisicalsecret -n acme -o wide

# Check the managed K8s Secret
kubectl get secret backend-secrets -n acme -o yaml

# Decode a specific secret value
kubectl get secret backend-secrets -n acme -o jsonpath='{.data.DATABASE_URL}' | base64 -d

# Force re-sync (delete and recreate the managed secret)
kubectl delete secret backend-secrets -n acme
# Operator will recreate it within 60 seconds
```
