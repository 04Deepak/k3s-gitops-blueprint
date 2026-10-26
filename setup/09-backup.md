# 09 — Database Backups (S3)

Set up automated daily backups: `pg_dump` → gzip → S3, with Object Lock (immutable for 90 days), lifecycle to Glacier, and a separate IAM user that can only write (never read or delete backups).

**Time:** ~30 minutes

---

## Step 1: Create S3 bucket

In the AWS Console (or CLI):

```bash
# Set variables
BUCKET="{{PROJECT_NAME}}-backups"
REGION="{{AWS_REGION}}"

# Create bucket with Object Lock enabled
aws s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION" \
  --object-lock-enabled-for-bucket

# Enable versioning (required for Object Lock)
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# Set default Object Lock retention (Compliance mode, 90 days)
aws s3api put-object-lock-configuration \
  --bucket "$BUCKET" \
  --object-lock-configuration '{
    "ObjectLockEnabled": "Enabled",
    "Rule": {
      "DefaultRetention": {
        "Mode": "COMPLIANCE",
        "Days": 90
      }
    }
  }'

# Enable server-side encryption
aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

## Step 2: Add lifecycle rule (Glacier transition)

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "GlacierAfter30Days",
      "Status": "Enabled",
      "Filter": { "Prefix": "daily/" },
      "Transitions": [{
        "Days": 30,
        "StorageClass": "GLACIER_IR"
      }]
    }]
  }'
```

This moves backups older than 30 days to Glacier Instant Retrieval (cheaper storage, same access speed).

## Step 3: Create IAM user (write-only)

```bash
# Create user
aws iam create-user --user-name {{PROJECT_NAME}}-backup-writer

# Create access key
aws iam create-access-key --user-name {{PROJECT_NAME}}-backup-writer
# Save the AccessKeyId and SecretAccessKey!
```

Attach a minimal policy — **PutObject only** (no read, no delete, no list):

```bash
cat > /tmp/backup-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPutOnly",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::{{PROJECT_NAME}}-backups/*"
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name {{PROJECT_NAME}}-backup-writer \
  --policy-name backup-put-only \
  --policy-document file:///tmp/backup-policy.json
```

> **Why write-only?** If the server is compromised, the attacker can't read existing backups or delete them. Object Lock prevents deletion even with full AWS access.

## Step 4: Add backup credentials to Infisical

In Infisical, create secrets under path `/backup`:

| Key | Value |
|-----|-------|
| `AWS_ACCESS_KEY_ID` | (from step 3) |
| `AWS_SECRET_ACCESS_KEY` | (from step 3) |
| `AWS_DEFAULT_REGION` | `{{AWS_REGION}}` |
| `S3_BUCKET` | `{{PROJECT_NAME}}-backups` |

## Step 5: Apply InfisicalSecret for backup-secrets

```bash
kubectl apply -f templates/backend/backup-secrets.yaml -n {{NAMESPACE}}
```

Wait 60 seconds, then verify:

```bash
kubectl -n {{NAMESPACE}} get secret backup-secrets -o jsonpath='{.data}' | jq -r 'keys[]'
```

Expected: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`, `S3_BUCKET`

## Step 6: Apply backup CronJob

```bash
kubectl apply -f templates/backend/backup-cronjob.yaml -n {{NAMESPACE}}
```

The CronJob uses a two-container pattern:

1. **initContainer `pg-dump`** (postgres:16-alpine):
   - Connects directly to PostgreSQL (not PgBouncer — dumps need consistent reads)
   - Runs `pg_dump | gzip > /backup/dump.sql.gz`
   - Writes to shared emptyDir volume

2. **Main container `upload`** (amazon/aws-cli):
   - Reads the dump from the shared volume
   - Uploads to `s3://BUCKET/daily/DB_YYYYMMDD_HHMMSS.sql.gz`
   - Only has access to `backup-secrets` (not `backend-secrets`)

Schedule: `0 20 * * *` (20:00 UTC — adjust to your timezone).

## Step 7: Run a test backup

```bash
kubectl -n {{NAMESPACE}} create job test-backup --from=cronjob/db-backup
```

Watch it:

```bash
kubectl -n {{NAMESPACE}} get pods -l job-name=test-backup -w
```

Wait for `Completed`, then check logs:

```bash
# pg_dump step
kubectl -n {{NAMESPACE}} logs job/test-backup -c pg-dump

# Upload step
kubectl -n {{NAMESPACE}} logs job/test-backup -c upload
```

Expected upload output:

```
upload: ./dump.sql.gz to s3://{{PROJECT_NAME}}-backups/daily/{{DB_NAME}}_20260904_200000.sql.gz
```

Verify in S3:

```bash
aws s3 ls s3://{{PROJECT_NAME}}-backups/daily/ --region {{AWS_REGION}}
```

Clean up the test job:

```bash
kubectl -n {{NAMESPACE}} delete job test-backup
```

## Step 8: Test restore procedure

It's not a backup until you've tested the restore.

```bash
# Download the backup (you'll need a user with s3:GetObject)
aws s3 cp s3://{{PROJECT_NAME}}-backups/daily/{{DB_NAME}}_20260904_200000.sql.gz /tmp/

# Decompress
gunzip /tmp/{{DB_NAME}}_20260904_200000.sql.gz

# Restore to a test database
kubectl -n shared exec -it postgres-0 -- psql -U {{DB_USER}} -d postgres -c "CREATE DATABASE restore_test;"

# Copy the dump file to the pod
kubectl -n shared cp /tmp/{{DB_NAME}}_20260904_200000.sql postgres-0:/tmp/restore.sql

# Restore
kubectl -n shared exec -it postgres-0 -- psql -U {{DB_USER}} -d restore_test -f /tmp/restore.sql

# Verify
kubectl -n shared exec -it postgres-0 -- psql -U {{DB_USER}} -d restore_test -c "\dt"
# Should list all your tables

# Clean up
kubectl -n shared exec -it postgres-0 -- psql -U {{DB_USER}} -d postgres -c "DROP DATABASE restore_test;"
kubectl -n shared exec -it postgres-0 -- rm /tmp/restore.sql
```

---

## Backup verification checklist

- [ ] CronJob is scheduled and not suspended
- [ ] Test backup completed successfully
- [ ] Backup file exists in S3
- [ ] Backup file is > 0 bytes (check for empty dumps)
- [ ] Restore to a test database works
- [ ] Object Lock prevents deletion
- [ ] IAM user can only PutObject (test: `aws s3 ls` should fail with this user)

---

## Troubleshooting

### CronJob never runs

```bash
kubectl -n {{NAMESPACE}} get cronjob db-backup
```

Check `SUSPEND` column — must be `False`. Check `LAST SCHEDULE` — if empty, the schedule hasn't triggered yet.

### pg_dump fails

```bash
kubectl -n {{NAMESPACE}} logs job/db-backup-xxx -c pg-dump
```

Common causes:
- **Wrong DATABASE_URL:** Must use DIRECT_URL (not PgBouncer)
- **Connection refused:** Postgres pod not running
- **Permission denied:** The DB user doesn't have read access to all tables

### Upload fails

```bash
kubectl -n {{NAMESPACE}} logs job/db-backup-xxx -c upload
```

Common causes:
- **Invalid credentials:** Check backup-secrets
- **Bucket doesn't exist:** Verify bucket name and region
- **Permission denied:** IAM policy is wrong

---

## What you have now

- Daily automated backups at 20:00 UTC
- Object Lock (immutable for 90 days)
- Lifecycle to Glacier IR after 30 days
- Isolated IAM (write-only, no read/delete)
- Tested restore procedure

**Next:** [10-scaling.md](./10-scaling.md) — configure HPA and resource management.
