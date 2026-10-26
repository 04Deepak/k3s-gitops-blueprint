# 02 — Shared Services (PostgreSQL + Redis)

Deploy PostgreSQL and Redis into the `shared` namespace. Both are accessed by the app via cross-namespace DNS (`service.shared.svc.cluster.local`).

**Time:** ~15 minutes

---

## Part A: PostgreSQL

### Step 1: Apply the PostgreSQL manifest

The template is at `templates/shared/postgres.yaml`. If you ran `init.sh`, your placeholders are already filled. Otherwise, update `{{DB_NAME}}`, `{{DB_USER}}`, `{{DB_PASSWORD}}` manually.

```bash
kubectl apply -f templates/shared/postgres.yaml
```

### Step 2: Wait for the StatefulSet

```bash
kubectl -n shared get statefulset postgres -w
```

Wait until `READY` shows `1/1`:

```
NAME       READY   AGE
postgres   1/1     45s
```

If it stays at `0/1`, check events:

```bash
kubectl -n shared describe pod postgres-0
```

### Step 3: Verify PostgreSQL is running

```bash
kubectl -n shared exec -it postgres-0 -- psql -U {{DB_USER}} -d postgres -c "SELECT version();"
```

Expected: `PostgreSQL 16.x ...`

### Step 4: Create application databases

```bash
kubectl -n shared exec -it postgres-0 -- psql -U {{DB_USER}} -d postgres <<'SQL'
-- Production database
CREATE DATABASE {{DB_NAME}};

-- Staging database
CREATE DATABASE {{DB_NAME}}_staging;

-- Verify
\l
SQL
```

### Step 5: Create scoped database users

Don't let the app connect as the superuser. Create scoped users with connection limits:

```bash
kubectl -n shared exec -it postgres-0 -- psql -U {{DB_USER}} -d postgres <<'SQL'
-- Production app user
CREATE USER app_prod_svc WITH PASSWORD 'GENERATE_A_STRONG_PASSWORD' CONNECTION LIMIT 50;
GRANT CONNECT ON DATABASE {{DB_NAME}} TO app_prod_svc;

-- Connect to the prod database to grant schema access
\c {{DB_NAME}}
GRANT USAGE ON SCHEMA public TO app_prod_svc;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_prod_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_prod_svc;

-- Staging app user
\c postgres
CREATE USER app_staging_svc WITH PASSWORD 'GENERATE_ANOTHER_PASSWORD' CONNECTION LIMIT 40;
GRANT CONNECT ON DATABASE {{DB_NAME}}_staging TO app_staging_svc;

\c {{DB_NAME}}_staging
GRANT USAGE ON SCHEMA public TO app_staging_svc;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_staging_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_staging_svc;

-- Dev/read-only user (for tunnel access)
\c postgres
CREATE USER dev_readonly WITH PASSWORD 'GENERATE_ANOTHER_PASSWORD' CONNECTION LIMIT 10;
GRANT CONNECT ON DATABASE {{DB_NAME}} TO dev_readonly;
GRANT CONNECT ON DATABASE {{DB_NAME}}_staging TO dev_readonly;
SQL
```

### Step 6: Verify the ClusterIP service

```bash
kubectl -n shared get svc postgres
```

Expected:

```
NAME       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
postgres   ClusterIP   10.43.x.x       <none>        5432/TCP   2m
```

> **Pin the ClusterIP** if you'll use SSH tunnels later. Note the IP — you can set `clusterIP: 10.43.x.x` in the Service spec so it survives re-creation.

### Step 7: Test cross-namespace access

From a pod in a different namespace:

```bash
kubectl run -n {{NAMESPACE}} pg-test --rm -it --image=postgres:16-alpine --restart=Never -- \
  psql "postgresql://{{DB_USER}}:{{DB_PASSWORD}}@postgres.shared.svc.cluster.local:5432/{{DB_NAME}}" \
  -c "SELECT 1 AS connected;"
```

Expected: `connected | 1`

---

## Part B: Redis

### Step 1: Apply the Redis manifest

```bash
kubectl apply -f templates/shared/redis.yaml
```

### Step 2: Wait for the Deployment

```bash
kubectl -n shared get deploy redis -w
```

Wait until `READY` shows `1/1`.

### Step 3: Verify Redis is running

```bash
kubectl -n shared exec -it deploy/redis -- redis-cli ping
```

Expected: `PONG`

Check config:

```bash
kubectl -n shared exec -it deploy/redis -- redis-cli INFO memory | grep -E "maxmemory|used_memory_human|maxmemory_policy"
```

Expected:

```
used_memory_human:1.50M
maxmemory:209715200
maxmemory_policy:allkeys-lru
```

### Step 4: Test cross-namespace access

```bash
kubectl run -n {{NAMESPACE}} redis-test --rm -it --image=redis:7-alpine --restart=Never -- \
  redis-cli -h redis.shared.svc.cluster.local ping
```

Expected: `PONG`

---

## Connection strings

Save these — you'll need them when configuring Infisical secrets:

| Variable | Value |
|----------|-------|
| `DATABASE_URL` | `postgresql://app_prod_svc:PASSWORD@pgbouncer.{{NAMESPACE}}:6432/{{DB_NAME}}` |
| `DIRECT_URL` | `postgresql://app_prod_svc:PASSWORD@postgres.shared:5432/{{DB_NAME}}` |
| `REDIS_URL` | `redis://redis.shared.svc.cluster.local:6379` |

> **Note:** `DATABASE_URL` points at PgBouncer (set up in [08-pgbouncer.md](./08-pgbouncer.md)). Until PgBouncer is running, use `DIRECT_URL` for both.

---

## Troubleshooting

### PVC stuck in Pending

```bash
kubectl -n shared describe pvc postgres-data
```

Common cause: `local-path-provisioner` is not running.

```bash
kubectl -n kube-system get pods -l app=local-path-provisioner
```

Fix: restart K3s (`systemctl restart k3s`).

### Postgres CrashLoopBackOff

```bash
kubectl -n shared logs postgres-0
```

Common causes:
- **Wrong password format:** special characters in POSTGRES_PASSWORD need URL-encoding
- **Disk full:** check `df -h` on the node
- **Permission denied on mount:** `chown 999:999 /opt/local-path-provisioner/xxx` on the node

### Redis OOMKilled

If Redis restarts with OOMKilled, the memory limit is too low. Bump limits in the manifest:

```yaml
resources:
  limits:
    memory: 512Mi  # was 256Mi
```

---

## What you have now

- PostgreSQL 16 running in `shared` namespace with pinned ClusterIP
- Production + staging databases created
- Scoped DB users with connection limits
- Redis 7 running with 200 MB memory cap and LRU eviction
- Both accessible from any namespace via DNS

**Next:** [03-argocd-install.md](./03-argocd-install.md) — install ArgoCD for GitOps deployments.
