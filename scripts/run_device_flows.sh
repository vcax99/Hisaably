#!/usr/bin/env bash
# Runs integration_test/app_flows_test.dart on a simulator/emulator against the
# dev backend. Screenshots land in build/device_screenshots/.
#
# Usage: QA_ADMIN_PASSWORD=... QA_MEMBER_PASSWORD=... scripts/run_device_flows.sh <device-id>
# (QA accounts qa_admin / qa_member live in the dev project; passwords are
#  never stored in the repo.)
set -euo pipefail
cd "$(dirname "$0")/.."
: "${QA_ADMIN_PASSWORD:?set QA_ADMIN_PASSWORD}"
: "${QA_MEMBER_PASSWORD:?set QA_MEMBER_PASSWORD}"
DEVICE="${1:?device id (flutter devices)}"
exec flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/app_flows_test.dart \
  -d "$DEVICE" \
  --dart-define-from-file=env/dev.json \
  --dart-define=QA_ADMIN_PASSWORD="$QA_ADMIN_PASSWORD" \
  --dart-define=QA_MEMBER_PASSWORD="$QA_MEMBER_PASSWORD"
