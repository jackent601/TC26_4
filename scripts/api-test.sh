#!/usr/bin/env bash
# Run the API unit tests (api/tests) in a short-lived container. No database
# needed. Exits 0 when everything passes.
# Usage (from anywhere in the repo, e.g. Git Bash):  scripts/api-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."

docker compose --profile test build api-test || exit 1
docker compose --profile test run --rm api-test
