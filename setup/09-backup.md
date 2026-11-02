# 09 — Database Backups (S3)

Set up automated daily backups: `pg_dump` → gzip → S3, with Object Lock (immutable for 90 days), lifecycle to Glacier, and a separate IAM user that can only write (never read or delete backups).

Two things in this guide are deliberately different from the rest of the blueprint, and both exist because of how a real restore goes wrong:

- **The backup credentials do not come from Infisical.** Every other Secret in this blueprint does. This one cannot, because you need it in exactly the situation where Infisical is gone. See Step 4.
- **The Infisical database is backed up too**, not just the application database. On a single-node cluster the vault is one directory on one disk. Backing up your data and not your credentials means a node loss is recoverable for the first and permanent for the second.

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

## Step 4: Create the backup Secret OUT OF BAND

> **Do not store these in Infisical.** It is the natural thing to do — it is what every other
> guide here tells you — and it produces a backup system that cannot be used in the one
> situation it exists for.
>
> Walk the failure through: the node dies, or the Infisical database is corrupted, or the
> machine identity is revoked. You rebuild the cluster from git, which works, because ArgoCD
> holds everything. Then you need the credentials, which were in the vault. The vault is in a
> backup. The backup job reads its S3 credentials from the vault. **Restoring the vault
> requires the vault.**
>
> This is not a hypothetical ordering problem; it is the ordering of every real restore.

Create the Secret directly, so the values never pass through Infisical, through git, or through
your shell history:

```bash
read -rsp 'AWS secret access key: ' SK && echo
read -rsp 'postgres password: '     PW && echo

kubectl -n {{NAMESPACE}} create secret generic backup-secrets \
  --from-literal=AWS_ACCESS_KEY_ID='AKIA...' \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SK" \
  --from-literal=DATABASE_URL="postgresql://{{DB_USER}}:${PW}@postgres.shared:5432/{{DB_NAME}}" \
  --from-literal=INFISICAL_DATABASE_URL="postgresql://infisical:${PW}@postgres.shared:5432/infisical"

unset SK PW
```

Then put the same four values somewhere a dead cluster cannot take with it — a password
manager, or printed and in a drawer. **Write them into your runbook as the first thing a
restore needs.** A credential that only exists inside the cluster is not a backup credential.

`templates/backend/backup-secrets.yaml` documents the shape and carries these warnings. It is
no longer an `InfisicalSecret`.

Verify:

```bash
kubectl -n {{NAMESPACE}} get secret backup-secrets -o jsonpath='{.data}' | jq -r 'keys[]'
```

Expected: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `DATABASE_URL`, `INFISICAL_DATABASE_URL`

## Step 5: Confirm the vault is in the backup set

`INFISICAL_DATABASE_URL` is what makes the CronJob dump the vault alongside your application
database. It is marked `optional: true` in the manifest so the job still runs without it — which
means **a missing key does not fail anything**. It prints one line and moves on:

```
SKIP infisical: no connection URL set
```

If you see that line in Step 7, your credentials are not in your backups. Check for it
explicitly; nothing else will tell you.

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

## Restore order

Write this down somewhere outside the cluster. A restore is not "put the data back"; it is a
sequence, and getting the order wrong is how people discover the deadlock in Step 4 at the worst
possible moment.

1. **The four values from Step 4**, from your password manager or your drawer. Nothing below
   works without them, and nothing in the cluster can give them to you.
2. **Rebuild the cluster from git.** ArgoCD, the namespaces, the workloads. This part is easy and
   it is why the GitOps repo exists.
3. **Restore the `infisical` database** from the dump, and bring Infisical up. Now the operator
   can write every other Secret, and the apps have their credentials.
4. **Restore the application database.**
5. Only now start the applications. An app that boots against a restored-but-empty database may
   write defaults over what you are about to restore.

The honest test of a backup system is not whether the job is green. It is whether somebody who
is not you, holding only step 1, can get to step 5.

---

## Backup verification checklist

- [ ] CronJob is scheduled and not suspended
- [ ] Test backup completed successfully
- [ ] **The log shows a dump for the `infisical` database, not `SKIP infisical`**
- [ ] Both backup files exist in S3
- [ ] Backup files are > 0 bytes (check for empty dumps)
- [ ] **A dump restores cleanly — not just "the file is there"** (see the truncation note below)
- [ ] Restore to a test database works
- [ ] Object Lock prevents deletion
- [ ] IAM user can only PutObject (test: `aws s3 ls` should fail with this user)
- [ ] **The four Step 4 values exist somewhere outside this cluster**
- [ ] Somebody other than you has done a restore drill from the runbook

---

## Troubleshooting

### The backup "succeeded" but the dump is truncated

The most dangerous failure in this whole guide, because every indicator says success.

`pg_dump | gzip` discards `pg_dump`'s exit status — the shell reports the status of `gzip`, which
happily compresses a half-finished stream. The result is a real, valid `.gz` file. `gzip -t`
passes on it. It uploads. The CronJob goes green. You find out months later, restoring.

The CronJob guards against this by checking for the trailer `pg_dump` writes only after a
complete dump:

```sh
gzip -dc "$FILE" | tail -5 | grep -q "PostgreSQL database dump complete" || exit 1
```

If you change the dump step, keep that check. "The file exists and is a valid archive" is not the
same claim as "the dump finished", and only the second one restores.

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

- Daily automated backups at 20:00 UTC, covering **both** the application database and the
  Infisical vault
- Backup credentials that live outside the thing they restore, so the restore path has no cycle
- A dump that refuses to upload itself when it is truncated
- Object Lock (immutable for 90 days)
- Lifecycle to Glacier IR after 30 days
- Isolated IAM (write-only, no read/delete)
- Tested restore procedure, and a written restore order

**Next:** [10-scaling.md](./10-scaling.md) — configure HPA and resource management.
