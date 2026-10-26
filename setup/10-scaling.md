# 10 — Scaling: HPA, PDB & Resource Management

This guide configures horizontal pod autoscaling, disruption budgets, and resource governance so the cluster scales under load without exhausting the node.

---

## Prerequisites

- Backend deployed and healthy (`kubectl get pods -n {{NAMESPACE}}`)
- Metrics server running (`kubectl top nodes` returns data — K3s bundles it by default)

---

## Step 1: Apply the HPA

The `hpa.yaml` template targets the backend Deployment:

```bash
kubectl apply -f backend/hpa.yaml -n {{NAMESPACE}}
```

Verify:

```bash
kubectl get hpa -n {{NAMESPACE}}
```

Expected output:

```
NAME       REFERENCE             TARGETS   MINPODS   MAXPODS   REPLICAS   AGE
backend    Deployment/backend    12%/80%   2         8         2          30s
```

The `TARGETS` column shows `<current>/<target>`. If it reads `<unknown>/80%`, metrics haven't arrived yet — wait 60 seconds and retry.

Inspect details:

```bash
kubectl describe hpa backend -n {{NAMESPACE}}
```

Watch live scaling decisions:

```bash
kubectl get hpa -n {{NAMESPACE}} -w
```

---

## Step 2: Apply the PodDisruptionBudget

The PDB guarantees at least one backend pod stays running during voluntary disruptions (node drains, rolling updates):

```bash
kubectl apply -f backend/pdb.yaml -n {{NAMESPACE}}
```

Verify:

```bash
kubectl get pdb -n {{NAMESPACE}}
```

Expected:

```
NAME       MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
backend    1               N/A               1                     10s
```

---

## Resource Budget Table

Every component's CPU and memory budget. The sum of all **limits** must fit within the node's allocatable capacity.

| Component | CPU Request | CPU Limit | Mem Request | Mem Limit |
|---|---|---|---|---|
| Backend (prod) × 2–8 | 250m | 1500m | 384Mi | 1536Mi |
| Backend (staging) × 2–8 | 250m | 1500m | 384Mi | 1536Mi |
| Frontend (prod) × 1 | 50m | 200m | 64Mi | 128Mi |
| Frontend (staging) × 1 | 25m | 100m | 32Mi | 64Mi |
| PgBouncer (prod) × 2 | 50m | 500m | 64Mi | 128Mi |
| PgBouncer (staging) × 2 | 50m | 500m | 64Mi | 128Mi |
| PostgreSQL × 1 | 100m | 500m | 256Mi | 512Mi |
| Redis × 1 | 50m | 200m | 64Mi | 256Mi |
| CronJob (standard) | 50m | 500m | 128Mi | 512Mi |
| CronJob (account-purge) | 100m | 1000m | 256Mi | 1024Mi |
| CronJob (consent-cleanup) | 50m | 500m | 128Mi | 384Mi |
| CronJob (session-cleanup) | 50m | 250m | 128Mi | 256Mi |
| Migrate hook Job | 100m | 500m | 256Mi | 512Mi |
| Seed hook Job | 100m | 500m | 256Mi | 512Mi |

> CronJobs are transient — only one runs at a time per type (`concurrencyPolicy: Forbid`), so their limits overlap rather than stack.

### Worst-case calculation (single 32 GB node)

```
Backend prod at max scale:   8 × 1536Mi =  12,288Mi
Backend staging at max:      8 × 1536Mi =  12,288Mi
PgBouncer prod + staging:    4 ×  128Mi =     512Mi
Frontend prod + staging:     1 × 128 + 1 × 64 = 192Mi
Postgres:                                    512Mi
Redis:                                       256Mi
Largest CronJob:                           1,024Mi
ArgoCD (system):                          ~1,500Mi
Infisical (system):                       ~1,200Mi
K3s + OS overhead:                        ~2,000Mi
─────────────────────────────────────────────────
Total worst-case:                        ~31,772Mi
```

This is tight on a 32 GB node if both prod and staging scale to 8 replicas simultaneously. In practice, staging rarely scales past 2.

**Rule of thumb:** keep total pod limits under 70% of node capacity for steady-state; accept burst to ~90% under load.

Check actual usage:

```bash
kubectl top nodes
kubectl top pods -n {{NAMESPACE}} --sort-by=memory
```

---

## Step 3: Load Test to Trigger Scaling

Simple curl-based load (quick and dirty):

```bash
for i in $(seq 1 200); do
  curl -s https://{{DOMAIN}}/api/health > /dev/null &
done
wait
```

Better — use [hey](https://github.com/rakyll/hey):

```bash
# Install
go install github.com/rakyll/hey@latest
# or: brew install hey

# Run: 10,000 requests, 50 concurrent
hey -n 10000 -c 50 https://{{DOMAIN}}/api/health
```

Watch scaling in another terminal:

```bash
kubectl get hpa -n {{NAMESPACE}} -w
```

You should see `REPLICAS` increase from 2 toward 8 as CPU crosses the 80% target. After load stops, replicas scale back down after the stabilization window (default: 5 minutes for scale-down).

---

## When to Scale Horizontally vs. Vertically

| Component | Horizontal? | Vertical? | Notes |
|-----------|-------------|-----------|-------|
| Backend | Yes (HPA) | If OOMKilled | Stateless — more replicas handle more requests |
| Frontend | No | Rarely | Nginx serves static files; 1 replica handles thousands of requests |
| PostgreSQL | No (not without an operator) | Yes | Single-replica StatefulSet — increase CPU/memory limits, never add replicas manually |
| Redis | No | Yes | Single-replica — increase `--maxmemory` and memory limits |
| PgBouncer | Yes | Rarely | 2 replicas default; increase if connection count grows beyond `max_client_conn × replicas` |

---

## CronJob Resource Isolation

Each CronJob has its own resource budget sized to its workload:

| Job | Why This Budget |
|-----|----------------|
| `account-purge` | Iterates all users for DPDP anonymization — heaviest job (1Gi limit) |
| `tat-scheduler` | Processes service applications — moderate (512Mi) |
| `broadcast-recovery` | Retries failed notifications — moderate (512Mi) |
| `consent-cleanup` | Deletes expired tokens — light queries (384Mi) |
| `session-cleanup` | Deletes old sessions — lightest (256Mi) |
| `insurance-expiry` | Sends reminders — moderate (512Mi) |

Every CronJob sets `activeDeadlineSeconds` as a safety net — if a job hangs (deadlock, infinite loop, network stall), Kubernetes kills it after the timeout. Without this, a stuck job blocks the next run (`concurrencyPolicy: Forbid` prevents overlap).

---

## Tuning Tips

### HPA flapping (constant scale-up / scale-down)

Add a stabilization window to the HPA:

```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300  # Wait 5 min before scaling down
    policies:
      - type: Pods
        value: 1
        periodSeconds: 60            # Remove at most 1 pod per minute
  scaleUp:
    stabilizationWindowSeconds: 0    # Scale up immediately
    policies:
      - type: Percent
        value: 100
        periodSeconds: 15            # Double pods every 15s under load
```

### Pods OOMKilled

```bash
# Check which pod was killed and why
kubectl describe pod <pod-name> -n {{NAMESPACE}} | grep -A5 "Last State"

# Check current memory usage vs limits
kubectl top pods -n {{NAMESPACE}} --sort-by=memory
```

Fix: bump the memory limit in the Deployment. If it happens repeatedly, profile the application — a memory leak needs a code fix, not a bigger limit.

### CPU throttling

```bash
# Compare actual CPU to limits
kubectl top pods -n {{NAMESPACE}} --sort-by=cpu
```

If a pod consistently uses >80% of its CPU limit, it's being throttled. Options:
1. Increase the CPU limit
2. If it's the backend, let HPA add more replicas instead (often better)

### Node under pressure

```bash
# Check node conditions
kubectl describe node | grep -A5 "Conditions"

# Look for MemoryPressure or DiskPressure = True
```

If `MemoryPressure` is `True`, Kubernetes starts evicting pods. Options:
1. Reduce replica counts or memory limits
2. Add a second node (K3s supports multi-node — `k3s agent` on a second server)
3. Move staging to a separate node

---

## Verification Checklist

```bash
# HPA is active and reading metrics
kubectl get hpa -n {{NAMESPACE}}

# PDB is enforced
kubectl get pdb -n {{NAMESPACE}}

# Current resource usage vs capacity
kubectl top nodes
kubectl top pods -n {{NAMESPACE}} --sort-by=memory

# No pods in OOMKilled or CrashLoopBackOff
kubectl get pods -n {{NAMESPACE}} -o wide
```

---

**Next:** [11 — Security Hardening](11-security-hardening.md) — WireGuard VPN, firewall, access control
