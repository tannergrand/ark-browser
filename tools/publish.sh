#!/bin/bash
# Mirrors this folder into its own git repo and pushes to GitHub.
#
# Why a mirror: the source of truth lives inside claude-workspace, which also
# holds unrelated personal files. Publishing a subtree of that repo would carry
# its commit history along, so the public repo gets its own history and only
# ever sees this directory. The mirror lives outside the workspace so no nested
# .git confuses the outer repo.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD"
MIRROR="${ARK_PUBLISH_DIR:-$HOME/.ark-publish}"
REPO="tannergrand/ark-browser"
MESSAGE="${1:-Sync from working tree}"

mkdir -p "$MIRROR"
if [ ! -d "$MIRROR/.git" ]; then
  git -C "$MIRROR" init -q -b main
  git -C "$MIRROR" remote add origin "git@github.com:$REPO.git" 2>/dev/null || true
fi

# --delete keeps the mirror an exact copy; excludes keep build output and the
# mirror's own git metadata out of it.
rsync -a --delete \
  --exclude '.git/' --exclude '.build/' --exclude 'Ark.app/' --exclude 'dist/' \
  --exclude '.DS_Store' \
  "$SRC"/ "$MIRROR"/

git -C "$MIRROR" add -A
if git -C "$MIRROR" diff --cached --quiet; then
  echo "nothing to publish"
else
  git -C "$MIRROR" commit -qm "$MESSAGE"
fi
git -C "$MIRROR" push -q -u origin main
echo "published to https://github.com/$REPO"
