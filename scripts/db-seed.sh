#!/usr/bin/env bash
# Load or reset the DEMO tenant's sample data by calling api.reset_demo_data()
# (the same function the UI's "Reset demo data" will use). Wipes and reloads
# DEMO only; other tenants are untouched. Needs the db service running
# (scripts/db-up.sh). For a completely clean database use scripts/db-reset.sh.
# Usage (from anywhere in the repo, e.g. Git Bash):  scripts/db-seed.sh
set -uo pipefail
cd "$(dirname "$0")/.."

# Runs psql inside the db container, as the database owner from .env.
docker compose exec -T db sh -c 'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
begin;
select api.use_tenant('DEMO') \gset
select * from api.reset_demo_data();
commit;
SQL
status=$?
echo
if [ "$status" -ne 0 ]; then
  echo "FAILED (exit code $status). Is the database running? Try scripts/db-up.sh first."
  exit 1
fi
echo "Demo data loaded."
