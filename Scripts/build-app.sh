#!/bin/bash
# Builds .build/Stercorarius.app from the SwiftPM package and signs it: with a
# "Developer ID Application" identity when one is installed, ad-hoc otherwise.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly APP=".build/Stercorarius.app"
readonly SIGN_IDENTITY="${STERCORARIUS_SIGN_IDENTITY:-Developer ID Application}"

swift build -c release -Xswiftc -warnings-as-errors
BIN_DIR="$(swift build -c release --show-bin-path)"
readonly BIN_DIR

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ditto "$BIN_DIR/Stercorarius" "$APP/Contents/MacOS/Stercorarius"
ditto Support/Info.plist "$APP/Contents/Info.plist"
ditto "$BIN_DIR/Stercorarius_Stercorarius.bundle" \
  "$APP/Contents/Resources/Stercorarius_Stercorarius.bundle"

if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"
