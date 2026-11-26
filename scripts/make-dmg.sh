#!/bin/bash
# Build dist/VibeView-<VERSION>.dmg (UDZO) containing VibeView.app and an Applications symlink.
# Usage: scripts/make-dmg.sh [--skip-build | --no-build]
#   --skip-build / --no-build  reuse an existing dist/VibeView.app instead of running make-app.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
SKIP=0
for a in "$@"; do
  case "$a" in
    --skip-build|--no-build) SKIP=1;;
    *) echo "unknown option: $a" >&2; exit 2;;
  esac
done
FILE_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
VERSION="${VIBEVIEW_VERSION:-${FILE_VERSION:-0.4.0}}"
APP="$DIST/VibeView.app"
DMG="$DIST/VibeView-$VERSION.dmg"

if [ "$SKIP" = 1 ]; then
  [ -d "$APP" ] || { echo "error: $APP not found; run scripts/make-app.sh first" >&2; exit 1; }
else
  "$ROOT/scripts/make-app.sh" "$DIST"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/VibeView"
cp -R "$APP" "$STAGE/VibeView/VibeView.app"
ln -s /Applications "$STAGE/VibeView/Applications"

rm -f "$DMG"
hdiutil create -volname "VibeView $VERSION" -srcfolder "$STAGE/VibeView" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
echo "$DMG"
