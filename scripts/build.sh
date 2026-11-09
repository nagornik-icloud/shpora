#!/bin/bash
# Build, sign (your Apple Development certificate or ad-hoc), install to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
xcodegen generate >/dev/null
xcodebuild -project Shpora.xcodeproj -scheme Shpora -configuration "$CONFIG" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
APP="build/Build/Products/$CONFIG/Shpora.app"
# Your own Apple Development certificate if you have one, otherwise an ad-hoc signature
# (fine for running on your own Mac).
IDENTITY="Apple Development"
security find-identity -v -p codesigning | grep -q "Apple Development" || IDENTITY="-"
codesign --force --deep --options runtime --timestamp=none \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
pkill -x Shpora || true
for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Shpora >/dev/null || break; sleep 0.3; done
rm -rf /Applications/Shpora.app
cp -R "$APP" /Applications/Shpora.app
echo "installed /Applications/Shpora.app ($CONFIG)"
