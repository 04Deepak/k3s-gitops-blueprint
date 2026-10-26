# Scaling

## HPA — Horizontal Pod Autoscaler

The backend is the only component that autoscales. It uses CPU-based HPA:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: backend-hpa
  namespace: acme
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: backend
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 80
```

### Why CPU-Based

- CPU correlates well with request throughput for API servers
- Metrics-server is bundled with K3s (no Prometheus needed)
- Memory-based scaling is unreliable for Node.js (V8 GC doesn't release memory predictably)

### Scaling Behavior

| Metric | Value | Meaning |
|--------|-------|---------|
| minReplicas | 2 | Always at least 2 pods (availability) |
| maxReplicas | 8 | Upper bound (node capacity) |
| target CPU | 80% | Scale up when average CPU exceeds 80% of requests |

**Scale-up:** When average CPU across all backend pods exceeds 80% of the `requests.cpu` value (250m × 80% = 200m), the HPA adds pods. Scale-up is fast — new pods appear within 15-30 seconds.

**Scale-down:** When CPU drops below the threshold for 5 minutes (default `stabilizationWindowSeconds`), the HPA removes pods one at a time. Scale-down is conservative to avoid flapping.

### Why Not Scale Frontend

The frontend is an nginx container serving static files. A single pod handles thousands of concurrent connections. The backend (doing database queries, business logic, SSE connections) is the bottleneck.

### Why Not Scale Database

PostgreSQL doesn't support horizontal scaling natively. Adding read replicas requires application-level query routing. The current single-replica setup handles the workload. If scaling becomes necessary, consider:
1. First: increase resource limits (vertical scaling)
2. Then: add a streaming replica for read-heavy queries
3. Then: managed PostgreSQL (RDS, Cloud SQL) with read replicas

## Resource Budgets

### Production

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit |
|-----------|------------|-----------|----------------|-------------|
| Backend | 250m | 1500m | 384Mi | 1536Mi |
| Frontend | 50m | 200m | 64Mi | 128Mi |
| PgBouncer (×2) | 50m | 500m | 64Mi | 128Mi |
| PostgreSQL | 100m | 500m | 256Mi | 512Mi |
| Redis | 50m | 200m | 64Mi | 256Mi |
| CronJob (standard) | 50m | 500m | 128Mi | 512Mi |
| CronJob (account-purge) | 100m | 1000m | 256Mi | 1024Mi |
| CronJob (consent-cleanup) | 50m | 500m | 128Mi | 384Mi |
| CronJob (session-cleanup) | 50m | 250m | 128Mi | 256Mi |
| Migrate/Seed hook Jobs | 100m | 500m | 256Mi | 512Mi |

### Staging

Same as production except:
- Frontend: 25m-100m CPU, 32Mi-64Mi memory
- Other components: identical (staging should mirror prod behavior)

### Total Node Budget (Worst Case)

At maximum scale (8 backend replicas + all CronJobs running + both PgBouncer pods):

| Component | Pods | CPU Request | Memory Request |
|-----------|------|------------|----------------|
| Backend | 8 | 2000m | 3072Mi |
| Frontend | 1 | 50m | 64Mi |
| PgBouncer | 2 | 100m | 128Mi |
| PostgreSQL | 1 | 100m | 256Mi |
| Redis | 1 | 50m | 64Mi |
| ArgoCD | 3 | ~500m | ~512Mi |
| Infisical | 2 | ~250m | ~512Mi |
| Traefik | 1 | ~200m | ~256Mi |
| K3s system | - | ~500m | ~1Gi |
| **Total** | | **~3750m** | **~5.8Gi** |

On a 32GB / 8 vCPU node, this leaves ample headroom. The limits allow bursting up to ~14 CPU cores and ~12GB memory, which would require more than the node has — but limits are aspirational, and the scheduler only guarantees requests.

## PodDisruptionBudget

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: backend-pdb
  namespace: acme
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: backend
```

**Purpose:** During node maintenance or rolling updates, Kubernetes won't evict ALL backend pods simultaneously. At least 1 must remain healthy.

**When it matters:**
- `kubectl drain` during node maintenance
- ArgoCD rolling updates (new image deployment)
- Cluster upgrades

**Components with PDBs:**
- Backend: `minAvailable: 1`
- PgBouncer: `minAvailable: 1`

Frontend and CronJobs don't need PDBs — frontend has 1 replica (PDB is meaningless), and CronJobs are batch (brief downtime is acceptable).

## Node Capacity Planning

### Single-Node Limits

A Hostinger KVM8 (32GB RAM, 8 vCPU, 387GB disk) comfortably runs:
- 1 production environment
- 1 staging environment
- 1 additional small project (community app)
- Infrastructure (ArgoCD, Infisical, Traefik)

**Warning signs you need a second node or larger instance:**
- Pods stuck in `Pending` (insufficient CPU/memory)
- Node memory usage consistently > 80%
- HPA unable to scale up (maxReplicas reached AND CPU still high)
- Disk usage > 70% (Docker images accumulate)

### Disk Management

Docker images accumulate on the node. Periodic cleanup:

```bash
# Check disk usage
df -h /

# Clean unused Docker images
k3s crictl rmi --prune

# Check image list
k3s crictl images | sort -k2 -h
```

### When to Add a Second Node

1. **HA requirement:** Single-node means any node failure is total downtime
2. **Resource exhaustion:** CPU/memory consistently maxed
3. **Workload isolation:** Want to separate prod from staging/infra

Adding a K3s agent node:
```bash
# On the new node:
curl -sfL https://get.k3s.io | K3S_URL=https://primary-node:6443 K3S_TOKEN=node-token sh -
```

## CronJob Resource Isolation

CronJobs run alongside the API server on the same node. Each job type has tailored resource limits:

| Job | Why Different Limits |
|-----|---------------------|
| account-purge | Processes many records, needs 1Gi memory for bulk anonymization |
| consent-cleanup | Moderate — scans consent records with TTL |
| session-cleanup | Light — deletes expired session rows |
| broadcast-recovery | Light but time-sensitive — 240s deadline |
| tat-scheduler | Moderate — processes service applications |
| insurance-expiry | Moderate — sends notification batches |

**activeDeadlineSeconds** is set on every CronJob as a safety net. If a job hangs (database lock, infinite loop), K8s kills it after the deadline.

## Vertical Scaling — When to Bump Limits

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| OOMKilled pods | `kubectl describe pod` shows OOMKilled | Increase memory limit |
| CPU throttling | `kubectl top pod` shows CPU at limit | Increase CPU limit |
| Slow response times | CPU requests too low, pod starved | Increase CPU request |
| Pod evicted | Node memory pressure | Increase node memory or reduce limits elsewhere |

**Example: Backend OOMKill**

The backend was OOMKilled after adding a Tesseract OCR module. Memory jumped from ~500Mi to ~900Mi on startup.

```yaml
# Before
resources:
  limits:
    memory: 768Mi

# After
resources:
  limits:
    memory: 1536Mi
```

Always bump the limit, not just the request. The request guarantees scheduling; the limit prevents OOM. If the limit is too close to actual usage, transient spikes trigger OOMKill.

**Rule of thumb:** Set memory limit to 2× typical usage. Set CPU limit to 3-6× request (allows bursting for request handling).
