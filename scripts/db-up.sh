#!/usr/bin/env bash
# Start the database, apply migrations and set role passwords, then show the
# output of the one-shot services and whether they succeeded.
# Usage (from anywhere in the repo, e.g. Git Bash):  scripts/db-up.sh
set -uo pipefail

# Remove the previous run's one-shot containers so the logs show this run only.
# (Only migrate and db-roles; the database and its data are untouched.)
docker compose rm -fs migrate db-roles >/dev/null 2>&1

# up -d waits for migrate to finish before starting db-roles, so if migrate
# fails this returns an error; carry on so its logs are still shown.
docker compose up -d db migrate db-roles
up_status=$?

echo
echo "---- migrate / db-roles output ----"
# -f follows until both have exited (they are one-shot services).
docker compose logs -f migrate db-roles

echo
echo "---- result ----"
result=0
for svc in migrate db-roles; do
  id=$(docker compose ps -a -q "$svc")
  if [ -z "$id" ]; then
    echo "$svc: did not run"
    result=1
    continue
  fi
  code=$(docker inspect -f '{{.State.ExitCode}}' "$id" 2>/dev/null || echo "unknown")
  echo "$svc: exit code $code"
  [ "$code" = "0" ] || result=1
done

echo
if [ "$up_status" -ne 0 ] || [ "$result" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "Database ready."
