# Databases

## PostgreSQL — StatefulSet Pattern

PostgreSQL runs as a single-replica StatefulSet in the `shared` namespace, serving multiple applications via separate databases on the same instance.

### Why StatefulSet (not Deployment)

- **Stable network identity:** Pod always gets the same DNS name (`postgres-0`)
- **Persistent volume claim:** Data survives pod restarts and rescheduling
- **Ordered startup:** Critical for databases that need deterministic initialization

### Manifest

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: shared
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_USER
              value: "app_user"
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-credentials
                  key: password
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data
              subPath: pgdata
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "app_user"]
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            exec:
              command: ["pg_isready", "-U", "app_user"]
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
  volumeClaimTemplates:
    - metadata:
        name: postgres-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
```

**Important:** The `subPath: pgdata` prevents PostgreSQL from complaining about a non-empty data directory (the PVC root may contain `lost+found`).

### Pinned ClusterIP Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: shared
spec:
  type: ClusterIP
  clusterIP: 10.43.100.100  # Pin the IP so SSH tunnels and connection strings survive restarts
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
```

**Why pin the ClusterIP:** SSH tunnel configurations (`ssh -L 5432:10.43.100.100:5432 dbtunnel@server`) break when the ClusterIP changes. Pinning the IP means tunnel configs never need updating.

## Multiple Databases on a Shared Instance

A single PostgreSQL instance hosts multiple databases:

| Database | Used By | Purpose |
|----------|---------|---------|
| `acme_platform` | Production backend | Application data |
| `acme_platform_staging` | Staging backend | Staging data |
| `community` | Community app | Community platform data |
| `infisical` | Infisical | Secret management metadata |

Create databases and scoped users:

```sql
-- Create databases
CREATE DATABASE acme_platform;
CREATE DATABASE acme_platform_staging;

-- Create scoped users with connection limits
CREATE USER acme_prod_svc WITH PASSWORD 'strong-random-password';
GRANT CONNECT ON DATABASE acme_platform TO acme_prod_svc;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO acme_prod_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO acme_prod_svc;
ALTER USER acme_prod_svc CONNECTION LIMIT 50;

CREATE USER acme_staging_svc WITH PASSWORD 'another-strong-password';
GRANT CONNECT ON DATABASE acme_platform_staging TO acme_staging_svc;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO acme_staging_svc;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO acme_staging_svc;
ALTER USER acme_staging_svc CONNECTION LIMIT 40;
```

**Why scoped users:** A compromised staging credential cannot access production data. Connection limits prevent one app from exhausting the shared connection pool.

## PgBouncer — Connection Pooling

### Why PgBouncer

PostgreSQL has a hard connection limit (default 100). Each Prisma instance opens ~10 connections. With HPA scaling the backend to 8 replicas, that is 80 connections from one app alone — leaving nothing for staging, community, Infisical, and admin queries.

PgBouncer sits between the application and PostgreSQL, multiplexing many client connections over a small pool of server connections.

### Configuration

```
[databases]
acme_platform = host=postgres.shared.svc.cluster.local port=5432 dbname=acme_platform

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 12
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
server_lifetime = 3600
server_idle_timeout = 600
log_connections = 0
log_disconnections = 0
```

**Key settings:**
- `pool_mode = transaction` — Connections are returned to the pool after each transaction, not after the client disconnects. This is required for Prisma, which uses prepared statements incompatible with `session` mode.
- `max_client_conn = 1000` — Maximum client connections PgBouncer accepts
- `default_pool_size = 12` — Server connections PgBouncer opens to PostgreSQL per database/user pair
- `reserve_pool_size = 5` — Extra connections for burst traffic

### Deployment

PgBouncer runs as a 2-replica Deployment with a PodDisruptionBudget:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgbouncer
  namespace: acme
spec:
  replicas: 2
  selector:
    matchLabels:
      app: pgbouncer
  template:
    spec:
      containers:
        - name: pgbouncer
          image: edoburu/pgbouncer@sha256:4c1ca296...  # Pin by digest in prod
          ports:
            - containerPort: 6432
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { cpu: 500m, memory: 128Mi }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: pgbouncer-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: pgbouncer
```

### Connection Routing

The application uses two connection strings:

| Variable | Target | Used For |
|----------|--------|----------|
| `DATABASE_URL` | PgBouncer (:6432) | Runtime queries (Prisma Client) |
| `DIRECT_URL` | PostgreSQL (:5432) | Migrations (`prisma migrate deploy`) |

**Why separate URLs:** Prisma migrations use advisory locks and long transactions that don't work well through a transaction-mode pooler. The `DIRECT_URL` bypasses PgBouncer and connects directly to PostgreSQL.

In `schema.prisma`:
```prisma
datasource db {
  provider  = "postgresql"
  url       = env("DATABASE_URL")
  directUrl = env("DIRECT_URL")
}
```

## Backup Strategy

### CronJob — 2-Container Pattern

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: acme-db-backup
  namespace: acme
spec:
  schedule: "0 20 * * *"  # 20:00 UTC = 01:30 IST
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      activeDeadlineSeconds: 900
      template:
        spec:
          initContainers:
            - name: pg-dump
              image: postgres:16-alpine
              command: ["sh", "-c"]
              args:
                - |
                  FILENAME="acme_platform_$(date +%Y%m%d_%H%M%S).sql.gz"
                  pg_dump "$DATABASE_URL" | gzip > /backup/$FILENAME
                  echo $FILENAME > /backup/LATEST
              env:
                - name: DATABASE_URL
                  valueFrom:
                    secretKeyRef:
                      name: backend-secrets
                      key: DIRECT_URL
              volumeMounts:
                - name: backup-vol
                  mountPath: /backup
          containers:
            - name: upload
              image: amazon/aws-cli:2.15.30
              command: ["sh", "-c"]
              args:
                - |
                  FILENAME=$(cat /backup/LATEST)
                  aws s3 cp /backup/$FILENAME s3://$S3_BUCKET/daily/$FILENAME
              envFrom:
                - secretRef:
                    name: backup-secrets
              volumeMounts:
                - name: backup-vol
                  mountPath: /backup
          volumes:
            - name: backup-vol
              emptyDir: {}
          restartPolicy: Never
```

**Why 2-container pattern:**
- `pg-dump` container has `DATABASE_URL` — no S3 credentials
- `upload` container has S3 credentials — no database credentials
- If either is compromised, the attacker gets access to only one system

### S3 Bucket Configuration

```bash
# Create bucket with Object Lock
aws s3api create-bucket \
  --bucket project-backups \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1 \
  --object-lock-enabled-for-bucket

# Set default retention (90 days Compliance mode)
aws s3api put-object-lock-configuration \
  --bucket project-backups \
  --object-lock-configuration '{
    "ObjectLockEnabled": "Enabled",
    "Rule": {
      "DefaultRetention": {
        "Mode": "COMPLIANCE",
        "Days": 90
      }
    }
  }'

# Lifecycle: transition to Glacier IR after 30 days
aws s3api put-bucket-lifecycle-configuration \
  --bucket project-backups \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "archive-old-backups",
      "Status": "Enabled",
      "Filter": { "Prefix": "daily/" },
      "Transitions": [{
        "Days": 30,
        "StorageClass": "GLACIER_IR"
      }]
    }]
  }'
```

### IAM — Write-Only Backup User

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject"],
    "Resource": "arn:aws:s3:::project-backups/*"
  }]
}
```

The backup user can only upload — it cannot list, read, or delete backups. Even if the backup credentials are compromised, existing backups cannot be exfiltrated or destroyed.

## Recovery

### Restore from S3 Backup

```bash
# List available backups
aws s3 ls s3://project-backups/daily/ --profile backup-reader

# Download the backup
aws s3 cp s3://project-backups/daily/acme_platform_20260901_093758.sql.gz /tmp/

# Restore (connect directly to Postgres, NOT through PgBouncer)
gunzip -c /tmp/acme_platform_20260901_093758.sql.gz | \
  psql -h 10.43.100.100 -p 5432 -U app_user -d acme_platform
```

**Warning:** Restore requires a separate IAM user with `s3:GetObject` permission — the backup writer cannot read.

## Known Risks

1. **Single-replica PostgreSQL** — No failover. A pod restart means downtime (typically 10-30 seconds). A volume failure means data loss back to the last backup. Mitigation: daily backups, future plan for WAL archiving + streaming replica.

2. **Liveness probe sensitivity** — Default `failureThreshold: 3` with `timeoutSeconds: 1` means 3 seconds of unresponsiveness triggers a pod kill. During crash recovery or a checkpoint stall, this can create a restart loop. Set `timeoutSeconds: 5` and `failureThreshold: 6` for safety.

3. **Shared superuser** — All databases use `app_user` with superuser privileges. A SQL injection in any app could affect all databases. Mitigation: scoped service users for runtime access; superuser only for admin tasks.

4. **Recovery Point Objective (RPO)** — With daily backups at 20:00 UTC, a failure at 19:59 UTC loses nearly 24 hours of data. Continuous WAL archiving would reduce RPO to minutes.
