#!/usr/bin/env bash
# Renders the real app screens (fake backend) to build/screenshots/*.png.
set -euo pipefail
cd "$(dirname "$0")/.."
FLUTTER_ROOT="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
export FLUTTER_ROOT RENDER_SCREENS=1
rm -rf build/screenshots
flutter test test/screenshots "$@"
ls -1 build/screenshots
