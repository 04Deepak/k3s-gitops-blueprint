#!/usr/bin/env bash
# Restore a PostgreSQL backup from S3
#
# Usage: ./restore-backup.sh <s3_path> <target_database>
# Example: ./restore-backup.sh s3://my-backups/daily/mydb_20260901_093758.sql.gz my_app_db
#
# Prerequisites:
#   - AWS CLI configured (or run from a pod with AWS credentials)
#   - psql available (or run via kubectl exec on the postgres pod)
#
# Template placeholders:
#   {{SSH_HOST}} — server SSH alias

set -euo pipefail

S3_PATH="${1:?Usage: $0 <s3_path> <target_database>}"
TARGET_DB="${2:?Missing target database name}"
SUPERUSER="${POSTGRES_USER:-postgres}"
WORK_DIR="/tmp/db-restore-$$"

echo "═══════════════════════════════════════════"
echo "  Database Restore"
echo "  Source:  $S3_PATH"
echo "  Target:  $TARGET_DB"
echo "═══════════════════════════════════════════"
echo ""

# Confirm before proceeding
read -rp "This will DROP and recreate '$TARGET_DB'. Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

mkdir -p "$WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

# Step 1: Download from S3
echo ""
echo "Step 1: Downloading backup..."
FILENAME=$(basename "$S3_PATH")
aws s3 cp "$S3_PATH" "$WORK_DIR/$FILENAME"
echo "  Downloaded: $FILENAME ($(du -h "$WORK_DIR/$FILENAME" | cut -f1))"

# Step 2: Decompress if gzipped
SQL_FILE="$WORK_DIR/$FILENAME"
if [[ "$FILENAME" == *.gz ]]; then
  echo ""
  echo "Step 2: Decompressing..."
  gunzip "$SQL_FILE"
  SQL_FILE="${SQL_FILE%.gz}"
  echo "  Decompressed: $(du -h "$SQL_FILE" | cut -f1)"
else
  echo ""
  echo "Step 2: Not compressed, skipping..."
fi

# Step 3: Terminate existing connections
echo ""
echo "Step 3: Terminating existing connections to '$TARGET_DB'..."
psql -U "$SUPERUSER" -c "
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = '${TARGET_DB}'
    AND pid <> pg_backend_pid();
" 2>/dev/null || true

# Step 4: Drop and recreate database
echo ""
echo "Step 4: Dropping and recreating database..."
psql -U "$SUPERUSER" -c "DROP DATABASE IF EXISTS \"${TARGET_DB}\";"
psql -U "$SUPERUSER" -c "CREATE DATABASE \"${TARGET_DB}\";"

# Step 5: Restore
echo ""
echo "Step 5: Restoring..."
psql -U "$SUPERUSER" -d "$TARGET_DB" -f "$SQL_FILE" 2>&1 | tail -5
echo "  Restore complete."

# Step 6: Verify
echo ""
echo "Step 6: Verification..."
TABLE_COUNT=$(psql -U "$SUPERUSER" -d "$TARGET_DB" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")
TABLE_COUNT=$(echo "$TABLE_COUNT" | tr -d ' ')
echo "  Tables in '$TARGET_DB': $TABLE_COUNT"

# Show a few table row counts as spot checks
echo ""
echo "  Sample row counts:"
psql -U "$SUPERUSER" -d "$TARGET_DB" -t -c "
  SELECT schemaname || '.' || relname AS table_name,
         n_live_tup AS row_count
  FROM pg_stat_user_tables
  ORDER BY n_live_tup DESC
  LIMIT 10;
"

echo ""
echo "═══════════════════════════════════════════"
echo "  Restore complete: $TARGET_DB"
echo "  Tables: $TABLE_COUNT"
echo "═══════════════════════════════════════════"
