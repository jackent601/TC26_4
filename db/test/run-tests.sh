#!/usr/bin/env bash
# Runs inside the db-test container. Expects /db/migrations, /db/setup and
# /db/tests to be mounted (see compose.yaml).
set -uo pipefail

PW=test-only
export PGDATA=/tmp/pgdata PGHOST=localhost PGPORT=5432 PGUSER=postgres PGPASSWORD=$PW PGDATABASE=accomm_test
export DATABASE_URL="postgres://postgres:$PW@localhost:5432/accomm_test?sslmode=disable"
export DBMATE_MIGRATIONS_DIR=/db/migrations DBMATE_NO_DUMP_SCHEMA=true

# Throwaway PostgreSQL, password-checked over TCP like the real one.
echo "$PW" > /tmp/pwfile && chown postgres /tmp/pwfile
mkdir -p "$PGDATA" && chown postgres "$PGDATA"
gosu postgres initdb -D "$PGDATA" -U postgres --pwfile=/tmp/pwfile \
  --auth-local=trust --auth-host=scram-sha-256 >/dev/null || exit 1
gosu postgres pg_ctl -D "$PGDATA" -o "-c listen_addresses=localhost" -l /tmp/pg.log -w start >/dev/null || exit 1
createdb accomm_test || exit 1

status=0

echo "== Applying migrations to an empty database"
dbmate up || exit 1
psql -q -v api_password=test-api-password -f /db/setup/roles.sql || exit 1

echo
echo "== Running tests"
pg_prove --failures /db/tests/*.sql || status=1

echo
echo "== Rolling back every migration, then re-applying"
n=$(ls /db/migrations/*.sql | wc -l)
rollback_ok=1
for _ in $(seq "$n"); do
  dbmate rollback >/dev/null || { echo "not ok: rollback failed"; rollback_ok=0; status=1; break; }
done
if [ "$rollback_ok" -eq 1 ]; then
  if dbmate up >/dev/null; then echo "ok: $n migrations rolled back and re-applied"
  else echo "not ok: re-apply failed"; status=1; fi
fi

echo
if [ "$status" -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED"; fi
exit "$status"
