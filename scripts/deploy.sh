#!/usr/bin/env bash
# Start or update the production stack on the server (decision D41, docs/deploy.md):
# database and migrations, API, and the UI rebuilt from ui/, behind HTTPS and
# the login. Run after every git pull.
# Usage (on the server):  scripts/deploy.sh
set -uo pipefail
cd "$(dirname "$0")/.."

env_value() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2-; }

echo "---- checks ----"
[ -f .env ] || { echo "FAILED: no .env (see docs/deploy.md)"; exit 1; }
[ "$(env_value COMPOSE_FILE)" = "compose.yaml:compose.prod.yaml" ] \
  || { echo "FAILED: .env needs COMPOSE_FILE=compose.yaml:compose.prod.yaml"; exit 1; }
site=$(env_value SITE_ADDRESS)
[ -n "$site" ] || { echo "FAILED: .env needs SITE_ADDRESS"; exit 1; }
grep -qE '^[^#[:space:]]+ \$2' deploy/caddy/users.caddy 2>/dev/null \
  || { echo "FAILED: no users yet; add one with scripts/users.sh set <username>"; exit 1; }
echo "OK ($site)"
echo

scripts/db-up.sh || exit 1

echo
echo "---- api, ui ----"
docker compose up -d --build api ui || { echo "FAILED"; exit 1; }

# Without a login the site must answer 401: that proves HTTPS works (the
# certificate can take a minute the first time) and the login is in front.
echo
echo "---- result ----"
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://$site/" || true)
  [ "$code" = "401" ] && { echo "https://$site/ : asks for a login (401). Deployed."; exit 0; }
  sleep 2
done
echo "https://$site/ : got '$code', expected 401."
echo "Check: docker compose logs ui   (DNS pointing at this server? ports 80 and 443 open?)"
echo "FAILED"
exit 1
