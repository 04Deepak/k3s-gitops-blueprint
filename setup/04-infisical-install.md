# 04 — Infisical (Secret Management)

Install self-hosted Infisical for centralized secrets. The secrets-operator syncs secrets from Infisical to Kubernetes Secrets automatically — no more `kubectl create secret` or secrets in git.

**Time:** ~30 minutes

**Alternative:** If you prefer simpler tooling, see [docs/12-alternatives.md](../docs/12-alternatives.md) for sealed-secrets and external-secrets options.

---

## Part A: Install Infisical

### Step 1: Create database for Infisical

Infisical needs its own PostgreSQL database:

```bash
kubectl -n shared exec -it postgres-0 -- psql -U {{DB_USER}} -d postgres <<'SQL'
CREATE DATABASE infisical;
SQL
```

### Step 2: Create namespace

```bash
kubectl create namespace infisical
```

### Step 3: Add Helm repo

```bash
helm repo add infisical https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/
helm repo update
```

### Step 4: Prepare values

Generate secrets for Infisical itself:

```bash
# Encryption key (32 hex chars)
ENCRYPTION_KEY=$(openssl rand -hex 16)
echo "ENCRYPTION_KEY=$ENCRYPTION_KEY"

# Auth secret (for JWT signing)
AUTH_SECRET=$(openssl rand -base64 32)
echo "AUTH_SECRET=$AUTH_SECRET"
```

> **Save these values somewhere safe** (password manager, not git). You'll need them if you ever redeploy Infisical.

Create a values file:

```bash
cat > /tmp/infisical-values.yaml <<EOF
backend:
  replicaCount: 1
  resources:
    limits:
      memory: 1Gi
      cpu: 1000m
    requests:
      memory: 256Mi
      cpu: 100m
  env:
    - name: ENCRYPTION_KEY
      value: "$ENCRYPTION_KEY"
    - name: AUTH_SECRET
      value: "$AUTH_SECRET"
    - name: DB_CONNECTION_URI
      value: "postgresql://{{DB_USER}}:{{DB_PASSWORD}}@postgres.shared.svc.cluster.local:5432/infisical"
    - name: REDIS_URL
      value: "redis://redis.shared.svc.cluster.local:6379"
    - name: SITE_URL
      value: "https://{{INFISICAL_DOMAIN}}"
    - name: SMTP_HOST
      value: ""
    - name: SMTP_PORT
      value: "587"
    - name: SMTP_FROM_ADDRESS
      value: ""
    - name: SMTP_FROM_NAME
      value: "Infisical"

frontend:
  enabled: false

redis:
  enabled: false

mongodb:
  enabled: false
EOF
```

> We disable frontend (Infisical backend serves the UI), Redis (use shared), and MongoDB (legacy).

### Step 5: Install

```bash
helm install infisical infisical/infisical \
  --namespace infisical \
  -f /tmp/infisical-values.yaml \
  --wait --timeout 5m
```

**Verify:**

```bash
kubectl -n infisical get pods
```

Expected: `infisical-backend-xxx` Running, `1/1`.

### Step 6: Access the UI

Port-forward to access it:

```bash
kubectl -n infisical port-forward svc/infisical-backend 8080:8080
# Open http://localhost:8080
```

- Click "Create an account" → register your admin user
- This first user becomes the superadmin

### Step 7: Create your project

In the Infisical UI:
1. Click "Add New Project" → name it `{{PROJECT_NAME}}`
2. Note the **project ID** (shown in the URL or project settings)
3. Go to the project → Secrets → add your application secrets:

| Key | Example value | Notes |
|-----|---------------|-------|
| `DATABASE_URL` | `postgresql://user:pass@pgbouncer:6432/db` | Via PgBouncer |
| `DIRECT_URL` | `postgresql://user:pass@postgres.shared:5432/db` | Direct, for migrations |
| `REDIS_URL` | `redis://redis.shared:6379` | Shared Redis |
| `JWT_SECRET` | (generate: `openssl rand -base64 48`) | Long random string |
| `JWT_EXPIRY` | `7d` | Token lifetime |
| `NODE_ENV` | `production` | |
| `PORT` | `5000` | Backend port |

Add more as your app needs them. Infisical supports **environments** — create `prod` and `staging` with different values.

---

## Part B: Install Secrets Operator

The operator watches InfisicalSecret CRDs and syncs secrets into Kubernetes Secrets.

### Step 1: Install the operator

```bash
helm install secrets-operator infisical/secrets-operator \
  --namespace infisical \
  --wait
```

**Verify:**

```bash
kubectl -n infisical get pods -l app.kubernetes.io/name=secrets-operator
```

Expected: controller-manager Running.

### Step 2: Create a Machine Identity

In the Infisical UI:
1. Go to **Organization Settings** → **Machine Identities**
2. Click "Create" → name: `k8s-operator`, role: Admin
3. Under the identity → **Authentication** → **Universal Auth**
4. Click "Create credentials" → note the **Client ID** and **Client Secret**

### Step 3: Create the identity secret in each namespace

```bash
# Production namespace
kubectl -n {{NAMESPACE}} create secret generic infisical-machine-identity \
  --from-literal=clientId='YOUR_CLIENT_ID' \
  --from-literal=clientSecret='YOUR_CLIENT_SECRET'

# Staging namespace
kubectl -n {{STAGING_NAMESPACE}} create secret generic infisical-machine-identity \
  --from-literal=clientId='YOUR_CLIENT_ID' \
  --from-literal=clientSecret='YOUR_CLIENT_SECRET'
```

### Step 4: Apply InfisicalSecret CRDs

The templates are at `templates/infisical/`. Apply them:

```bash
kubectl apply -f templates/infisical/secrets.yaml
```

This tells the operator: "sync secrets from Infisical project X, environment Y, into K8s secret Z".

### Step 5: Verify secrets are syncing

Wait 60 seconds (default resync interval), then:

```bash
kubectl -n {{NAMESPACE}} get secret backend-secrets -o jsonpath='{.data}' | jq -r 'keys[]'
```

Expected: list of your secret keys (DATABASE_URL, JWT_SECRET, etc.).

```bash
# Decode a specific value to verify
kubectl -n {{NAMESPACE}} get secret backend-secrets -o jsonpath='{.data.NODE_ENV}' | base64 -d
echo
```

Expected: `production`

### Step 6: Enable auto-reload on Deployments

Add this annotation to your Deployment spec so pods restart when secrets change:

```yaml
metadata:
  annotations:
    secrets.infisical.com/auto-reload: "true"
```

This is already included in the backend deployment template.

---

## How it works end-to-end

```
You update a secret in Infisical UI
        ↓ (within 60 seconds)
Secrets Operator detects the change
        ↓
Operator updates the K8s Secret (backend-secrets)
        ↓ (auto-reload annotation)
Deployment detects secret change
        ↓
Pods are restarted with new secret values
```

---

## Using Infisical CLI locally

For local development or one-off lookups:

```bash
# Login with machine identity
infisical login --method=universal-auth \
  --client-id='YOUR_CLIENT_ID' \
  --client-secret='YOUR_CLIENT_SECRET' \
  --domain='https://{{INFISICAL_DOMAIN}}/api'

# List secrets
infisical secrets list \
  --projectId='YOUR_PROJECT_ID' \
  --env=prod \
  --domain='https://{{INFISICAL_DOMAIN}}/api'

# Get a specific secret
infisical secrets get DATABASE_URL \
  --projectId='YOUR_PROJECT_ID' \
  --env=prod \
  --domain='https://{{INFISICAL_DOMAIN}}/api'
```

---

## Organizing secrets by path

Use paths to scope secrets within a project:

| Path | K8s Secret | Purpose |
|------|-----------|---------|
| `/` | `backend-secrets` | Main app secrets |
| `/pgbouncer` | `pgbouncer-cred` | PgBouncer auth |
| `/backup` | `backup-secrets` | S3 backup credentials |

Each path becomes a separate InfisicalSecret CRD → a separate K8s Secret.

---

## Troubleshooting

### Secrets not syncing

```bash
kubectl -n infisical logs deploy/secrets-operator-controller-manager | tail -20
```

Common causes:
- **Wrong client ID/secret:** Recreate the `infisical-machine-identity` secret
- **Wrong project ID or env:** Check the InfisicalSecret CRD spec
- **Infisical backend unreachable:** Check the `hostAPI` URL in the CRD

### "authentication failed" in operator logs

The machine identity credentials are wrong. Verify by testing locally:

```bash
infisical login --method=universal-auth \
  --client-id='YOUR_CLIENT_ID' \
  --client-secret='YOUR_CLIENT_SECRET' \
  --domain='http://infisical-backend.infisical.svc.cluster.local:8080/api'
```

### Secret keys not appearing

The operator only syncs secrets that exist in the Infisical project for the specified environment and path. Double-check in the Infisical UI that:
- The environment (`prod`/`staging`) matches the CRD
- The path (`/`, `/pgbouncer`, etc.) matches the CRD
- The secrets actually have values (empty secrets are skipped)

---

## What you have now

- Self-hosted Infisical with PostgreSQL backend
- Machine identity for K8s operator authentication
- Secrets syncing from Infisical → K8s Secrets every 60 seconds
- Auto-reload annotation for zero-downtime secret updates
- Path-based secret organization

**Next:** [05-app-deploy.md](./05-app-deploy.md) — deploy your first application.
