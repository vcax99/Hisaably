#!/usr/bin/env bash
# Runs a command with the LINKED dev project's keys in its environment:
#   SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SERVICE_ROLE_KEY
# Keys are fetched with your Supabase CLI login and exist only in this
# process's environment: never printed, written to disk or committed.
# Usage: scripts/with_dev_keys.sh <command> [args...]
set -euo pipefail
cd "$(dirname "$0")/.."

REF="$(cat supabase/.temp/project-ref)"
KEYS_JSON="$(npx supabase projects api-keys --project-ref "$REF" -o json </dev/null 2>/dev/null)"

extract() {
  python3 -c "
import json, sys
t = sys.stdin.read(); d = json.loads(t[t.find('['):t.rfind(']') + 1])
print(next(k['api_key'] for k in d if k.get('name') == sys.argv[1] and k.get('type') == sys.argv[2]))
" "$1" "$2"
}

export SUPABASE_URL="https://${REF}.supabase.co"
export SUPABASE_PUBLISHABLE_KEY="$(extract default publishable <<<"$KEYS_JSON")"
export SUPABASE_SERVICE_ROLE_KEY="$(extract service_role legacy <<<"$KEYS_JSON")"
unset KEYS_JSON

exec "$@"
