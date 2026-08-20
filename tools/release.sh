#!/bin/bash
# Cuts a release of Ark.
#
#   tools/release.sh 0.29.0 "What changed"
#
# Everything git-facing happens in the *mirror*, never here. This directory is
# inside claude-workspace, so tagging or releasing from it would put an Ark tag —
# and possibly a GitHub release — on the wrong repository. `gh` is given an
# explicit --repo for the same reason.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD"
MIRROR="${ARK_PUBLISH_DIR:-$HOME/.ark-publish}"
REPO="tannergrand/ark-browser"

VERSION="${1:?usage: tools/release.sh <version> [notes]}"
NOTES="${2:-}"
TAG="v$VERSION"

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 1; }

echo "$VERSION" > VERSION
./build.sh

# Ship the exact bundle that was just built and self-tested.
"$SRC/Ark.app/Contents/MacOS/Ark" --selftest >/tmp/ark-release-selftest.log 2>&1 || {
  echo "self-test failed — not releasing. See /tmp/ark-release-selftest.log" >&2
  exit 1
}

mkdir -p dist
ZIP="dist/Ark-$VERSION.zip"
rm -f "$ZIP"
# ditto, not zip: it preserves the bundle's signature and resource forks.
ditto -c -k --sequesterRsrc --keepParent Ark.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

# Source of truth first, then the mirror.
git add -A
git diff --cached --quiet || git commit -qm "ark $VERSION"
git push -q

./tools/publish.sh "Ark $VERSION"
git -C "$MIRROR" tag -f "$TAG" -m "Ark $VERSION" >/dev/null
git -C "$MIRROR" push -q -f origin "$TAG"

BODY="$NOTES

sha256: $SHA

Unsigned build. First launch: right-click Ark.app → Open, then confirm. macOS
blocks a double-click on an app without a Developer ID, and this has none."

gh release create "$TAG" "$SRC/$ZIP" --repo "$REPO" \
  --title "Ark $VERSION" --notes "$BODY"
echo "released $TAG  sha256=$SHA"
