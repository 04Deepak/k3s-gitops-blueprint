# Monitoring

Current observability: a health-check script, kubectl commands, and the ArgoCD UI. No Prometheus/Grafana yet — those are planned.

## health-check.sh

A single script that SSHs into the server and runs a battery of kubectl and service checks. Output is color-coded: green checkmark (healthy), yellow warning (degraded), red X (failing).

### Running It

```bash
# From your local machine
./scripts/health-check.sh

# Or via SSH alias
ssh myserver 'bash /path/to/health-check.sh'
```

### What It Checks

| Check | Green | Yellow | Red |
|-------|-------|--------|-----|
| Node status | Ready | — | NotReady |
| Pod status | All Running/Succeeded | Pending pods | Failed/CrashLoop pods |
| Restart count | < 5 restarts | 5–20 restarts | > 20 restarts |
| Memory usage | < 70% of node | 70–85% | > 85% |
| ArgoCD apps | Synced + Healthy | Progressing | OutOfSync / Degraded |
| CronJobs | All active, recent runs | Suspended | Failed last run |
| TLS certs | > 30 days to expiry | 7–30 days | < 7 days |
| Disk usage | < 80% | 80–90% | > 90% |
| K8s warnings | None in last 10 min | — | Warnings present |
| Postgres | Ready, < 80% connections | 80–90% connections | Not ready / > 90% |
| Redis | Pong, < 80% maxmemory | 80–90% maxmemory | Not responding / > 90% |
| HTTP endpoints | 200 on SPA + API health | — | Non-200 |

### Sample Output

```
━━━ CLUSTER HEALTH CHECK ━━━

✔ Node: Ready (CPU: 23%, Memory: 58%)
✔ Pods: 24/24 Running (acme: 12, acme-staging: 8, shared: 3, argocd: 1)
✔ No high-restart pods
✔ ArgoCD: 7/7 Synced + Healthy
✔ CronJobs: 7/7 active, all ran within schedule
⚠ TLS: argocd.example.com expires in 22 days
✔ Disk: 41% used
✔ Postgres: Ready, 18/100 connections, DBs: my_project(245MB), staging(112MB)
✔ Redis: Pong, 12MB/200MB, 3 clients, 847 keys
✔ HTTP: prod SPA 200, prod API 200, staging SPA 200, staging API 200

━━━ SUMMARY: 11 passed, 1 warning, 0 failed ━━━
```

## Essential kubectl Commands

### Pod Health

```bash
# All pods in a namespace
kubectl get pods -n my-namespace

# Detailed pod info (events, conditions, container status)
kubectl describe pod backend-abc123 -n my-namespace

# Logs (current container)
kubectl logs backend-abc123 -n my-namespace

# Logs (previous crashed container)
kubectl logs backend-abc123 -n my-namespace --previous

# Follow logs in real time
kubectl logs -f backend-abc123 -n my-namespace

# Logs from all pods in a deployment
kubectl logs deployment/backend -n my-namespace --all-containers

# Top memory/CPU consumers
kubectl top pods -n my-namespace --sort-by=memory
```

### Deployment Status

```bash
# Rollout status (is it progressing or stuck?)
kubectl rollout status deployment/backend -n my-namespace

# Rollout history
kubectl rollout history deployment/backend -n my-namespace

# Undo last rollout
kubectl rollout undo deployment/backend -n my-namespace
```

### CronJob Inspection

```bash
# All CronJobs (LAST SCHEDULE, ACTIVE columns are key)
kubectl get cronjobs -n my-namespace

# Recent jobs
kubectl get jobs -n my-namespace --sort-by=.status.startTime | tail -10

# Logs from a specific job run
kubectl logs job/broadcast-recovery-28876543 -n my-namespace

# Failed jobs
kubectl get jobs -n my-namespace --field-selector status.successful=0
```

### Resource Usage

```bash
# Node-level
kubectl top nodes

# Pod-level, sorted by memory
kubectl top pods -n my-namespace --sort-by=memory

# All namespaces
kubectl top pods -A --sort-by=memory | head -20
```

### Events

```bash
# Recent events, sorted by time
kubectl get events -n my-namespace --sort-by=.lastTimestamp | tail -20

# Warnings only
kubectl get events -n my-namespace --field-selector type=Warning

# All namespaces, last 10 minutes
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

### Secret Inspection

```bash
# List secrets
kubectl get secrets -n my-namespace

# Check which keys a secret has (without revealing values)
kubectl get secret backend-secrets -n my-namespace -o jsonpath='{.data}' | \
  python3 -c "import sys,json; print('\n'.join(json.loads(sys.stdin.read()).keys()))"

# Decode a specific key
kubectl get secret backend-secrets -n my-namespace \
  -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

## ArgoCD Monitoring

### App Status

```bash
# Via kubectl exec (when ArgoCD runs in insecure mode behind Traefik)
kubectl exec deployment/argocd-server -n argocd -- \
  argocd app list --server localhost:8080 --plaintext \
  --auth-token "$(argocd login localhost:8080 --plaintext \
    --username admin --password $PASS --grpc-web)"
```

Or more commonly, check the ArgoCD UI at `https://argocd.example.com`.

### Health States

| State | Meaning | Action |
|-------|---------|--------|
| **Synced + Healthy** | Git matches cluster, all resources healthy | None |
| **Synced + Progressing** | Deploying — pods rolling out | Wait (usually <2 min) |
| **OutOfSync** | Git has changes not yet applied | Check if auto-sync is on; if yes, wait. If no, manual sync needed |
| **Degraded** | Resources unhealthy (pod crash, failed probe) | `kubectl describe pod` + `kubectl logs` |
| **Missing** | Expected resource not found in cluster | Check if it was accidentally deleted, or if the manifest path changed |

### Sync History

The ArgoCD UI shows every sync with: trigger (auto/manual), result (success/fail), timestamp, and the git commit that triggered it. PreSync and PostSync hook results (migrate, seed) are shown as sub-steps.

### Diff

```bash
# What would change if you synced now
argocd app diff my-app --server localhost:8080 --plaintext
```

Shows the exact diff between the git manifest and the live cluster state. Useful for debugging selfHeal reverts — if you manually `kubectl apply` something, ArgoCD will revert it on the next selfHeal check (every 3 minutes by default).

## Database Monitoring

### PostgreSQL

```bash
# Connect via SSH tunnel (from local machine)
ssh -L 5432:10.43.100.100:5432 dbtunnel@server-ip

# Then in another terminal:
psql -h localhost -U app_prod -d my_project
```

```sql
-- Active connections by database
SELECT datname, count(*) FROM pg_stat_activity GROUP BY datname;

-- Database sizes
SELECT datname, pg_size_pretty(pg_database_size(datname))
FROM pg_database WHERE datistemplate = false ORDER BY pg_database_size(datname) DESC;

-- Long-running queries (>30 seconds)
SELECT pid, now() - pg_stat_activity.query_start AS duration, query, state
FROM pg_stat_activity
WHERE (now() - pg_stat_activity.query_start) > interval '30 seconds'
  AND state != 'idle';

-- Connection utilization
SELECT count(*) AS active,
       (SELECT setting::int FROM pg_settings WHERE name = 'max_connections') AS max
FROM pg_stat_activity;

-- Table sizes (top 10)
SELECT relname, pg_size_pretty(pg_total_relation_size(relid))
FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 10;
```

### PgBouncer

```bash
# Connect to PgBouncer's admin console
psql -h pgbouncer-service -p 5432 -U pgbouncer pgbouncer

# Pool statistics
SHOW POOLS;

# Connection counts
SHOW STATS;

# Active server connections
SHOW SERVERS;

# Waiting clients
SHOW CLIENTS;
```

Key metrics from `SHOW POOLS`:
- `cl_active` — clients actively using a connection
- `cl_waiting` — clients waiting for a connection (should be 0 normally)
- `sv_active` — server connections in use
- `sv_idle` — server connections idle in pool

## Redis Monitoring

```bash
# From inside the cluster
kubectl exec deployment/redis -n shared -- redis-cli INFO memory
kubectl exec deployment/redis -n shared -- redis-cli INFO clients
kubectl exec deployment/redis -n shared -- redis-cli DBSIZE
```

Key metrics:

| Metric | Command | Healthy | Warning |
|--------|---------|---------|---------|
| Memory usage | `INFO memory` → `used_memory_human` | < 80% of maxmemory | > 80% |
| Evicted keys | `INFO stats` → `evicted_keys` | 0 | > 0 (means maxmemory reached, keys being dropped) |
| Connected clients | `INFO clients` → `connected_clients` | < 100 | > 100 (possible connection leak) |
| Total keys | `DBSIZE` | Stable or growing slowly | Sudden spike (possible leak) |

### Key Pattern Inspection

```bash
# Count keys by prefix
kubectl exec deployment/redis -n shared -- redis-cli --scan --pattern 'rl:*' | wc -l
kubectl exec deployment/redis -n shared -- redis-cli --scan --pattern 'sse:*' | wc -l

# TTL check on a specific key
kubectl exec deployment/redis -n shared -- redis-cli TTL "rl:auth:192.168.1.1"
```

## TLS Certificate Monitoring

```bash
# Check cert expiry for a domain
echo | openssl s_client -connect app.example.com:443 -servername app.example.com 2>/dev/null | \
  openssl x509 -noout -dates

# Days until expiry
echo | openssl s_client -connect app.example.com:443 -servername app.example.com 2>/dev/null | \
  openssl x509 -noout -enddate | \
  awk -F= '{print $2}' | \
  xargs -I {} bash -c 'echo $(( ($(date -d "{}" +%s) - $(date +%s)) / 86400 )) days'
```

Traefik renews Let's Encrypt certificates automatically 30 days before expiry. If renewal fails (DNS issues, rate limits), certificates expire and HTTPS breaks. The health-check script catches this at 30 days.

## What's Planned

### Prometheus + Grafana

Metrics and alerting on silent failure modes:
- Cron last-success timestamp per job (alert if no success in 2× schedule)
- Notification queue depth and age
- SSE active connection count
- External integration error rate and latency
- 5xx rate on API endpoints

### Loki Centralized Logging

Durable centralized logging with ≥1 year retention:
- Ship container logs to Loki via Promtail/FluentBit
- Store in S3 (same region as backups)
- Query via Grafana

Depends on: log redaction being in place first — without it, centralized logging durably persists secrets and PII that console-only logs would have rotated away.

### Alerting

Once Prometheus is in place:
- Slack notifications for critical alerts (CronJob failure, pod crash, high error rate)
- PagerDuty for on-call escalation
- ArgoCD notifications for deploy status (success/failure/health-degraded)
