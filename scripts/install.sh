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
#   --with-xtb         download xtb without asking when it is not already installed
#   --no-xtb           don't check for or offer xtb
#   --uninstall        remove VibeView.app, its preferences and the xtb it installed
set -euo pipefail

REPO="ClevinLiju/VibeView"
APP="VibeView.app"
BUNDLE_ID="io.github.clevinliju.VibeView"
VERSION=""
DEST=""
FROM_SOURCE=0
OPEN_APP=1
UNINSTALL=0
XTB_MODE="ask"          # ask | yes | no
MANAGED="$HOME/Library/Application Support/VibeView"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version)     VERSION="${2:?--version needs a tag, e.g. v0.3.0}"; shift 2 ;;
        --dir)         DEST="${2:?--dir needs a path}"; shift 2 ;;
        --from-source) FROM_SOURCE=1; shift ;;
        --no-open)     OPEN_APP=0; shift ;;
        --with-xtb)    XTB_MODE="yes"; shift ;;
        --no-xtb)      XTB_MODE="no"; shift ;;
        --uninstall)   UNINSTALL=1; shift ;;
        -h|--help)     sed -n '2,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    if [ -d "$MANAGED/xtb" ]; then say "Removing the xtb VibeView installed ($MANAGED/xtb)"; rm -rf "$MANAGED/xtb"; fi
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

# ---- xtb -------------------------------------------------------------------------------------------
# Same places the app searches (MolCompute ProgramLocator): PATH, conda-style environments, Homebrew,
# and the copy this script manages.
find_xtb() {
    local p
    if p="$(command -v xtb 2>/dev/null)" && [ -x "$p" ]; then echo "$p"; return 0; fi
    for root in miniconda3 miniforge3 anaconda3 mambaforge micromamba; do
        for p in "$HOME/$root/bin/xtb" "$HOME/$root"/envs/*/bin/xtb; do
            [ -x "$p" ] && { echo "$p"; return 0; }
        done
    done
    for p in /opt/homebrew/bin/xtb /usr/local/bin/xtb "$MANAGED/xtb/bin/xtb"; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

xtb_version() {
    local bin="$1" share
    share="$(cd "$(dirname "$bin")/.." && pwd)/share/xtb"
    if [ -f "$share/param_gfn2-xtb.txt" ]; then XTBPATH="$share" "$bin" --version 2>/dev/null; else "$bin" --version 2>/dev/null; fi \
        | grep -o 'xtb version [0-9.]*' | head -n 1
}

# Asks on the terminal even when this script arrives through `curl | bash` (stdin is the script then).
confirm() {
    local reply
    if { : < /dev/tty > /dev/tty; } 2>/dev/null; then
        printf '%s [Y/n] ' "$1" > /dev/tty
        read -r reply < /dev/tty || reply="n"
        case "$reply" in ""|y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
    fi
    return 1   # no terminal to ask on: treat as "no"
}

install_xtb() {
    local arch asset json url sumurl tmp want got
    case "$(uname -m)" in arm64) arch="arm64" ;; x86_64) arch="x86_64" ;; *) fail "no xtb build for $(uname -m)" ;; esac
    say "Finding the latest xtb release (github.com/grimme-lab/xtb)"
    json="$(curl -fsSL -H 'Accept: application/vnd.github+json' https://api.github.com/repos/grimme-lab/xtb/releases/latest)" \
        || { echo "  could not reach GitHub; skipping xtb" >&2; return 1; }
    url="$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*macos-'"$arch"'-openblas\.tar\.xz"' | head -n 1 | sed 's/.*"\(https[^"]*\)"/\1/')"
    [ -n "$url" ] || { echo "  the latest xtb release has no macOS $arch build; skipping" >&2; return 1; }
    tmp="$WORK/xtb"; mkdir -p "$tmp"
    say "Downloading $(basename "$url")"
    curl -fL --progress-bar -o "$tmp/xtb.tar.xz" "$url" || { echo "  download failed; skipping xtb" >&2; return 1; }
    if curl -fsSL -o "$tmp/xtb.sha256" "$url.sha256"; then
        want="$(awk '{print $1}' "$tmp/xtb.sha256" | head -n 1)"
        got="$(shasum -a 256 "$tmp/xtb.tar.xz" | awk '{print $1}')"
        [ "$want" = "$got" ] || { echo "  checksum mismatch (expected $want, got $got); not installing xtb" >&2; return 1; }
        say "Checksum verified"
    else
        echo "  no checksum published for this build; not installing xtb" >&2; return 1
    fi
    mkdir -p "$tmp/x" && tar -xJf "$tmp/xtb.tar.xz" -C "$tmp/x"
    local stage; stage="$(dirname "$(dirname "$(find "$tmp/x" -path '*/bin/xtb' -type f | head -n 1)")")"
    [ -x "$stage/bin/xtb" ] || { echo "  unexpected archive layout; not installing xtb" >&2; return 1; }
    rm -rf "$MANAGED/xtb"; mkdir -p "$MANAGED/xtb"
    ditto "$stage/bin" "$MANAGED/xtb/bin"
    ditto "$stage/share" "$MANAGED/xtb/share"
    xattr -dr com.apple.quarantine "$MANAGED/xtb" 2>/dev/null || true
    local v; v="$(xtb_version "$MANAGED/xtb/bin/xtb")"
    [ -n "$v" ] || { echo "  the downloaded xtb does not run; removing it" >&2; rm -rf "$MANAGED/xtb"; return 1; }
    say "Installed $v to $MANAGED/xtb (VibeView finds it automatically)"
}

ensure_xtb() {
    [ "$XTB_MODE" = "no" ] && return 0
    local found
    if found="$(find_xtb)"; then
        say "xtb found: $found ($(xtb_version "$found"))"
        return 0
    fi
    echo "xtb (GFN-xTB) is not installed. VibeView uses it for fast geometry optimizations."
    if [ "$XTB_MODE" = "yes" ] || confirm "Download the official xtb build from github.com/grimme-lab/xtb (about 13 MB, LGPL-3.0)?"; then
        install_xtb || echo "  VibeView works without xtb; install it later with: conda install -c conda-forge xtb"
    else
        echo "  Skipped. VibeView works without it; to add it later rerun this script or: conda install -c conda-forge xtb"
    fi
}

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
ensure_xtb
if [ "$OPEN_APP" = 1 ]; then open "$TARGET"; fi
