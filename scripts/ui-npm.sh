#!/usr/bin/env bash
# Run npm for the UI inside the official node image (no Node needed on the host).
# The container joins the compose network, so http://api:3000 is reachable.
#   scripts/ui-npm.sh install                 install from package-lock.json
#   scripts/ui-npm.sh install some-package    add a dependency
#   scripts/ui-npm.sh run gen:api             regenerate the typed API client
#   scripts/ui-npm.sh run build               type-check and build into ui/dist
set -uo pipefail
cd "$(dirname "$0")/.."

if [ $# -eq 0 ]; then
  echo "Usage: scripts/ui-npm.sh <npm arguments>"; exit 1
fi

# --no-deps: don't start db/api; gen:api needs them running already (scripts/up.sh).
if docker compose run --rm --no-deps ui-dev npm "$@"; then
  echo "npm $*: OK"
else
  echo "npm $*: FAILED"; exit 1
fi
