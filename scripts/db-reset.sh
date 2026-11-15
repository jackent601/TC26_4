#!/usr/bin/env bash
# Wipe the LOCAL database volume, then rebuild it: migrations, role passwords
# and sample data. Gives a known state for development and demos.
# Usage (from anywhere in the repo, e.g. Git Bash):  scripts/db-reset.sh [-y]
set -uo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" != "-y" ]; then
  read -r -p "This deletes ALL data in the local database volume. Continue? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled."; exit 1 ;;
  esac
fi

# Stops the project's containers and removes its volumes (the database data).
docker compose down -v || exit 1
scripts/db-up.sh   || exit 1
echo
scripts/db-seed.sh || exit 1
