# 04 — Infisical (Secret Management)

Install self-hosted Infisical for centralized secrets. The secrets-operator syncs secrets from Infisical to Kubernetes Secrets automatically — no more `kubectl create secret` or secrets in git.

**Time:** ~30 minutes

**Alternative:** If you prefer simpler tooling, see [docs/12-alternatives.md](../docs/12-alternatives.md) for sealed-secrets and external-secrets options.

---

## Part A: Install Infisical

### Pick the right chart — there are two, and they are not interchangeable

```bash
helm repo add infisical https://dl.cloudsmith.io/public/infisical/helm-charts/helm/charts/
helm repo update
helm search repo infisical
```

| Chart | Version | Backend | Use it? |
|-------|---------|---------|---------|
| `infisical/infisical` | 0.4.2 (app 1.17.0) | **MongoDB** | **No.** Legacy. |
| `infisical/infisical-standalone` | 1.11.1 (app v0.167.0) | **PostgreSQL** | **Yes.** |

This matters more than a version bump. The legacy chart takes its configuration from a top-level
`backendEnvironmentVariables` map and has **no** `backend.env` and **no** `backend.resources` keys
at all. Point a modern values file at it and Helm accepts every key without complaint while the
chart ignores all of them — you end up with an Infisical that has an empty `ENCRYPTION_KEY` and no
database connection, and nothing tells you why.

Check before you trust any key, in any chart:

```bash
helm show values infisical/infisical-standalone --version 1.11.1 | grep -nE "^infisical:|kubeSecretRef|^postgresql:|^redis:"
```

### Step 1: The database already exists

`templates/shared/postgres.yaml` created it on first boot, because `vars.env` sets
`DB_NAME={{DB_NAME}}`. Confirm rather than create:

```bash
kubectl -n shared exec postgres-0 -- \
  psql -U {{DB_SUPERUSER}} -d {{DB_NAME}} -tAc "SELECT datname FROM pg_database WHERE datname='{{DB_NAME}}';"
```

Also confirm the application role can **create tables**, or every migration will fail:

```bash
kubectl -n shared exec postgres-0 -- \
  psql -U {{DB_SUPERUSER}} -d {{DB_NAME}} -tAc \
  "SELECT has_schema_privilege('{{DB_USER}}','public','CREATE');"
```

Expected: `t`. If it says `f`, you are on PostgreSQL 15 or newer, where the `public` schema no
longer grants `CREATE` to everyone. Fix it:

```bash
kubectl -n shared exec postgres-0 -- \
  psql -U {{DB_SUPERUSER}} -d {{DB_NAME}} -c "GRANT USAGE, CREATE ON SCHEMA public TO {{DB_USER}};"
```

### Step 2: Namespace

```bash
kubectl create namespace infisical
```

### Step 3: Create the config Secret

This chart reads **all** its configuration from a Kubernetes Secret named by
`infisical.kubeSecretRef`. Every key in that Secret becomes an environment variable on the pod.
Nothing goes into the values file, so nothing sensitive ends up in git.

```bash
REDIS_PW=$(kubectl -n shared get secret redis-auth -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d)
DB_PW='<the {{DB_USER}} password from your password manager>'

kubectl -n infisical create secret generic infisical-secrets \
  --from-literal=ENCRYPTION_KEY="$(openssl rand -hex 16)" \
  --from-literal=AUTH_SECRET="$(openssl rand -base64 32)" \
  --from-literal=DB_CONNECTION_URI="postgresql://{{DB_USER}}:${DB_PW}@postgres.shared.svc.cluster.local:5432/{{DB_NAME}}" \
  --from-literal=REDIS_URL="redis://:${REDIS_PW}@redis.shared.svc.cluster.local:6379" \
  --from-literal=SITE_URL="https://{{INFISICAL_DOMAIN}}"
unset DB_PW REDIS_PW
```

Three things worth noticing:

- `ENCRYPTION_KEY` must be exactly **32 hex characters** (`openssl rand -hex 16`). **Back it up
  now.** Every secret Infisical stores is encrypted with it; lose it and the data is gone, and
  re-installing with a new key leaves you with a database full of unreadable rows.
- `REDIS_URL` carries a password. The Redis from guide 02 requires one, and the empty-username
  form `redis://:password@host` is correct.
- Nothing here is echoed to the terminal, so none of it reaches your shell history.

Confirm the keys without printing the values:

```bash
kubectl -n infisical get secret infisical-secrets -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
```

### Step 4: Install

```bash
helm install infisical infisical/infisical-standalone \
  --namespace infisical \
  --version 1.11.1 \
  -f output/infisical/values.yaml \
  --wait --timeout 10m
```

`templates/infisical/values.yaml` turns off four things. Each one is there for a reason:

| Setting | Why |
|---------|-----|
| `postgresql.enabled: false` | Defaults to **true** — leave it out and you get a second PostgreSQL next to the shared one. |
| `redis.enabled: false` | Same: defaults to **true**. |
| `ingress.enabled: false` | Traefik handles ingress, via `templates/admin-ingress/infisical-ingress.yaml`. |
| `ingress.nginx.enabled: false` | **Read this one twice.** The bundled ingress-nginx subchart is gated on `ingress.nginx.enabled`, *not* on `ingress.enabled`. Set only the latter and you get a complete nginx ingress controller whose LoadBalancer sits at `<pending>` and whose `svclb` pod is stuck `Pending 0/2` forever, because Traefik already holds host ports 80 and 443. |

**Verify:**

```bash
kubectl -n infisical get pods
kubectl get svc -A --field-selector spec.type=LoadBalancer
kubectl get pods -A --field-selector status.phase=Pending
```

Expected: exactly one Infisical pod `1/1 Running`; `traefik` the only LoadBalancer; no Pending
pods anywhere.

Confirm the migrations ran against the shared PostgreSQL:

```bash
kubectl -n shared exec postgres-0 -- \
  psql -U {{DB_SUPERUSER}} -d {{DB_NAME}} -tAc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
```

Expected: several hundred tables. `0` means the app role cannot create tables — go back to step 1.

> **If an install gets interrupted**, the release is left in `pending-install` and every later
> command fails with `another operation (install/upgrade/rollback) is in progress`. Clear it with
> `helm uninstall infisical -n infisical` (your `infisical-secrets` Secret was created with
> `kubectl`, so it survives, and so does the data), or `helm rollback` if there is an earlier
> revision.

### Step 5: Create the first account

```bash
kubectl -n infisical port-forward svc/infisical-infisical-standalone-infisical 8080:8080
```

Open `http://localhost:8080` and register. **The first user becomes the superadmin**, so do this
immediately after install, before the UI is reachable from the internet.

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
