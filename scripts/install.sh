#!/bin/bash
# VibeView installer.
#
#   curl -fsSL https://raw.githubusercontent.com/ClevinLiju/VibeView/main/scripts/install.sh | bash
#
# Downloads the latest release DMG from GitHub, copies VibeView.app into /Applications
# (or ~/Applications when /Applications is not writable), clears the download quarantine
# flag so the ad-hoc-signed app opens without the Gatekeeper prompt, and launches it.
#
# Options (pass after `bash -s --` when piping, e.g. `... | bash -s -- --version v0.3.0`):
#   --version vX.Y.Z   install a specific release instead of the latest
#   --dir PATH         install into PATH instead of /Applications
#   --from-source      clone the repo and build locally (needs Xcode)
#   --no-open          don't launch the app afterwards
#   --uninstall        remove VibeView.app and its preferences
set -euo pipefail

REPO="ClevinLiju/VibeView"
APP="VibeView.app"
BUNDLE_ID="io.github.clevinliju.VibeView"
VERSION=""
DEST=""
FROM_SOURCE=0
OPEN_APP=1
UNINSTALL=0

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version)     VERSION="${2:?--version needs a tag, e.g. v0.3.0}"; shift 2 ;;
        --dir)         DEST="${2:?--dir needs a path}"; shift 2 ;;
        --from-source) FROM_SOURCE=1; shift ;;
        --no-open)     OPEN_APP=0; shift ;;
        --uninstall)   UNINSTALL=1; shift ;;
        -h|--help)     sed -n '2,17p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             fail "unknown option: $1" ;;
    esac
done

[ "$(uname -s)" = "Darwin" ] || fail "VibeView is a macOS app."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || fail "VibeView needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

if [ -z "$DEST" ]; then
    if [ -w /Applications ]; then DEST="/Applications"; else DEST="$HOME/Applications"; fi
fi
mkdir -p "$DEST"
TARGET="$DEST/$APP"

if [ "$UNINSTALL" = 1 ]; then
    for p in "/Applications/$APP" "$HOME/Applications/$APP"; do
        if [ -d "$p" ]; then say "Removing $p"; rm -rf "$p"; fi
    done
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
    say "VibeView uninstalled."
    exit 0
fi

WORK="$(mktemp -d -t vibeview-install)"
MOUNT=""
cleanup() {
    if [ -n "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

if [ "$FROM_SOURCE" = 1 ]; then
    command -v git >/dev/null || fail "git is required for --from-source."
    dev="$(xcode-select -p 2>/dev/null || true)"
    case "$dev" in
        *Xcode*.app*) ;;
        *) [ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
               || fail "--from-source needs Xcode (the Command Line Tools alone lack SwiftUI's macros)." ;;
    esac
    say "Cloning $REPO"
    git clone --depth 1 ${VERSION:+--branch "$VERSION"} "https://github.com/$REPO.git" "$WORK/src" >/dev/null 2>&1 \
        || fail "could not clone https://github.com/$REPO"
    say "Building (release, takes a few minutes)"
    (cd "$WORK/src" && scripts/make-app.sh) || fail "build failed; see the output above."
    SRC_APP="$WORK/src/dist/$APP"
else
    if [ -n "$VERSION" ]; then API="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
    else API="https://api.github.com/repos/$REPO/releases/latest"; fi
    say "Finding ${VERSION:-the latest} release"
    json="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API")" \
        || fail "no release found at $API (try --from-source)."
    url="$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -n 1 | sed 's/.*"\(https[^"]*\)"/\1/')"
    [ -n "$url" ] || fail "the release has no .dmg attached (try --from-source)."
    tag="$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"

    say "Downloading VibeView $tag"
    curl -fL --progress-bar -o "$WORK/VibeView.dmg" "$url" || fail "download failed."

    say "Mounting disk image"
    MOUNT="$(hdiutil attach "$WORK/VibeView.dmg" -nobrowse -readonly -noautoopen | grep -o '/Volumes/.*' | tail -n 1)"
    [ -n "$MOUNT" ] && [ -d "$MOUNT/$APP" ] || fail "the disk image does not contain $APP."
    SRC_APP="$MOUNT/$APP"
fi

if [ "$(uname -m)" != "arm64" ] && ! lipo -archs "$SRC_APP/Contents/MacOS/VibeView" 2>/dev/null | grep -q x86_64; then
    fail "this build is for Apple Silicon; on an Intel Mac use --from-source."
fi

if pgrep -xq VibeView; then
    say "Quitting the running VibeView"
    osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' >/dev/null 2>&1 || true
    sleep 1
fi

say "Installing to $TARGET"
rm -rf "$TARGET"
ditto "$SRC_APP" "$TARGET"
# The app is ad-hoc signed (not notarized): clear the quarantine flag so it opens normally.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
# Register the app and its Quick Look extension with Launch Services.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" >/dev/null 2>&1 || true

say "VibeView installed: $TARGET"
if [ "$OPEN_APP" = 1 ]; then open "$TARGET"; fi
