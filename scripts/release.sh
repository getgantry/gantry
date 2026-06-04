#!/bin/bash
# Builds a distributable Gantry release:
#   - Release build of the app (universal)
#   - universal gantry-mcp embedded into Resources
#   - ad-hoc re-sign of the app seal (nested Sparkle signatures left intact)
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

# The appcast and release tag derive from the app's Info.plist; catch a
# forgotten MARKETING_VERSION bump before anything is published.
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    echo "version mismatch: app is $BUILT_VERSION, requested $VERSION."
    echo "Bump MARKETING_VERSION in Gantry.xcodeproj first."
    exit 1
fi

echo "==> Building gantry-mcp (release, universal)"
swift build -c release --package-path Packages/GantryMCP --arch arm64 --arch x86_64 | tail -1
MCP_BIN="Packages/GantryMCP/.build/apple/Products/Release/gantry-mcp"
[ -f "$MCP_BIN" ] || { echo "gantry-mcp not found at $MCP_BIN"; exit 1; }
lipo -archs "$MCP_BIN" | grep -q "x86_64 arm64\|arm64 x86_64" \
    || { echo "gantry-mcp is not universal: $(lipo -archs "$MCP_BIN")"; exit 1; }
cp "$MCP_BIN" "$APP/Contents/Resources/gantry-mcp"

echo "==> Re-signing bundle"
# Sign the embedded MCP binary, then re-seal the app itself. No --deep: it
# would clobber Sparkle's pre-signed framework / XPC services, which the
# updater validates at install time.
codesign --force --sign - "$APP/Contents/Resources/gantry-mcp"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP" || { echo "codesign verify failed"; exit 1; }

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
echo "    release: gh release create v$VERSION dist/Gantry-$VERSION.zip --title 'Gantry $VERSION'"
