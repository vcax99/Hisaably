#!/usr/bin/env bash
# Every automated check except on-device flows (see run_device_flows.sh):
# format, analyze, unit/widget tests, SQL smoke suites (rolled back), live
# backend tests. Exits non-zero on the first failure.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== format";  dart format --output=none --set-exit-if-changed lib test integration_test test_driver
echo "== analyze"; flutter analyze
echo "== unit/widget tests"; flutter test

echo "== SQL smoke suites (linked project; all changes rolled back)"
for f in supabase/tests/smoke/*.sql; do
  out="$(npx supabase db query --linked -f "$f" </dev/null 2>&1 || true)"
  if grep -q "SMOKE_OK" <<<"$out"; then
    echo "  ok  $(basename "$f"): $(grep -oE 'SMOKE_OK: [0-9]+ checks' <<<"$out")"
  else
    echo "  FAIL $(basename "$f")"; grep -oE '(FAIL|ERROR)[^\\]*' <<<"$out" | head -3
    exit 1
  fi
done

echo "== live backend tests"; scripts/run_live_tests.sh
echo "== admin-users Edge Function E2E"; supabase/tests/e2e/run_admin_users_e2e.sh
echo "ALL CHECKS PASSED"
