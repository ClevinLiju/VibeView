#!/bin/bash
# Build MolScope in release mode and assemble an ad-hoc signed MolScope.app.
# Usage: scripts/make-app.sh [output-dir]   (default: ./dist)
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
SCRATCH="${MOLSCOPE_SCRATCH:-$ROOT/.build-app}"
VERSION="${MOLSCOPE_VERSION:-0.1.0}"
APP="$OUT/MolScope.app"

echo "==> Building release (scratch: $SCRATCH)"
swift build -c release --product MolScope --package-path "$ROOT" --scratch-path "$SCRATCH"
BIN="$(swift build -c release --product MolScope --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)/MolScope"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MolScope"
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
swift "$ROOT/scripts/make-icon.swift" "$TMP/MolScope.iconset" >/dev/null
iconutil -c icns "$TMP/MolScope.iconset" -o "$APP/Contents/Resources/MolScope.icns"

echo "==> Writing Info.plist"
doc() { # name uti role rank exts...
  local name="$1" uti="$2" role="$3"; shift 3
  printf '    <dict>\n      <key>CFBundleTypeName</key><string>%s</string>\n      <key>CFBundleTypeRole</key><string>%s</string>\n      <key>LSHandlerRank</key><string>Default</string>\n      <key>LSItemContentTypes</key><array><string>%s</string></array>\n    </dict>\n' "$name" "$role" "$uti"
}
uti() { # uti desc conforms exts...
  local id="$1" desc="$2" conf="$3"; shift 3
  printf '    <dict>\n      <key>UTTypeIdentifier</key><string>%s</string>\n      <key>UTTypeDescription</key><string>%s</string>\n      <key>UTTypeConformsTo</key><array><string>%s</string></array>\n      <key>UTTypeIconFile</key><string>MolScope</string>\n      <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array>' "$id" "$desc" "$conf"
  for e in "$@"; do printf '<string>%s</string>' "$e"; done
  printf '</array></dict>\n    </dict>\n'
}
# name | uti | role | conforms | extensions  (must match Sources/MolScopeApp/Core/MoleculeDocument.swift)
FORMATS=(
  "Gaussian Input|org.molscope.gaussian-input|Editor|public.plain-text|gjf com"
  "Calculation Output|org.molscope.gaussian-output|Viewer|public.plain-text|log out"
  "ORCA Input|org.molscope.orca-input|Viewer|public.plain-text|inp"
  "Molden File|org.molscope.molden|Viewer|public.plain-text|molden"
  "ORCA Hessian|org.molscope.orca-hessian|Viewer|public.plain-text|hess"
  "Formatted Checkpoint|org.molscope.fchk|Viewer|public.plain-text|fchk fch"
  "Cube File|org.molscope.cube|Viewer|public.plain-text|cube cub"
  "XYZ Coordinates|org.molscope.xyz|Editor|public.plain-text|xyz"
  "Protein Data Bank File|org.molscope.pdb|Editor|public.plain-text|pdb ent"
  "MDL Molfile|org.molscope.mol|Editor|public.plain-text|mol"
  "SD File|org.molscope.sdf|Editor|public.plain-text|sdf sd"
  "Chemical Markup Language|org.molscope.cml|Editor|public.xml|cml"
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
  <key>CFBundleName</key><string>MolScope</string>
  <key>CFBundleDisplayName</key><string>MolScope</string>
  <key>CFBundleIdentifier</key><string>org.molscope.MolScope</string>
  <key>CFBundleExecutable</key><string>MolScope</string>
  <key>CFBundleIconFile</key><string>MolScope</string>
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
  <key>NSHumanReadableCopyright</key><string>MolScope — open-source molecular builder and viewer.</string>
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
  sed -E '/^(@_exported )?import (MolCore|MolIO)$/d' "$f" > "$QLSRC/${d}_$(basename "$f")"
done
cp "$ROOT"/Extensions/QuickLook/*.swift "$QLSRC/"
APPEX="$APP/Contents/PlugIns/MolScopeQuickLook.appex"
mkdir -p "$APPEX/Contents/MacOS"
xcrun swiftc -O -parse-as-library -application-extension -module-name MolScopeQuickLook \
  -target arm64-apple-macos14.0 -swift-version 5 -framework QuickLookUI \
  -Xlinker -e -Xlinker _NSExtensionMain "$QLSRC"/*.swift -o "$APPEX/Contents/MacOS/MolScopeQuickLook"
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
