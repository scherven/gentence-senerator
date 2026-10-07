#!/bin/bash
# Invite codes for the app.
#   ./invite.sh new <name>     mint a code for <name> and print it
#   ./invite.sh list           every code and who has it
#   ./invite.sh revoke <code>  stop a code working (within a minute)
set -euo pipefail
cd "$(dirname "$0")"
kv() { npx wrangler kv key "$@" --binding STATE --remote; }

case "${1:-}" in
  new)
    name="${2:?name}"
    # No 0/O/1/I: it gets read off a message and typed.
    code=$(LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' </dev/urandom | head -c 8)
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
    kv delete "invite:${2:?code}"
    ;;
  *) sed -n 2,5p "$0"; exit 1 ;;
esac
