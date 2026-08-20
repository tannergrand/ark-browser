#!/bin/bash
# Cuts a release: bumps VERSION, builds, zips, publishes to GitHub Releases with
# the SHA-256 in the notes — which is what the in-app updater verifies against.
#
#   tools/release.sh 0.27.0 "What changed"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: tools/release.sh <version> [notes]}"
NOTES="${2:-}"
TAG="v$VERSION"

if ! command -v gh >/dev/null; then
  echo "gh CLI not found — install it or publish the release by hand." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit first — the release should match a commit." >&2
  exit 1
fi

echo "$VERSION" > VERSION
git add VERSION
git commit -qm "Ark $VERSION" || true

./build.sh

ZIP="dist/Ark-$VERSION.zip"
mkdir -p dist
rm -f "$ZIP"
# ditto keeps the bundle's signature and resource forks intact; `zip` does not.
ditto -c -k --sequesterRsrc --keepParent Ark.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

BODY="$NOTES

sha256: $SHA

Unsigned build. First launch: right-click Ark.app → Open, then confirm. macOS
blocks a double-click on an app without a Developer ID, and this has none."

git tag -f "$TAG"
git push -q origin HEAD --tags

gh release create "$TAG" "$ZIP" --title "Ark $VERSION" --notes "$BODY"
echo "released $TAG  sha256=$SHA"
