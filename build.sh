#!/bin/bash
# Builds Ark and wraps the binary in a proper .app bundle.
# WKWebView needs a bundle identifier and an Info.plist, so a bare
# `swift build` binary won't do — this script assembles both.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="release"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install) INSTALL=1 ;;
    *) echo "usage: ./build.sh [debug|release] [--install]"; exit 2 ;;
  esac
done
VERSION="$(cat VERSION 2>/dev/null || echo 0.1.0)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="Ark.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Ark"
[ -f "$BIN" ] || { echo "build produced no binary"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ark"

# The changelog ships inside the bundle: the what's-new page is rendered from it
# at runtime, so it has to travel with the app rather than living only in git.
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

# App icon. Regenerate with ./tools/make-icns.sh after editing MakeIcon.swift.
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Ark</string>
  <key>CFBundleDisplayName</key><string>Ark</string>
  <key>CFBundleExecutable</key><string>Ark</string>
  <key>CFBundleIdentifier</key><string>com.tannergrandstaff.ark</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>

  <!-- Declares Ark as a web browser so macOS lists it under
       System Settings > Desktop & Dock > Default web browser. -->
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web site URL</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>http</string>
        <string>https</string>
      </array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>HTML document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.html</string>
        <string>public.xhtml</string>
        <string>public.url</string>
      </array>
    </dict>
  </array>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
</dict>
</plist>
PLIST

# iCloud Keychain sync needs a real team identity; ad-hoc gets -34018.
# Set ARK_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" to
# sign properly, and sync turns itself on at next launch.
cat > "$APP/Contents/Resources/Ark.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>keychain-access-groups</key>
  <array><string>$(AppIdentifierPrefix)com.tannergrandstaff.ark</string></array>
</dict>
</plist>
ENT

# Signing identity, in order of preference:
#   1. ARK_SIGN_IDENTITY  — a real Apple Developer ID; also unlocks iCloud
#                             Keychain sync via the entitlements file.
#   2. "Ark Code Signing" — a local self-signed identity. No entitlements, but
#                             it gives the app a STABLE code identity, which is
#                             what makes the keychain's "Always Allow" persist.
#                             Ad-hoc signatures change every build, so macOS
#                             re-asks for consent on every single rebuild.
#   3. ad-hoc               — works, but expect a keychain prompt per rebuild.
LOCAL_IDENTITY="Ark Code Signing"
if [ -n "${ARK_SIGN_IDENTITY:-}" ]; then
  echo "==> signing as $ARK_SIGN_IDENTITY (keychain sync enabled)"
  codesign --force --options runtime \
    --entitlements "$APP/Contents/Resources/Ark.entitlements" \
    --sign "$ARK_SIGN_IDENTITY" "$APP"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$LOCAL_IDENTITY"; then
  echo "==> signing as $LOCAL_IDENTITY (stable identity; keychain consent sticks)"
  codesign --force --sign "$LOCAL_IDENTITY" "$APP"
else
  echo "==> ad-hoc signing — keychain will re-ask for consent on every rebuild."
  echo "    See README > Passwords for how to create a stable local identity."
  codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "   (signing skipped)"
fi

LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREG" ]; then
  echo "==> registering with Launch Services"
  "$LSREG" -f "$(pwd)/$APP" || echo "   (registration skipped)"
fi

# Being the default browser only sticks from a stable location. Running from
# the project folder works, but every rebuild re-registers a new bundle.
if [ "$INSTALL" = "1" ]; then
  DEST="/Applications/Ark.app"
  echo "==> installing to $DEST"
  if pgrep -f "$DEST/Contents/MacOS/Ark" >/dev/null 2>&1; then
    echo "   quitting the running copy first"
    pkill -f "$DEST/Contents/MacOS/Ark" || true
    sleep 1
  fi
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  [ -x "$LSREG" ] && "$LSREG" -f "$DEST"
  echo "   installed. Set it as default in Ark ▸ Settings ▸ General."
fi

echo "==> done: $(pwd)/$APP"
