# 08 — PgBouncer (Connection Pooling)

PgBouncer sits between your app and PostgreSQL, pooling connections. Without it, each backend replica opens its own connection pool — with HPA scaling to 8 replicas, you'd exhaust PostgreSQL's `max_connections` (default 100).

**Time:** ~15 minutes

---

## Why you need this

```
Without PgBouncer:
  8 replicas × 12 connections each = 96 connections
  + staging replicas + CronJobs + admin tools = over 100 → connection refused

With PgBouncer:
  8 replicas → PgBouncer (transaction pooling) → 12 actual DB connections
  Each request borrows a connection only for the duration of a transaction
```

## Step 1: Create PgBouncer auth secret

PgBouncer needs a `userlist.txt` file mapping database users to passwords.

```bash
# Generate the password hash (md5 format for PgBouncer)
# Format: "md5" + md5(password + username)
PG_USER="app_prod_svc"
PG_PASS="YOUR_DB_PASSWORD"
PG_HASH=$(echo -n "${PG_PASS}${PG_USER}" | md5sum | cut -d' ' -f1)

kubectl -n {{NAMESPACE}} create secret generic pgbouncer-auth \
  --from-literal=userlist.txt="\"${PG_USER}\" \"md5${PG_HASH}\""
```

Or if using Infisical, add the credentials to the `/pgbouncer` path and use an InfisicalSecret CRD (already in `templates/backend/pgbouncer-secret.yaml`).

## Step 2: Apply PgBouncer manifest

```bash
kubectl apply -f templates/backend/pgbouncer.yaml -n {{NAMESPACE}}
```

The template includes:
- **ConfigMap** with `pgbouncer.ini` (pool_mode, max_client_conn, default_pool_size)
- **Deployment** (2 replicas for high availability)
- **Service** (ClusterIP on port 6432)
- **PodDisruptionBudget** (minAvailable: 1)

Key settings in the ConfigMap:

```ini
[databases]
{{DB_NAME}} = host=postgres.shared.svc.cluster.local port=5432 dbname={{DB_NAME}}

[pgbouncer]
listen_port = 6432
listen_addr = 0.0.0.0
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 12
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
server_idle_timeout = 600
```

## Step 3: Verify PgBouncer

```bash
kubectl -n {{NAMESPACE}} get pods -l app=pgbouncer
```

Expected: 2 pods Running.

Test connectivity through PgBouncer:

```bash
kubectl -n {{NAMESPACE}} run pgb-test --rm -it --image=postgres:16-alpine --restart=Never -- \
  psql "postgresql://app_prod_svc:YOUR_PASSWORD@pgbouncer:6432/{{DB_NAME}}" \
  -c "SELECT 1 AS connected;"
```

Expected: `connected | 1`

## Step 4: Update application connection strings

In Infisical (or your secrets), set:

| Variable | Value | Purpose |
|----------|-------|---------|
| `DATABASE_URL` | `postgresql://app_prod_svc:PASS@pgbouncer.{{NAMESPACE}}:6432/{{DB_NAME}}?pgbouncer=true` | Runtime queries (via PgBouncer) |
| `DIRECT_URL` | `postgresql://app_prod_svc:PASS@postgres.shared:5432/{{DB_NAME}}` | Migrations only (bypasses PgBouncer) |

> **`?pgbouncer=true`** tells Prisma to avoid features incompatible with transaction pooling (named prepared statements).

> **`DIRECT_URL`** is critical — Prisma migrations use advisory locks that break under transaction pooling. Always run migrations through the direct connection.

## Step 5: Connection budget planning

Calculate your total connection budget:

```
PostgreSQL max_connections: 100 (default)

PgBouncer pool_size: 12 (prod) + 12 (staging) = 24
Direct connections: migrations (1), backup CronJob (1), admin (5) = 7
PgBouncer overhead: 5 reserve = 5
Total: ~36 connections out of 100

Headroom: 64 connections for spikes, new services, monitoring
```

If you need more, increase PostgreSQL `max_connections` in postgres.yaml:

```yaml
args: ["-c", "max_connections=200"]
```

## Step 6: Repeat for staging

```bash
# Create auth secret for staging
kubectl -n {{STAGING_NAMESPACE}} create secret generic pgbouncer-auth \
  --from-literal=userlist.txt="\"app_staging_svc\" \"md5HASH\""

# Apply PgBouncer for staging
kubectl apply -f templates/staging/backend/pgbouncer.yaml -n {{STAGING_NAMESPACE}}
```

---

## Monitoring PgBouncer

Connect to PgBouncer's admin database to check stats:

```bash
kubectl -n {{NAMESPACE}} exec -it deploy/pgbouncer -- \
  psql "postgresql://pgbouncer:6432/pgbouncer" -U {{DB_USER}} -c "SHOW POOLS;"
```

Key metrics:
- `cl_active`: clients actively executing a query
- `cl_waiting`: clients waiting for a server connection (should be 0 normally)
- `sv_active`: server connections in use
- `sv_idle`: server connections idle in the pool

```bash
# Quick health check
kubectl -n {{NAMESPACE}} exec -it deploy/pgbouncer -- \
  psql "postgresql://pgbouncer:6432/pgbouncer" -U {{DB_USER}} -c "SHOW STATS;"
```

---

## Troubleshooting

### "no more connections allowed"

PgBouncer hit `max_client_conn`. Increase it:

```ini
max_client_conn = 2000  # was 1000
```

### "server connection limit reached"

PostgreSQL hit `max_connections` or the user's `CONNECTION LIMIT`. Options:
- Increase `default_pool_size` in PgBouncer (costs more DB connections)
- Increase PostgreSQL `max_connections`
- Increase the user's `CONNECTION LIMIT`

### Prisma migrations fail

If you see `"prepared statement already exists"` or advisory lock errors:
- Ensure migrations use `DIRECT_URL`, not `DATABASE_URL`
- Check the PreSync hook Job uses `DIRECT_URL` in its env

### Connection leak

If `cl_active` keeps growing without returning:
- The app has long-running transactions or forgot to release connections
- Check: `SHOW CLIENTS;` for connections with long `link_age`

---

## What you have now

- PgBouncer running with transaction pooling
- 2 replicas with PDB for zero-downtime upgrades
- Runtime queries via PgBouncer (pooled)
- Migrations via direct connection (not pooled)
- Connection budget planned

**Next:** [09-backup.md](./09-backup.md) — set up automated database backups.
