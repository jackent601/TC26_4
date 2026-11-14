#!/usr/bin/env bash
# The API contract (decision D22) is the OpenAPI document generated from the
# database's api schema. This keeps a snapshot of it in api/openapi.json so
# changes to the contract show up in commits.
#
#   scripts/api-contract.sh          update api/openapi.json from the running API
#   scripts/api-contract.sh --check  fail if the running API differs from the snapshot
#
# Needs the api service running (docker compose up -d --build api).
set -uo pipefail
cd "$(dirname "$0")/.."

snapshot=api/openapi.json
current=$(docker compose exec -T api python -c '
import json, urllib.request
doc = json.load(urllib.request.urlopen("http://localhost:8000/api/openapi.json"))
print(json.dumps(doc, indent=2, sort_keys=True))
') || { echo "Could not read the contract. Is the api service running?"; exit 1; }

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
