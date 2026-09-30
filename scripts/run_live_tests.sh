#!/usr/bin/env bash
# Flutter tests that talk to the real dev backend (test/live). They create and
# delete their own throwaway users.
set -euo pipefail
cd "$(dirname "$0")/.."
exec scripts/with_dev_keys.sh flutter test test/live "$@"
