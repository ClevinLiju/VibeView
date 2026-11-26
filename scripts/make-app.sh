#!/bin/bash
# Build VibeView in release mode and assemble an ad-hoc signed VibeView.app.
# Usage: scripts/make-app.sh [output-dir]   (default: ./dist)
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
SCRATCH="${VIBEVIEW_SCRATCH:-${MOLSCOPE_SCRATCH:-$ROOT/.build-app}}"
FILE_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)"
VERSION="${VIBEVIEW_VERSION:-${MOLSCOPE_VERSION:-${FILE_VERSION:-0.3.0}}}"
APP="$OUT/VibeView.app"

echo "==> Building release (scratch: $SCRATCH)"
swift build -c release --product VibeView --package-path "$ROOT" --scratch-path "$SCRATCH"
BIN="$(swift build -c release --product VibeView --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)/VibeView"

echo "==> Assembling $APP"
# remove stale pre-rename artifacts
rm -rf "$OUT/MolScope.app" "$OUT"/MolScope*.dmg
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VibeView"
# SwiftPM resource bundles (if any target ships resources)
BINDIR="$(dirname "$BIN")"
for b in "$BINDIR"/*.bundle; do
  [ -e "$b" ] || continue
  case "$(basename "$b")" in *MolChecks*) continue;; esac
  cp -R "$b" "$APP/Contents/Resources/"
done

echo "==> Generating icon"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Rendered by the app itself (MolRender, two waters forming a "W"); the drawn fallback needs no GPU/window server.
if ! "$BIN" --render-icon "$TMP/VibeView.iconset" >/dev/null 2>&1 || [ ! -f "$TMP/VibeView.iconset/icon_512x512@2x.png" ]; then
  echo "    (renderer icon unavailable, using scripts/make-icon.swift)"
  rm -rf "$TMP/VibeView.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$TMP/VibeView.iconset" >/dev/null
fi
iconutil -c icns "$TMP/VibeView.iconset" -o "$APP/Contents/Resources/VibeView.icns"

echo "==> Writing Info.plist"
doc() { # name uti role rank exts...
  local name="$1" uti="$2" role="$3"; shift 3
  printf '    <dict>\n      <key>CFBundleTypeName</key><string>%s</string>\n      <key>CFBundleTypeRole</key><string>%s</string>\n      <key>LSHandlerRank</key><string>Default</string>\n      <key>LSItemContentTypes</key><array><string>%s</string></array>\n    </dict>\n' "$name" "$role" "$uti"
}
uti() { # uti desc conforms exts...
  local id="$1" desc="$2" conf="$3"; shift 3
  printf '    <dict>\n      <key>UTTypeIdentifier</key><string>%s</string>\n      <key>UTTypeDescription</key><string>%s</string>\n      <key>UTTypeConformsTo</key><array><string>%s</string></array>\n      <key>UTTypeIconFile</key><string>VibeView</string>\n      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array>' "$id" "$desc" "$conf"
  for e in "$@"; do printf '<string>%s</string>' "$e"; done
  printf '</array></dict>\n    </dict>\n'
}
# name | uti | role | conforms | extensions  (must match Sources/MolScopeApp/Core/MoleculeDocument.swift)
FORMATS=(
  "Gaussian Input|io.github.clevinliju.vibeview.gaussian-input|Editor|public.plain-text|gjf com"
  "Calculation Output|io.github.clevinliju.vibeview.gaussian-output|Viewer|public.plain-text|log out"
  "ORCA Input|io.github.clevinliju.vibeview.orca-input|Viewer|public.plain-text|inp"
  "Molden File|io.github.clevinliju.vibeview.molden|Viewer|public.plain-text|molden"
  "ORCA Hessian|io.github.clevinliju.vibeview.orca-hessian|Viewer|public.plain-text|hess"
  "Formatted Checkpoint|io.github.clevinliju.vibeview.fchk|Viewer|public.plain-text|fchk fch"
  "Cube File|io.github.clevinliju.vibeview.cube|Viewer|public.plain-text|cube cub"
  "XYZ Coordinates|io.github.clevinliju.vibeview.xyz|Editor|public.plain-text|xyz"
  "Protein Data Bank File|io.github.clevinliju.vibeview.pdb|Editor|public.plain-text|pdb ent"
  "MDL Molfile|io.github.clevinliju.vibeview.mol|Editor|public.plain-text|mol"
  "SD File|io.github.clevinliju.vibeview.sdf|Editor|public.plain-text|sdf sd"
  "Chemical Markup Language|io.github.clevinliju.vibeview.cml|Editor|public.xml|cml"
)
DOCS=""; UTIS=""
SESSION_ID="io.github.clevinliju.vibeview.session"
for f in "${FORMATS[@]}"; do
  IFS='|' read -r name id role conf exts <<<"$f"
  DOCS+="$(doc "$name" "$id" "$role")"$'\n'
  # shellcheck disable=SC2086
  UTIS+="$(uti "$id" "$name" "$conf" $exts)"$'\n'
done
DOCS+="$(doc "VibeView Session" "$SESSION_ID" "Editor")"$'\n'
UTIS+="$(uti "$SESSION_ID" "VibeView Session" "public.json" vibeview)"$'\n'
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VibeView</string>
  <key>CFBundleDisplayName</key><string>VibeView</string>
  <key>CFBundleIdentifier</key><string>io.github.clevinliju.VibeView</string>
  <key>CFBundleExecutable</key><string>VibeView</string>
  <key>CFBundleIconFile</key><string>VibeView</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>VibeView — open-source molecular builder and viewer. MIT License.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
$DOCS    <dict>
      <key>CFBundleTypeName</key><string>Structure or Calculation File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.plain-text</string><string>com.apple.log</string><string>public.xml</string><string>public.data</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
$UTIS  </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

echo "==> Building Quick Look preview extension"
QLSRC="$TMP/qlsrc"; mkdir -p "$QLSRC"
for f in "$ROOT"/Sources/MolCore/*.swift "$ROOT"/Sources/MolIO/*.swift; do
  d="$(basename "$(dirname "$f")")"
  # MolSIMD only re-exports `simd` on Darwin, so the single-module extension build imports simd directly.
  sed -E -e '/^(@_exported )?import (MolCore|MolIO)$/d' -e 's/^import MolSIMD$/import simd/' "$f" > "$QLSRC/${d}_$(basename "$f")"
done
cp "$ROOT"/Extensions/QuickLook/*.swift "$QLSRC/"
APPEX="$APP/Contents/PlugIns/VibeViewQuickLook.appex"
mkdir -p "$APPEX/Contents/MacOS"
xcrun swiftc -O -parse-as-library -application-extension -module-name VibeViewQuickLook \
  -target arm64-apple-macos14.0 -swift-version 5 -framework QuickLookUI \
  -Xlinker -e -Xlinker _NSExtensionMain "$QLSRC"/*.swift -o "$APPEX/Contents/MacOS/VibeViewQuickLook"
QLUTIS=""
for f in "${FORMATS[@]}"; do IFS='|' read -r _ id _ _ _ <<<"$f"; QLUTIS+="        <string>$id</string>"$'\n'; done
python3 - "$ROOT/Extensions/QuickLook/Info.plist" "$APPEX/Contents/Info.plist" "$VERSION" "$QLUTIS" <<'PY'
import sys
src, dst, ver, utis = sys.argv[1:5]
s = open(src).read().replace("__VERSION__", ver).replace("__UTIS__", utis.rstrip("\n"))
open(dst, "w").write(s)
PY
plutil -lint "$APPEX/Contents/Info.plist"

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none --entitlements "$ROOT/Extensions/QuickLook/QuickLook.entitlements" "$APPEX"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"
echo "==> Done: $APP"
