#!/bin/bash
# Invite codes for the app.
#   ./invite.sh new <name>     mint a code for <name> and print it
#   ./invite.sh list           every code and who has it
#   ./invite.sh revoke <code>  stop a code working (within a minute)
set -euo pipefail
cd "$(dirname "$0")"
kv() { npx wrangler kv key "$@" --binding STATE --remote; }

npx wrangler whoami 2>/dev/null | grep "You are logged in" >/dev/null || npx wrangler login

case "${1:-}" in
  new)
    name="${2:?name}"
    # No 0/O/1/I: it gets read off a message and typed.
    # A finite read: cutting off an endless /dev/urandom pipe trips pipefail.
    code=$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' | cut -c1-8)
    code="${code:0:4}-${code:4:4}"
    kv put "invite:$code" "{\"name\":\"$name\",\"made\":\"$(date +%F)\"}" >/dev/null
    echo "$code  $name"
    ;;
  list)
    for key in $(kv list --prefix invite: | grep -o '"invite:[^"]*"' | tr -d '"'); do
      echo "${key#invite:}  $(kv get "$key")"
    done
    ;;
  revoke)
    # Deleting a key that doesn't exist succeeds silently, so check first.
    code=$(echo "${2:?code}" | tr '[:lower:]' '[:upper:]')
    if ! kv get "invite:$code" >/dev/null 2>&1; then
      echo "no such code: $code" >&2; exit 1
    fi
    kv delete "invite:$code" >/dev/null
    echo "revoked $code"
    ;;
  *) sed -n 2,5p "$0"; exit 1 ;;
esac
