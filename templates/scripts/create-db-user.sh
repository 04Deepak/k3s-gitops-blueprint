#!/usr/bin/env bash
# Create a scoped PostgreSQL user with connection limit
#
# Usage: ./create-db-user.sh <username> <password> <database> <conn_limit>
# Example: ./create-db-user.sh app_prod_svc 'SecurePass123!' my_app_db 50
#
# Run this via kubectl exec on the Postgres pod:
#   kubectl exec -n shared statefulset/postgres -- bash -c "$(cat create-db-user.sh)" -- args...
#
# Or pipe it:
#   cat create-db-user.sh | ssh {{SSH_HOST}} 'kubectl exec -i -n shared statefulset/postgres -- bash -s' -- <user> <pass> <db> <limit>

set -euo pipefail

USERNAME="${1:?Usage: $0 <username> <password> <database> <conn_limit>}"
PASSWORD="${2:?Missing password}"
DATABASE="${3:?Missing database name}"
CONN_LIMIT="${4:-50}"

SUPERUSER="${POSTGRES_USER:-postgres}"

echo "Creating user '$USERNAME' with CONNECTION LIMIT $CONN_LIMIT on database '$DATABASE'..."

psql -U "$SUPERUSER" -v ON_ERROR_STOP=1 <<SQL
-- Create the user (idempotent: DO NOTHING if exists)
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${USERNAME}') THEN
    CREATE ROLE "${USERNAME}" LOGIN PASSWORD '${PASSWORD}' CONNECTION LIMIT ${CONN_LIMIT};
    RAISE NOTICE 'Created user %', '${USERNAME}';
  ELSE
    ALTER ROLE "${USERNAME}" PASSWORD '${PASSWORD}' CONNECTION LIMIT ${CONN_LIMIT};
    RAISE NOTICE 'Updated user %', '${USERNAME}';
  END IF;
END
\$\$;

-- Grant database access
GRANT CONNECT ON DATABASE "${DATABASE}" TO "${USERNAME}";
SQL

# Grant schema-level permissions (must connect to the target database)
psql -U "$SUPERUSER" -d "$DATABASE" -v ON_ERROR_STOP=1 <<SQL
GRANT USAGE ON SCHEMA public TO "${USERNAME}";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "${USERNAME}";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "${USERNAME}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO "${USERNAME}";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO "${USERNAME}";
SQL

echo ""
echo "Done. Connection URL:"
echo "  postgresql://${USERNAME}:${PASSWORD}@postgres.shared.svc.cluster.local:5432/${DATABASE}"
echo ""
echo "For PgBouncer (transaction pooling):"
echo "  postgresql://${USERNAME}:${PASSWORD}@pgbouncer.{{NAMESPACE}}.svc.cluster.local:5432/${DATABASE}?pgbouncer=true"
