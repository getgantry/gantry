#!/bin/bash
# Builds a distributable Gantry release:
#   - Release build of the app
#   - gantry-mcp embedded into Resources
#   - ad-hoc deep re-sign, zip
#   - Sparkle appcast entry (EdDSA-signed; key in the login Keychain)
#
# Usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.1.0
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
BUILD="$ROOT/build"

cd "$ROOT"
rm -rf "$DIST" && mkdir -p "$DIST"

echo "==> Building Gantry.app (Release)"
xcodebuild -project Gantry.xcodeproj -scheme Gantry -configuration Release \
    -derivedDataPath "$BUILD" build | tail -2

APP="$BUILD/Build/Products/Release/Gantry.app"
[ -d "$APP" ] || { echo "app not found at $APP"; exit 1; }

echo "==> Building gantry-mcp (release)"
swift build -c release --package-path Packages/GantryMCP | tail -1
cp "Packages/GantryMCP/.build/release/gantry-mcp" "$APP/Contents/Resources/gantry-mcp"

echo "==> Re-signing bundle"
codesign --force --deep --sign - "$APP"

echo "==> Zipping"
ZIP="$DIST/Gantry-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Generating Sparkle appcast"
SPARKLE_BIN="$(ls -d "$BUILD"/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null \
    || ls -d ~/Library/Developer/Xcode/DerivedData/Gantry-*/SourcePackages/artifacts/sparkle/Sparkle/bin | head -1)"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/andrewkomkov/gantry/releases/download/v$VERSION/" \
    "$DIST"
cp "$DIST/appcast.xml" "$ROOT/appcast.xml"

echo "==> Done"
echo "    app:     $APP"
echo "    zip:     $ZIP"
echo "    appcast: $ROOT/appcast.xml (commit it to main)"
echo "    release: gh release create v$VERSION '$ZIP' --title 'Gantry $VERSION'"
