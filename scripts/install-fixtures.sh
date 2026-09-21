#!/usr/bin/env bash
# Copies ./fixtures into the booted simulator's "On My iPhone > Mango" (the app's Documents),
# which Mango scans on launch.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.vanities.mango"
[ -d fixtures ] || { echo "No fixtures yet — run: make fixtures"; exit 1; }

CONTAINER=$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null) || {
  echo "Mango isn't installed on the booted simulator. Run: make run"; exit 1; }

DEST="$CONTAINER/Documents"
mkdir -p "$DEST"
cp -R fixtures/. "$DEST/"
echo "Copied $(find fixtures -type f | wc -l | tr -d ' ') files into $DEST"
echo "Pull to refresh in the Library tab, or relaunch the app."
