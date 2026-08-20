#!/bin/bash
# Renders the icon and packages it as AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

swift tools/MakeIcon.swift

SET="tools/AppIcon.iconset"
rm -rf "$SET"; mkdir -p "$SET"
SRC="tools/icon-1024.png"

# The exact names iconutil expects; anything else is silently ignored.
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$SRC" --out "$SET/$2.png" >/dev/null
done

mkdir -p Resources
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$SET"
echo "wrote Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
