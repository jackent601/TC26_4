#!/usr/bin/env bash
# The API contract (decisions D22, D27) is the api schema: its views and
# functions with their types. PostgREST serves exactly that. This keeps a
# snapshot in db/api-contract.txt so changes to the contract show up in commits.
#
#   scripts/api-contract.sh          update db/api-contract.txt from the database
#   scripts/api-contract.sh --check  fail if the database differs from the snapshot
#
# Needs the db service running with migrations applied (scripts/db-up.sh).
set -uo pipefail
cd "$(dirname "$0")/.."

snapshot=db/api-contract.txt
current=$(docker compose exec -T db sh -c 'psql -X -q -At -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
          < db/setup/api_contract.sql) || { echo "Could not read the contract. Is the database running?"; exit 1; }

if [ "${1:-}" = "--check" ]; then
  if [ ! -f "$snapshot" ]; then
    echo "No snapshot yet: run scripts/api-contract.sh to create $snapshot"; exit 1
  fi
  if diff -u "$snapshot" <(printf '%s\n' "$current"); then
    echo "Contract unchanged."
  else
    echo
    echo "The API contract has changed. If that is intended, run scripts/api-contract.sh and commit $snapshot."
    exit 1
  fi
else
  printf '%s\n' "$current" > "$snapshot"
  echo "Wrote $snapshot"
fi
