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

# The SHA-1 of the first matching identity: a name shared by two certificates is ambiguous.
IDENTITY="$(security find-identity -v -p codesigning |
  awk -v name="$SIGN_IDENTITY" 'index($0, name) { print $2; exit }')"
readonly IDENTITY
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-an ad-hoc signature})"
