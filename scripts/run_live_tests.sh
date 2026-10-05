#!/usr/bin/env bash
# Flutter tests that talk to the real dev backend (test/live). They create and
# delete their own throwaway users.
set -euo pipefail
cd "$(dirname "$0")/.."
# With arguments: only those tests (avoids Auth rate limits); else all.
if [[ $# -gt 0 ]]; then
  exec scripts/with_dev_keys.sh flutter test "$@"
fi
exec scripts/with_dev_keys.sh flutter test test/live
