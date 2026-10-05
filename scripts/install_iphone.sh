#!/usr/bin/env bash
# Builds Hisaably, signs it for another 7 days (free Apple ID) and installs it
# OVER the existing app on an iPhone, so the login and data stay.
#
# Usage:
#   scripts/install_iphone.sh [prod|dev] [device name]
#   scripts/install_iphone.sh list            # show the iPhones this Mac knows
#
# Examples:
#   scripts/install_iphone.sh                          # prod on the only connected iPhone
#   scripts/install_iphone.sh prod "Admin's iPhone"
#   scripts/install_iphone.sh dev gravit               # part of the name is enough
#   scripts/install_iphone.sh prod strawhat
#
# The name match ignores case, spaces, apostrophes and emoji. The phone must be
# unlocked, trusted, in Developer Mode, and connected by cable or on the same
# Wi-Fi as this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

devices_json() {
  local out
  out="$(mktemp)"
  xcrun devicectl list devices --json-output "$out" >/dev/null 2>&1
  cat "$out"
  rm -f "$out"
}

# Prints: name<TAB>udid<TAB>state for each iPhone.
list_iphones() {
  devices_json | python3 -c '
import json, sys
for d in json.load(sys.stdin)["result"]["devices"]:
    hw, conn = d["hardwareProperties"], d["connectionProperties"]
    if hw.get("platform") != "iOS":
        continue
    state = "connected" if conn.get("tunnelState") == "connected" or conn.get("transportType") else "not connected"
    print("\t".join([d["deviceProperties"]["name"], hw["udid"], state]))
'
}

if [[ "${1:-}" == "list" ]]; then
  list_iphones | awk -F'\t' '{printf "%-28s %s\n", $1, $3}'
  exit 0
fi

ENV_NAME="prod"
if [[ "${1:-}" == "prod" || "${1:-}" == "dev" ]]; then
  ENV_NAME="$1"
  shift
fi
QUERY="$*"
ENV_FILE="env/${ENV_NAME}.json"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE"; exit 1; }

# Pick the device: by (part of) its name, or the only connected iPhone.
MATCH="$(list_iphones | QUERY="$QUERY" python3 -c '
import os, re, sys
norm = lambda s: re.sub(r"[^a-z0-9]", "", s.lower())
q = norm(os.environ["QUERY"])
rows = [line.rstrip("\n").split("\t") for line in sys.stdin if line.strip()]
if q:
    hits = [r for r in rows if q in norm(r[0])]
else:
    hits = [r for r in rows if r[2] == "connected"]
if len(hits) == 1:
    print("\t".join(hits[0]))
else:
    what = "matching " + repr(os.environ["QUERY"]) if q else "connected"
    sys.stderr.write(f"Found {len(hits)} iPhones {what}. Known iPhones:\n")
    for r in rows:
        sys.stderr.write(f"  {r[0]}  ({r[2]})\n")
    sys.stderr.write("Pass (part of) the name, e.g.: scripts/install_iphone.sh prod admin\n")
    sys.exit(1)
')"
NAME="$(cut -f1 <<<"$MATCH")"
UDID="$(cut -f2 <<<"$MATCH")"

echo "== Installing Hisaably ($ENV_NAME) on ${NAME}"
# flutter run builds for this exact device (registering it with the signing
# team if needed), installs over the existing app, launches it and exits.
flutter run -d "$UDID" --release --no-resident --dart-define-from-file="$ENV_FILE"
echo "Done: Hisaably ($ENV_NAME) is on ${NAME}, signed for another 7 days."
