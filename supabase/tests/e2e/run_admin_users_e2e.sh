#!/usr/bin/env bash
# Runs admin_users_e2e.py against the LINKED dev project (keys via CLI login,
# kept in memory only — see scripts/with_dev_keys.sh).
set -euo pipefail
cd "$(dirname "$0")/../../.."
exec scripts/with_dev_keys.sh python3 supabase/tests/e2e/admin_users_e2e.py
