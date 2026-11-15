#!/usr/bin/env bash
# Run the database tests (db/tests) in a throwaway database inside the
# db-test container. Does not touch the db service or its data.
# Exits 0 when everything passes, 1 otherwise.
# Usage (from anywhere in the repo, e.g. Git Bash):  scripts/db-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."

docker compose --profile test build db-test || exit 1
docker compose --profile test run --rm db-test
