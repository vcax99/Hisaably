#!/usr/bin/env bash
# Wires the notifications trigger to the send-push Edge Function on the
# LINKED project, and (optionally) installs the Firebase credentials.
#
#   scripts/configure_push_dispatch.sh                       # wiring + deploy
#   scripts/configure_push_dispatch.sh path/to/firebase-sa.json  # + FCM key
#
# - Stores the function URL in Vault ('push_dispatch_url').
# - Copies Vault's 'push_dispatch_secret' into the function secret
#   PUSH_DISPATCH_SECRET (via a 0600 temp file; never printed).
# - Optionally sets FCM_SERVICE_ACCOUNT from the given service-account JSON
#   (download it from Firebase console → Project settings → Service accounts;
#   keep it OUT of the repo — *.json under secrets/ is git-ignored).
# - Deploys send-push (it authenticates callers itself: --no-verify-jwt).
set -euo pipefail
cd "$(dirname "$0")/.."

REF="$(cat supabase/.temp/project-ref)"
URL="https://${REF}.supabase.co/functions/v1/send-push"

npx supabase db query --linked "
do \$\$
begin
  if exists (select 1 from vault.secrets where name = 'push_dispatch_url') then
    perform vault.update_secret(
      (select id from vault.secrets where name = 'push_dispatch_url'), '${URL}');
  else
    perform vault.create_secret('${URL}', 'push_dispatch_url', 'send-push function URL');
  end if;
end
\$\$;" </dev/null >/dev/null

ENV_FILE="$(mktemp)"
chmod 600 "$ENV_FILE"
trap 'rm -f "$ENV_FILE"' EXIT

npx supabase db query --linked \
  "select decrypted_secret as s from vault.decrypted_secrets where name = 'push_dispatch_secret'" \
  </dev/null 2>/dev/null | python3 -c "
import json, sys
t = sys.stdin.read(); d = json.loads(t[t.find('{'):t.rfind('}') + 1])
rows = d.get('rows') or d.get('result') or []
print('PUSH_DISPATCH_SECRET=' + rows[0]['s'])
" >"$ENV_FILE"

if [[ $# -ge 1 ]]; then
  python3 -c "
import json, sys
sa = json.load(open(sys.argv[1]))
for k in ('project_id', 'client_email', 'private_key'):
    assert k in sa, 'not a service-account JSON: missing ' + k
# One line; single quotes keep the JSON's \\n escapes literal.
print(\"FCM_SERVICE_ACCOUNT='\" + json.dumps(sa, separators=(',', ':')) + \"'\")
" "$1" >>"$ENV_FILE"
fi

npx supabase secrets set --env-file "$ENV_FILE" </dev/null >/dev/null
npx supabase functions deploy send-push --no-verify-jwt </dev/null 2>&1 | tail -1
echo "Push dispatch configured for ${REF}."
