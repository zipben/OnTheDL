#!/bin/bash
# Builds dist/On The DL.app (release, ad-hoc signed). No Apple Developer account needed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="dist/On The DL.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/OnTheDL" "$APP/Contents/MacOS/OnTheDL"
cp Resources/PressStart2P-Regular.ttf Resources/OFL-PressStart2P.txt "$APP/Contents/Resources/"

ICONSET="$(mktemp -d)/AppIcon.iconset"
"$APP/Contents/MacOS/OnTheDL" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force -s - "$APP"
echo "Built $APP"
