#!/usr/bin/env bash
# Load or reset the DEMO tenant's sample data (db/seed/sample.sql, which calls
# api.reset_demo_data). Wipes and reloads DEMO only; other tenants are untouched.
# For a completely clean database use scripts/db-reset.sh.
# Usage (from anywhere in the repo, e.g. Git Bash):  scripts/db-seed.sh
set -uo pipefail
cd "$(dirname "$0")/.."

docker compose --profile seed run --rm db-seed
status=$?
echo
if [ "$status" -ne 0 ]; then
  echo "FAILED (exit code $status)"
  exit 1
fi
echo "Demo data loaded."
