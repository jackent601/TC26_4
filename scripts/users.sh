#!/usr/bin/env bash
# Manage the production login accounts (decision D41) in deploy/caddy/users.caddy.
# Usage (on the server, from anywhere in the repo):
#   scripts/users.sh list
#   scripts/users.sh set <username>              add a user or change their password (asks for it)
#   scripts/users.sh set <username> --generate   same, with a random password that is printed once
#   scripts/users.sh remove <username>
# Passwords are stored only as bcrypt hashes. If the ui service is running,
# it is restarted to pick up the change (a second or two of downtime).
set -uo pipefail
cd "$(dirname "$0")/.."

USERS_FILE=deploy/caddy/users.caddy
CADDY_IMAGE=caddy:2.11-alpine   # same Caddy as ui/Dockerfile

fail() { echo "FAILED: $*" >&2; exit 1; }
usage() { sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

valid_name() { [[ "$1" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || fail "username may use letters, digits and . _ @ - (up to 64)"; }

# Keep every line except the named user's (comments and blank lines dropped).
without_user() {
  [ -f "$USERS_FILE" ] || return 0
  awk -v n="$1" 'NF && $1 !~ /^#/ && $1 != n' "$USERS_FILE"
}

restart_ui() {
  if [ -n "$(docker compose ps -q ui 2>/dev/null)" ]; then
    docker compose restart ui >/dev/null || fail "could not restart ui"
    echo "ui restarted."
  else
    echo "ui is not running; the change applies when it starts."
  fi
}

cmd=${1:-}
case "$cmd" in
  list)
    [ -f "$USERS_FILE" ] || { echo "No users yet."; exit 0; }
    awk 'NF && $1 !~ /^#/ {print $1}' "$USERS_FILE"
    ;;

  set)
    name=${2:-}; [ -n "$name" ] || usage
    valid_name "$name"
    if [ "${3:-}" = "--generate" ]; then
      password=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20)
    elif [ -n "${3:-}" ]; then
      usage
    else
      read -rsp "Password for $name: " password; echo
      read -rsp "Same again: " again; echo
      [ "$password" = "$again" ] || fail "passwords don't match"
      [ ${#password} -ge 12 ] || fail "use at least 12 characters (or --generate)"
    fi
    # Caddy reads the password from stdin when it isn't a terminal, so it never
    # appears on a command line.
    hash=$(printf '%s\n' "$password" | docker run --rm -i "$CADDY_IMAGE" caddy hash-password 2>/dev/null | tail -1)
    [[ "$hash" == \$2* ]] || fail "could not hash the password"
    mkdir -p "$(dirname "$USERS_FILE")"
    { without_user "$name"; echo "$name $hash"; } > "$USERS_FILE.tmp" && mv "$USERS_FILE.tmp" "$USERS_FILE" \
      || fail "could not write $USERS_FILE"
    chmod 600 "$USERS_FILE" 2>/dev/null
    echo "Password set for $name."
    [ "${3:-}" = "--generate" ] && echo "Their password (shown once, send it privately): $password"
    restart_ui
    ;;

  remove)
    name=${2:-}; [ -n "$name" ] || usage
    awk -v n="$name" '$1 == n {f=1} END {exit !f}' "$USERS_FILE" 2>/dev/null || fail "no user called $name"
    without_user "$name" > "$USERS_FILE.tmp" && mv "$USERS_FILE.tmp" "$USERS_FILE" || fail "could not write $USERS_FILE"
    echo "Removed $name."
    [ -s "$USERS_FILE" ] || echo "Warning: no users left; the site won't start until you add one."
    restart_ui
    ;;

  *) usage ;;
esac
