#!/bin/bash
# Builds Voicedic.app into build/ and signs it. Signing with a stable identity (your Apple
# Development certificate, picked automatically) keeps macOS privacy permissions across rebuilds.
# Override with CODESIGN_IDENTITY="..." or CODESIGN_IDENTITY=- for ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
APP="build/Voicedic.app"

swift build -c "$CONFIGURATION" --product Voicedic
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Voicedic" "$APP/Contents/MacOS/Voicedic"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
codesign --force --deep --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with: $IDENTITY)"
