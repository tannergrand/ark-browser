#!/bin/bash
# Builds and launches the staging copy of Ark, leaving production untouched.
#
#   tools/stage.sh            build, install to /Applications, launch
#   tools/stage.sh --no-open  build and install only
#
# Staging is a separate app: com.tannergrandstaff.ark.staging, its own
# "Ark Staging" support folder, its own website data. Nothing it does can reach
# your real tabs, cookies or sessions.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh --staging
"./Ark Staging.app/Contents/MacOS/Ark" --selftest >/tmp/ark-staging-selftest.log 2>&1 || {
  echo "self-test failed — see /tmp/ark-staging-selftest.log" >&2
  exit 1
}

DEST="/Applications/Ark Staging.app"
if pgrep -f "$DEST/Contents/MacOS/Ark" >/dev/null 2>&1; then
  echo "==> quitting the running staging copy"
  pkill -f "$DEST/Contents/MacOS/Ark" || true
  sleep 1
fi
rm -rf "$DEST"
cp -R "./Ark Staging.app" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "==> installed $DEST"

if [ "${1:-}" != "--no-open" ]; then
  open "$DEST"
fi
