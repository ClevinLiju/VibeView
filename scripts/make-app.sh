#!/bin/bash
# Build VibeView in release mode and assemble an ad-hoc signed VibeView.app.
# Usage: scripts/make-app.sh [output-dir]   (default: ./dist)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
SCRATCH="${VIBEVIEW_SCRATCH:-$ROOT/.build-app}"
VERSION="${VIBEVIEW_VERSION:-0.1.0}"
APP="$OUT/VibeView.app"

echo "==> Building release (scratch: $SCRATCH)"
swift build -c release --product VibeView --package-path "$ROOT" --scratch-path "$SCRATCH"
BIN="$(swift build -c release --product VibeView --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)/VibeView"

echo "==> Assembling $APP"
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
swift "$ROOT/scripts/make-icon.swift" "$TMP/VibeView.iconset" >/dev/null
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
# name | uti | role | conforms | extensions  (must match Sources/VibeViewApp/Core/MoleculeDocument.swift)
FORMATS=(
  "Gaussian Input|org.vibeview.gaussian-input|Editor|public.plain-text|gjf com"
  "Gaussian Output|org.vibeview.gaussian-output|Viewer|public.plain-text|log out"
  "Formatted Checkpoint|org.vibeview.fchk|Viewer|public.plain-text|fchk fch"
  "Cube File|org.vibeview.cube|Viewer|public.plain-text|cube cub"
  "XYZ Coordinates|org.vibeview.xyz|Editor|public.plain-text|xyz"
  "Protein Data Bank File|org.vibeview.pdb|Editor|public.plain-text|pdb ent"
  "MDL Molfile|org.vibeview.mol|Editor|public.plain-text|mol"
  "SD File|org.vibeview.sdf|Editor|public.plain-text|sdf sd"
  "Chemical Markup Language|org.vibeview.cml|Editor|public.xml|cml"
)
DOCS=""; UTIS=""
for f in "${FORMATS[@]}"; do
  IFS='|' read -r name id role conf exts <<<"$f"
  DOCS+="$(doc "$name" "$id" "$role")"$'\n'
  # shellcheck disable=SC2086
  UTIS+="$(uti "$id" "$name" "$conf" $exts)"$'\n'
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VibeView</string>
  <key>CFBundleDisplayName</key><string>VibeView</string>
  <key>CFBundleIdentifier</key><string>org.vibeview.VibeView</string>
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
  <key>NSHumanReadableCopyright</key><string>VibeView — open-source molecular builder and viewer.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
$DOCS  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
$UTIS  </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"
echo "==> Done: $APP"
