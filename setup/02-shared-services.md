# 02 — Shared Services (PostgreSQL + Redis)

Deploy PostgreSQL and Redis into the `shared` namespace. Both are reached from app namespaces over cluster DNS (`redis.shared.svc.cluster.local`).

**Time:** ~15 minutes

> **Using a managed database?** If your app's data lives in MongoDB Atlas, RDS, Neon or similar, you still want the PostgreSQL below: self-hosted Infisical ([04](./04-infisical-install.md)) needs its own PostgreSQL. Set `DB_NAME=infisical` in `vars.env` and treat Part A as "the database Infisical runs on". Skip [08-pgbouncer.md](./08-pgbouncer.md) — it only helps a self-hosted PostgreSQL that your app connects to directly.

---

## Part A: PostgreSQL

### Step 1: Apply the manifest

The template is at `templates/shared/postgres.yaml`. If you ran `init.sh`, your placeholders are already filled; use `output/shared/postgres.yaml`.

```bash
kubectl apply -f output/shared/postgres.yaml
```

This creates three things: a ConfigMap holding an init script, the StatefulSet, and a ClusterIP Service on a pinned IP.

### Step 2: Wait for the StatefulSet

```bash
kubectl -n shared rollout status statefulset/postgres --timeout=180s
```

Expected:

```
partitioned roll out complete: 1 new pods have been updated...
```

If it hangs, read the events:

```bash
kubectl -n shared describe pod postgres-0 | tail -20
```

### Step 3: Confirm the init script ran

The ConfigMap at `templates/shared/postgres.yaml` runs **once**, on the very first boot of an empty data directory. It creates the staging database and the scoped application role for you. You do not create them by hand.

```bash
kubectl -n shared logs postgres-0 | grep -E "init-databases|initialization complete"
```

Expected:

```
/usr/local/bin/docker-entrypoint.sh: sourcing /docker-entrypoint-initdb.d/init-databases.sh
Creating application databases and scoped users...
Database initialization complete.
```

> **If you see nothing**, the volume already had data when the pod started, so the entrypoint skipped the script. Either apply the SQL by hand or delete the PVC (`kubectl -n shared delete pvc postgres-data-postgres-0`) and start over — that destroys all data.

### Step 4: Verify the databases and the role

Everything administrative runs as `{{DB_SUPERUSER}}`, which is what the container's `POSTGRES_USER` is set to. `{{DB_USER}}` is a scoped role and **cannot** create databases.

```bash
kubectl -n shared exec postgres-0 -- \
  psql -U {{DB_SUPERUSER}} -d {{DB_NAME}} -tAc "SELECT datname FROM pg_database ORDER BY 1;"
```

Expected — both your databases plus the three built-ins:

```
{{DB_NAME}}
{{DB_STAGING_NAME}}
postgres
template0
template1
```

```bash
kubectl -n shared exec postgres-0 -- \
  psql -U {{DB_SUPERUSER}} -d {{DB_NAME}} -tAc \
  "SELECT rolname, rolconnlimit FROM pg_roles WHERE rolname NOT LIKE 'pg_%' ORDER BY 1;"
```

Expected — the superuser and the scoped app role with its connection cap:

```
{{DB_SUPERUSER}}|-1
{{DB_USER}}|50
```

> **Why `exec` and not `exec -it`?** `-t` allocates a TTY and fails with `the input device is not a TTY` in any non-interactive context: CI, a shell script, or `ssh server 'kubectl ...'`. Leave `-t` out of anything you might paste into a script. This guide never uses it.

### Step 5: Verify the Service and its pinned ClusterIP

```bash
kubectl -n shared get svc postgres
```

Expected:

```
NAME       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
postgres   ClusterIP   10.43.100.100   <none>        5432/TCP   2m
```

The IP is pinned by `clusterIP: {{POSTGRES_CLUSTERIP}}` in the manifest so SSH tunnels and `pg_hba`-style allowlists keep working across re-creation. It must fall inside the cluster's service CIDR — `10.43.0.0/16` on a default K3s install.

### Step 6: Test access from another namespace, over TCP with a password

A plain `psql -U someuser` **inside** the pod proves almost nothing: the official image trusts the local Unix socket, so it succeeds without a password. Test the path your app will actually use — TCP, from a different namespace, authenticating with the password.

```bash
kubectl -n {{NAMESPACE}} delete pod pg-test --ignore-not-found
kubectl run -n {{NAMESPACE}} pg-test --restart=Never --image=postgres:16-alpine \
  --env="PGPASSWORD={{DB_PASSWORD}}" --command -- \
  psql -h postgres.shared.svc.cluster.local -U {{DB_USER}} -d {{DB_NAME}} -tAc "SELECT 'connected';"

kubectl -n {{NAMESPACE}} wait --for=jsonpath='{.status.phase}'=Succeeded pod/pg-test --timeout=90s
kubectl -n {{NAMESPACE}} logs pg-test
kubectl -n {{NAMESPACE}} delete pod pg-test
```

Expected: `connected`

> **Avoid `kubectl run --rm -it` for this.** Two things go wrong: `-i` reads from stdin, so inside a heredoc or a script it swallows the rest of your script, and with `--rm` the pod is often deleted before its output is streamed, so you see nothing. The create / wait / logs / delete sequence above is reliable everywhere.

---

## Part B: Redis

Three settings in `templates/shared/redis.yaml` are not optional. All three were found by running this blueprint on a live cluster.

| Setting | Why |
|---------|-----|
| `requirepass` | A ClusterIP Service is reachable from **every** namespace. Without a password any pod in the cluster can run `FLUSHALL` against your queues. |
| `maxmemory-policy noeviction` | BullMQ, Sidekiq and Celery all store queue state in Redis. An `allkeys-*` policy evicts those keys under memory pressure and jobs vanish with no error anywhere. Only use `allkeys-lru` if this Redis is a pure cache with no queues. |
| `appendonly` + a PVC | Without a volume, Redis writes its snapshots to the container filesystem. One pod restart and every queued job and rate-limit counter is gone. |

### Step 1: Create the password Secret

Redis reads the password from a Secret, so it never appears in the manifest, in the process list, or in your git history. Do this **before** applying the manifest — the pod will not start without it.

```bash
PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 28)
kubectl -n shared create secret generic redis-auth \
  --from-literal=REDIS_PASSWORD="$PW" \
  --from-literal=requirepass.conf="requirepass $PW"
unset PW
```

Two keys, on purpose:

- `requirepass.conf` is mounted as a file and pulled in by an `include` line in `redis.conf`. Passing `--requirepass` as an argument instead would expose the password to any `ps` inside the container.
- `REDIS_PASSWORD` is the bare value, for your apps to build a `REDIS_URL` and for `redis-cli` to pick up through `REDISCLI_AUTH`.

Verify both keys exist:

```bash
kubectl -n shared get secret redis-auth -o jsonpath='{.data}' | tr ',' '\n'
```

### Step 2: Apply the manifest

```bash
kubectl apply -f output/shared/redis.yaml
kubectl -n shared rollout status deploy/redis --timeout=120s
```

The Deployment uses `strategy: Recreate`. A `ReadWriteOnce` volume cannot attach to two pods at once, so a rolling update would deadlock with the new pod stuck `Pending`.

### Step 3: Verify the three settings

```bash
kubectl -n shared exec deploy/redis -- redis-cli CONFIG GET maxmemory-policy
kubectl -n shared exec deploy/redis -- redis-cli CONFIG GET appendonly
kubectl -n shared exec deploy/redis -- redis-cli CONFIG GET maxmemory
```

Expected:

```
maxmemory-policy
noeviction
appendonly
yes
maxmemory
209715200
```

The probes and these commands need no password argument: the container sets `REDISCLI_AUTH` from the Secret and `redis-cli` reads it automatically.

### Step 4: Prove the password is enforced

From a different namespace, with no credentials — this **must** fail:

```bash
kubectl -n {{NAMESPACE}} delete pod redis-noauth --ignore-not-found
kubectl run -n {{NAMESPACE}} redis-noauth --restart=Never --image=redis:7-alpine --command -- \
  redis-cli -h redis.shared.svc.cluster.local ping
kubectl -n {{NAMESPACE}} wait --for=jsonpath='{.status.phase}'=Succeeded pod/redis-noauth --timeout=60s
kubectl -n {{NAMESPACE}} logs redis-noauth
kubectl -n {{NAMESPACE}} delete pod redis-noauth
```

Expected:

```
NOAUTH Authentication required.
```

If that returns `PONG`, the Secret was not picked up. Check that `redis.conf`'s `include /etc/redis/auth/requirepass.conf` line resolves:

```bash
kubectl -n shared exec deploy/redis -- cat /etc/redis/auth/requirepass.conf | cut -d' ' -f1
```

### Step 5: Prove the data survives a restart

```bash
kubectl -n shared exec deploy/redis -- redis-cli SET blueprint:test "survived"
kubectl -n shared delete pod -l app=redis
kubectl -n shared rollout status deploy/redis --timeout=120s
kubectl -n shared exec deploy/redis -- redis-cli GET blueprint:test
```

Expected: `survived`

Confirm the append-only files are on the volume, not the container filesystem:

```bash
kubectl -n shared exec deploy/redis -- ls /data/appendonlydir
```

Expected:

```
appendonly.aof.1.base.rdb
appendonly.aof.1.incr.aof
appendonly.aof.manifest
```

Clean up the test key:

```bash
kubectl -n shared exec deploy/redis -- redis-cli DEL blueprint:test
```

---

## Connection strings

Put these into Infisical in [04-infisical-install.md](./04-infisical-install.md). Read the Redis password out of the Secret rather than retyping it:

```bash
kubectl -n shared get secret redis-auth -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d
```

| Variable | Value |
|----------|-------|
| `REDIS_URL` | `redis://:PASSWORD@redis.shared.svc.cluster.local:6379` |
| `DATABASE_URL` | `postgresql://{{DB_USER}}:PASSWORD@pgbouncer.{{NAMESPACE}}:6432/{{DB_NAME}}` |
| `DIRECT_URL` | `postgresql://{{DB_USER}}:PASSWORD@postgres.shared:5432/{{DB_NAME}}` |

Note the empty username in `REDIS_URL` — `redis://:password@host` is correct. Redis has no username before version 6 ACLs, and most clients reject `redis://password@host`.

`DATABASE_URL` points at PgBouncer, which does not exist until [08-pgbouncer.md](./08-pgbouncer.md). Until then use the `DIRECT_URL` value for both.

---

## Troubleshooting

### PVC stuck in Pending

```bash
kubectl -n shared describe pvc postgres-data-postgres-0
```

Usually `local-path-provisioner` is not running:

```bash
kubectl -n kube-system get pods -l app=local-path-provisioner
```

Fix: `systemctl restart k3s`.

### `FATAL: database "<username>" does not exist` repeating in the Postgres log

`pg_isready -U someuser` with no `-d` probes a database named after the *user*. It still exits 0, because the server answered, so the probe passes while logging a FATAL every single period. Both probes in `postgres.yaml` pass `-d {{DB_NAME}}` for exactly this reason. If you wrote your own, add it.

### Redis pod `CrashLoopBackOff` right after applying

Almost always the missing Secret. Check:

```bash
kubectl -n shared logs deploy/redis --previous | tail -20
```

`Fatal error, can't open config file` means the `redis-auth` Secret does not exist or lacks the `requirepass.conf` key. Go back to Part B step 1.

### Redis OOMKilled

`maxmemory` is a Redis-level cap; the container limit must sit above it with headroom for overhead and the AOF buffer. With `REDIS_MAX_MEMORY=200mb`, keep the container limit at 256Mi or more. If you raise one, raise the other.

### Postgres CrashLoopBackOff

```bash
kubectl -n shared logs postgres-0
```

- **Permission denied on the data directory:** `chown 999:999` the host path under `/opt/local-path-provisioner/`.
- **Disk full:** `df -h` on the node.
- **Password with special characters:** fine in the Secret, but URL-encode it inside any `postgresql://` string.

---

## What you have now

- PostgreSQL 16 in `shared` on a pinned ClusterIP, with the staging database and a connection-capped application role created automatically on first boot
- Probes that validate a real database instead of logging a FATAL every ten seconds
- Redis 7 with a password, `noeviction` so queued jobs are never evicted, and an append-only log on a PVC that survives pod restarts
- Both verified over TCP from a different namespace

**Next:** [03-argocd-install.md](./03-argocd-install.md) — install ArgoCD for GitOps deployments.
