#!/bin/bash
# Build StayAwake and install to /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="StayAwake.app"
BUILD_APP="$ROOT/build/Build/Products/Release/$APP_NAME"
INSTALL_APP="/Applications/$APP_NAME"

ICONSET="$ROOT/StayAwake/Assets.xcassets/AppIcon.appiconset"
ICNS_TMP="$(mktemp -t stayawake-appicon.XXXXXX).icns"

echo "Generating app icon PNGs..."
"$ROOT/scripts/generate-app-icon.swift" "$ICONSET"

echo "Building complete AppIcon.icns..."
ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
mkdir "$ICONSET_TMP"
cp "$ICONSET"/icon_*.png "$ICONSET_TMP/"
iconutil -c icns "$ICONSET_TMP" -o "$ICNS_TMP"
rm -rf "$(dirname "$ICONSET_TMP")"
icns_size=$(stat -f%z "$ICNS_TMP")
if [[ ! -s "$ICNS_TMP" || "$icns_size" -lt 50000 ]]; then
  echo "error: AppIcon.icns looks incomplete (${icns_size} bytes)" >&2
  rm -f "$ICNS_TMP"
  exit 1
fi

echo "Building StayAwake..."
xcodebuild -scheme StayAwake -configuration Release -derivedDataPath "$ROOT/build" -project "$ROOT/StayAwake.xcodeproj" >/dev/null

echo "Replacing incomplete Xcode AppIcon.icns..."
cp "$ICNS_TMP" "$BUILD_APP/Contents/Resources/AppIcon.icns"
rm -f "$ICNS_TMP"

echo "Quitting any running copy..."
killall StayAwake 2>/dev/null || true
sleep 1

echo "Installing to $INSTALL_APP..."
cp -R "$BUILD_APP" /Applications/

echo "Refreshing Launch Services icon cache..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_APP"
touch "$INSTALL_APP"

echo "Launching..."
open "$INSTALL_APP"

echo "Done. If Start at Login is enabled, toggle it off and on once in the popover"
echo "so macOS registers the /Applications path."
