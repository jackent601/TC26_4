#!/usr/bin/env bash
# Start everything: database (with migrations and role passwords), API, API docs
# and the UI (rebuilt from ui/), then check each answers and print the URLs.
# Usage (Git Bash):  scripts/up.sh
# DEMO sample data is loaded on a new install (migration 0012); scripts/db-seed.sh reloads it.
set -uo pipefail
cd "$(dirname "$0")/.."

scripts/db-up.sh || exit 1

echo
echo "---- api, api-docs, ui ----"
docker compose up -d --build api api-docs ui || { echo "FAILED"; exit 1; }

# Read ports from .env if set there, with the same defaults as compose.
env_value() { grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2-; }
ui_port=$(env_value UI_PORT); ui_port=${ui_port:-8080}
api_port=$(env_value API_PORT); api_port=${api_port:-8000}
docs_port=$(env_value API_DOCS_PORT); docs_port=${docs_port:-8081}

# Caddy takes a moment to start listening.
check() {
  local name=$1 url=$2
  for _ in $(seq 1 20); do
    if curl -sf -o /dev/null "$url"; then echo "$name: OK  ($url)"; return 0; fi
    sleep 1
  done
  echo "$name: NOT RESPONDING  ($url)"; return 1
}

echo
echo "---- result ----"
result=0
check "UI         " "http://localhost:$ui_port/"            || result=1
check "API via UI " "http://localhost:$ui_port/api/health"  || result=1
check "API (dev)  " "http://localhost:$api_port/health"     || result=1
check "API docs   " "http://localhost:$docs_port/"          || result=1

echo
if [ "$result" -ne 0 ]; then echo "FAILED"; exit 1; fi
echo "All up. Open http://localhost:$ui_port"
