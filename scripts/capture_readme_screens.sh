#!/usr/bin/env bash
# Captures the README screenshots on an iOS simulator against the DEV backend,
# using a demo group with one Group Admin and one member (fictional data).
# Saves build/readme_screens/*.png; copy the ones you need to .github/readme/
# (e.g. `sips -Z 1040 in.png --out .github/readme/name.png`).
#
# Usage: DEMO_ADMIN_PASSWORD=… DEMO_MEMBER_PASSWORD=… DEMO_GROUP_ID=<uuid> \
#        scripts/capture_readme_screens.sh <simulator-id>
# The test signs in as the usernames `aarav` (Group Admin) and `meera` (member).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEMO_ADMIN_PASSWORD:?set DEMO_ADMIN_PASSWORD}"
: "${DEMO_MEMBER_PASSWORD:?set DEMO_MEMBER_PASSWORD}"
: "${DEMO_GROUP_ID:?set DEMO_GROUP_ID}"
DEVICE="${1:?simulator id (flutter devices)}"
rm -rf build/readme_screens
exec flutter drive \
  --driver=tool/readme_screenshots/driver.dart \
  --target=tool/readme_screenshots/capture_test.dart \
  -d "$DEVICE" \
  --dart-define-from-file=env/dev.json \
  --dart-define=DEMO_ADMIN_PASSWORD="$DEMO_ADMIN_PASSWORD" \
  --dart-define=DEMO_MEMBER_PASSWORD="$DEMO_MEMBER_PASSWORD" \
  --dart-define=DEMO_GROUP_ID="$DEMO_GROUP_ID"
