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
# RELEASE_XCODEBUILD_FLAGS lets CI pass e.g. CODE_SIGNING_ALLOWED=NO; the app is
# re-signed ad-hoc below regardless.
xcodebuild -project Gantry.xcodeproj -scheme Gantry -configuration Release \
    -derivedDataPath "$BUILD" ${RELEASE_XCODEBUILD_FLAGS:-} build | tail -2

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

echo "==> Stamping CHANGELOG"
# Promote the running notes under "## [Unreleased]" into a dated version
# section, then re-open an empty Unreleased for the next cycle. Idempotent per
# version: re-running for the same version would duplicate the heading, so only
# run release.sh once per version.
#
# Under the normal release-please flow this is already done — the release PR
# carries the changelog entry — so the whole block is a no-op and only a
# hand-driven release reaches it.
CHANGELOG="$ROOT/CHANGELOG.md"
DATE="$(date +%F)"
# Matches both "## [0.21.0] - 2026-06-29" (stamped here) and release-please's
# "## [0.21.0](compare-link) (2026-06-29)".
if grep -qE "^## \[$VERSION\][ (]" "$CHANGELOG"; then
    echo "CHANGELOG.md already has a $VERSION section; skipping stamp."
elif ! grep -q '^## \[Unreleased\]$' "$CHANGELOG"; then
    echo "CHANGELOG.md has neither a $VERSION section nor '## [Unreleased]'; skipping stamp."
else
    # Warn (don't block) when releasing with no notes recorded.
    BODY="$(awk '/^## \[Unreleased\]$/{f=1;next} /^## \[/{f=0} f' "$CHANGELOG" \
        | grep -v '^[[:space:]]*$' || true)"
    [ -n "$BODY" ] || echo "    warning: [Unreleased] is empty — $VERSION will have no notes"

    awk -v ver="$VERSION" -v date="$DATE" '
        /^## \[Unreleased\]$/ && !h { print; print ""; print "## [" ver "] - " date; print ""; h=1; next }
        /^\[Unreleased\]:/ && !l {
            print "[Unreleased]: https://github.com/getgantry/gantry/compare/v" ver "...HEAD"
            print "[" ver "]: https://github.com/getgantry/gantry/releases/tag/v" ver
            l=1; next
        }
        { print }
    ' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"
    echo "    stamped $VERSION ($DATE)"
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
PREFIX="https://github.com/getgantry/gantry/releases/download/v$VERSION/"
# Locally the EdDSA key comes from the login Keychain; in CI, point
# SPARKLE_ED_KEY_FILE at an exported key file (see .github/workflows/release.yml).
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
    "$SPARKLE_BIN/generate_appcast" --ed-key-file "$SPARKLE_ED_KEY_FILE" \
        --download-url-prefix "$PREFIX" "$DIST"
else
    "$SPARKLE_BIN/generate_appcast" --download-url-prefix "$PREFIX" "$DIST"
fi
cp "$DIST/appcast.xml" "$ROOT/appcast.xml"

echo "==> Done"
echo "    app:     $APP"
echo "    zip:     $ZIP"
echo "    appcast:   $ROOT/appcast.xml (commit it to main)"
echo "    changelog: $ROOT/CHANGELOG.md (stamped $VERSION; commit it to main)"
echo "    release: gh release create v$VERSION dist/Gantry-$VERSION.zip --title 'Gantry $VERSION'"
