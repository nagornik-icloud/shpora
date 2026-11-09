#!/bin/bash
# release.sh — universal (Apple silicon + Intel) Release build for download, ad-hoc signed,
# zipped. Ad-hoc on purpose: the personal Apple Development certificate carries the owner's
# e-mail and is not meant for distribution. Output: build/dist/Shpora-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Shpora.xcodeproj -scheme Shpora -configuration Release \
  -derivedDataPath build/universal ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build | grep -E 'error:|BUILD (SUCCEEDED|FAILED)'
APP="build/universal/Build/Products/Release/Shpora.app"
codesign --force --deep --options runtime --timestamp=none --sign - "$APP"
codesign --verify --strict "$APP"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p build/dist; rm -f "build/dist/Shpora-$VER.zip"
ditto -c -k --keepParent "$APP" "build/dist/Shpora-$VER.zip"
lipo -archs "$APP/Contents/MacOS/Shpora"
echo "build/dist/Shpora-$VER.zip"
