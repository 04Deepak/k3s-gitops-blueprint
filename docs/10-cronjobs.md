# CronJobs

Scheduled background tasks running as Kubernetes CronJob resources, decoupled from the API server process.

## The CLI Runner Pattern

All CronJobs use a single entrypoint in the backend image:

```
node dist/jobs/runner.js <job-name>
```

The runner maps a job name to a function, connects to the database, executes the job, disconnects, and exits:

```typescript
// src/jobs/runner.ts
const JOBS: Record<string, () => Promise<void>> = {
  'broadcast-recovery': () => broadcastRecoveryJob(),
  'tat-scheduler':      () => tatSchedulerJob(),
  'consent-cleanup':    () => consentCleanupJob(),
  'insurance-expiry':   () => insuranceExpiryJob(),
  'account-purge':      () => accountPurgeJob(),
  'session-cleanup':    () => sessionCleanupJob(),
};

const jobName = process.argv[2];
const job = JOBS[jobName];
if (!job) {
  console.error(`Unknown job: ${jobName}`);
  process.exit(1);
}

await connectDB();
await job();
await disconnectDB();
process.exit(0);
```

### Why One Image, Not Separate Images

- **Same dependencies** — jobs use the same ORM, models, services, and config as the API
- **Same config** — `envFrom: backend-secrets` gives jobs the same environment variables
- **No build overhead** — adding a new job doesn't require a new Docker image or CI pipeline
- **Atomic deploys** — when the Deployment image updates, CronJobs use the same image automatically

### Adding a New CronJob

1. Write the job function in `src/jobs/`
2. Add it to the runner map in `src/jobs/runner.ts`
3. Add a CronJob manifest to `cronjobs.yaml` in the devops repo
4. Update CI to sed the image tag in `cronjobs.yaml` (same as `deployment.yaml`)
5. Push — ArgoCD deploys the new CronJob

## CronJob Configuration

### concurrencyPolicy: Forbid

Every CronJob uses `concurrencyPolicy: Forbid`:

```yaml
spec:
  concurrencyPolicy: Forbid
```

This means: if the previous run hasn't finished when the next schedule fires, the new run is **skipped**. This prevents:
- Duplicate notifications (broadcast-recovery running twice = double messages)
- Database contention (two account-purge jobs competing for the same rows)
- Resource exhaustion (stacking jobs consuming all node memory)

### startingDeadlineSeconds

```yaml
spec:
  startingDeadlineSeconds: 200
```

Used on `broadcast-recovery` (every 5 minutes). If K8s misses the schedule (node restart, controller busy), it still starts the job up to 200 seconds late. Without this, missed runs are silently dropped.

Most hourly/daily jobs don't need this — a few minutes' delay is acceptable, and the next run catches up.

### activeDeadlineSeconds

```yaml
spec:
  jobTemplate:
    spec:
      activeDeadlineSeconds: 600
```

Safety net. If a job hangs (deadlock, infinite loop, network stall), Kubernetes kills it after this many seconds. Set conservatively — the job should normally finish well under this limit.

## Production CronJobs

| CronJob | Schedule | Timeout | Resources (req/lim) | Purpose |
|---------|----------|---------|---------------------|---------|
| `broadcast-recovery` | `*/5 * * * *` | 240s | 50m/128Mi → 500m/512Mi | Retry failed notification broadcasts |
| `tat-scheduler` | `0 * * * *` | 600s | 50m/128Mi → 500m/512Mi | Process TAT (turnaround time) for service applications |
| `consent-cleanup` | `0 * * * *` | 300s | 50m/128Mi → 500m/384Mi | Clean up expired consent tokens |
| `insurance-expiry` | `0 8 * * *` | 600s | 50m/128Mi → 500m/512Mi | Send insurance expiry reminder notifications |
| `account-purge` | `0 2 * * *` | 1800s | 100m/256Mi → 1000m/1024Mi | DPDP account deletion and anonymization |
| `session-cleanup` | `0 3 * * *` | 120s | 50m/128Mi → 250m/256Mi | Expire old authentication sessions |

### Resource Isolation

Jobs get different resource budgets based on their workload:

- **account-purge** gets the most (1024Mi limit) — it processes bulk anonymization with encryption operations, potentially touching thousands of rows
- **session-cleanup** gets the least (256Mi) — it runs a simple `DELETE WHERE expiresAt < NOW()`
- **consent-cleanup** is mid-range (384Mi) — it queries and deletes expired consent records with related data

The key principle: CronJob resources are **independent** of the Deployment's resources. A CronJob pod is a separate pod — it doesn't share memory with the API server.

### Environment

CronJobs use the same environment pattern as the Deployment:

```yaml
spec:
  template:
    spec:
      containers:
        - name: job
          image: ghcr.io/org/backend:latest
          command: ["node", "dist/jobs/runner.js", "job-name"]
          env:
            - name: NODE_ENV
              value: "production"
          envFrom:
            - secretRef:
                name: backend-secrets
```

`NODE_ENV` is explicit (not from envFrom) — same reason as the Deployment: if `NODE_ENV` disappears from Infisical, jobs still run in production mode.

### DATABASE_URL Routing

Most CronJobs connect through PgBouncer (via `DATABASE_URL` from `backend-secrets`). For heavy batch operations that hold long transactions (like `account-purge`), consider using `DIRECT_URL` to bypass the pooler. Transaction-mode PgBouncer releases connections between transactions — a job that holds a transaction for 30 minutes blocks a pool slot the entire time.

## Backup CronJob

The database backup uses a different pattern — a 2-container Job:

```yaml
spec:
  jobTemplate:
    spec:
      template:
        spec:
          initContainers:
            - name: pg-dump
              image: postgres:16-alpine
              command:
                - sh
                - -c
                - |
                  pg_dump "$DATABASE_URL" | gzip > /backup/dump.sql.gz
              volumeMounts:
                - name: backup-vol
                  mountPath: /backup
              envFrom:
                - secretRef:
                    name: backup-secrets
          containers:
            - name: upload
              image: amazon/aws-cli:2.15.30
              command:
                - sh
                - -c
                - |
                  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
                  aws s3 cp /backup/dump.sql.gz \
                    "s3://${S3_BUCKET}/daily/${DB_NAME}_${TIMESTAMP}.sql.gz"
              volumeMounts:
                - name: backup-vol
                  mountPath: /backup
              envFrom:
                - secretRef:
                    name: backup-secrets
          volumes:
            - name: backup-vol
              emptyDir:
                sizeLimit: 1Gi
```

### Why 2 Containers

1. **Minimal images** — `postgres:16-alpine` for pg_dump, `amazon/aws-cli` for S3. Neither contains application code or dependencies.
2. **Isolated credentials** — the backup job uses `backup-secrets`, not `backend-secrets`. The S3 upload container never sees the JWT secret, API keys, or encryption keys. The pg_dump container never sees AWS credentials.
3. **Isolated IAM** — the AWS user (`acme-backup-writer`) has only `s3:PutObject` permission on the backup bucket. It cannot read, list, or delete backups. It cannot access the uploads bucket.

### S3 Bucket Hardening

| Setting | Value | Purpose |
|---------|-------|---------|
| Object Lock | Compliance, 90 days | Backups cannot be deleted or overwritten for 90 days, even by root |
| Lifecycle | Glacier IR after 30 days | Reduces storage cost for older backups |
| SSE-S3 | Enabled | Encryption at rest |
| Versioning | Enabled | Accidental overwrites recoverable |
| Bucket policy | Deny non-TLS | All access must use HTTPS |

## Monitoring CronJob Health

### Quick Status

```bash
# All CronJobs — check LAST SCHEDULE and ACTIVE columns
kubectl get cronjobs -n my-namespace

# Recent jobs, newest first
kubectl get jobs -n my-namespace --sort-by=.status.startTime

# Logs from the last run of a specific job
kubectl logs job/broadcast-recovery-28876543 -n my-namespace
```

### Common Failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| `OOMKilled` in pod events | Job exceeds memory limit | Bump `resources.limits.memory` in the CronJob manifest |
| `ImagePullBackOff` | GHCR secret missing or expired | Recreate `ghcr-secret` in the namespace |
| `CrashLoopBackOff` on job pod | Job code throws unhandled error | Check `kubectl logs` — fix the application code |
| `DeadlineExceeded` | Job ran longer than `activeDeadlineSeconds` | Increase timeout or optimize the job |
| `LAST SCHEDULE` not updating | CronJob suspended, or controller overloaded | Check `spec.suspend`, check kube-controller-manager logs |
| Job succeeded but no effect | Wrong `NODE_ENV` or missing env vars | Check `kubectl describe pod` for env |

### Suspend / Unsuspend

```bash
# Suspend (stop scheduling)
kubectl patch cronjob broadcast-recovery -n my-namespace \
  -p '{"spec":{"suspend":true}}'

# Unsuspend
kubectl patch cronjob broadcast-recovery -n my-namespace \
  -p '{"spec":{"suspend":false}}'
```

### Manual Trigger

```bash
kubectl create job --from=cronjob/broadcast-recovery test-broadcast \
  -n my-namespace
```

This creates a one-off Job from the CronJob template. Useful for testing or catch-up runs.
