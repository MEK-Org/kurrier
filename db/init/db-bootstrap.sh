#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve migrations directory from multiple possible mount points or relative location
if [ -d "${MIGRATIONS_DIR:-}" ]; then
  MIGRATIONS_PATH="$MIGRATIONS_DIR"
elif [ -d "$SCRIPT_DIR/migrations" ]; then
  MIGRATIONS_PATH="$SCRIPT_DIR/migrations"
elif [ -d "/scripts/migrations" ]; then
  MIGRATIONS_PATH="/scripts/migrations"
elif [ -d "/db/init/migrations" ]; then
  MIGRATIONS_PATH="/db/init/migrations"
else
  echo "❌ Error: Could not locate migrations directory." >&2
  exit 1
fi

if [ -n "${DATABASE_URL:-}" ]; then
  echo "🟡 Waiting for Postgres via DATABASE_URL..."

  until pg_isready -d "$DATABASE_URL" >/dev/null 2>&1; do
    sleep 2
  done

  PSQL=(psql "$DATABASE_URL" -v ON_ERROR_STOP=1)
else
  PGHOST="${PGHOST:-postgres}"
  PGUSER="${PGUSER:-${POSTGRES_USER:-postgres}}"
  PGDATABASE="${PGDATABASE:-${POSTGRES_DB:-postgres}}"

  echo "🟡 Waiting for Postgres at $PGHOST..."

  until pg_isready -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" >/dev/null 2>&1; do
    sleep 2
  done

  PSQL=(
    psql
    -h "$PGHOST"
    -U "$PGUSER"
    -d "$PGDATABASE"
    -v ON_ERROR_STOP=1
  )
fi

echo "✅ Postgres is ready."

# Determine RLS user and password without exposing secrets in logs
RLS_USER="kurrier"
RLS_PASSWORD=""

if [ -n "${DATABASE_RLS_URL:-}" ]; then
  # Parse credentials from DATABASE_RLS_URL: postgresql://[user[:password]@]host...
  url_without_proto="${DATABASE_RLS_URL#*://}"
  userpass="${url_without_proto%%@*}"
  if [[ "$userpass" == *":"* ]]; then
    RLS_USER="${userpass%%:*}"
    RLS_PASSWORD="${userpass#*:}"
  elif [ -n "$userpass" ] && [ "$userpass" != "$url_without_proto" ]; then
    RLS_USER="$userpass"
  fi
fi

if [ -z "$RLS_PASSWORD" ]; then
  RLS_PASSWORD="${RLS_CLIENT_PASSWORD:-${POSTGRES_PASSWORD:-}}"
fi

echo "🧩 Ensuring auth schema and database roles exist..."
"${PSQL[@]}" <<'SQL'
CREATE SCHEMA IF NOT EXISTS "auth";
SQL

if [ -n "$RLS_PASSWORD" ]; then
  "${PSQL[@]}" -v rls_user="$RLS_USER" -v rls_pw="$RLS_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'rls_user')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = :'rls_user'
)\gexec

SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'rls_user', :'rls_pw')\gexec
SQL
fi

echo "🧩 Ensuring migrations table exists..."
"${PSQL[@]}" <<'SQL'
CREATE TABLE IF NOT EXISTS public.migrations (
  version text PRIMARY KEY,
  applied_at timestamptz DEFAULT now()
);
SQL

echo "🚀 Applying new migrations from $MIGRATIONS_PATH..."
for file in $(ls "$MIGRATIONS_PATH"/*.sql | sort); do
  base=$(basename "$file")
  version="${base%.sql}"

  exists=$(
    "${PSQL[@]}" -tA \
      -c "SELECT 1 FROM public.migrations WHERE version = '$version' LIMIT 1"
  )

  if [ "$exists" = "1" ]; then
    echo "⏭️  Skipping $base (already applied)"
  else
    echo "🟢 Running $base ..."

    "${PSQL[@]}" -f "$file"

    "${PSQL[@]}" \
      -c "INSERT INTO public.migrations(version) VALUES ('$version');"
  fi
done

echo "✅ All migrations done."
echo "✅ Bootstrap complete."
