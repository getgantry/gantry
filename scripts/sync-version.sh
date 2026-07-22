#!/bin/bash
# Propagates the version release-please owns (version.txt) into the Xcode
# project, which is what the built app, the release tag check and the Sparkle
# appcast all read.
#
#   MARKETING_VERSION      <- version.txt
#   CURRENT_PROJECT_VERSION <- previous build number + 1 (once per version)
#
# Run by .github/workflows/release-please.yml against the release PR branch, so
# the version bump is visible in the PR rather than applied behind the release.
# Safe to run by hand: it is a no-op when the project already matches.
#
# Usage: scripts/sync-version.sh [version]   (defaults to version.txt)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Gantry.xcodeproj/project.pbxproj"

VERSION="${1:-$(tr -d '[:space:]' < "$ROOT/version.txt")}"
[ -n "$VERSION" ] || { echo "no version given and version.txt is empty"; exit 1; }
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "version '$VERSION' is not x.y.z"; exit 1 ;;
esac

CURRENT="$(grep -m1 'MARKETING_VERSION' "$PROJECT" | sed -E 's/.*= (.*);/\1/')"
BUILD="$(grep -m1 'CURRENT_PROJECT_VERSION' "$PROJECT" | sed -E 's/.*= (.*);/\1/')"

if [ "$CURRENT" = "$VERSION" ]; then
    echo "project already at $VERSION (build $BUILD); nothing to do"
    exit 0
fi

NEXT_BUILD=$((BUILD + 1))

# Both Debug and Release build configurations carry the pair, so replace all.
# Written through a temp file rather than `sed -i`, whose in-place syntax
# differs between BSD sed (macOS, where this is run by hand) and GNU sed (the
# Linux runner the release workflow uses).
sed -E \
    -e "s/(MARKETING_VERSION = ).*;/\1$VERSION;/" \
    -e "s/(CURRENT_PROJECT_VERSION = ).*;/\1$NEXT_BUILD;/" \
    "$PROJECT" > "$PROJECT.tmp"
mv "$PROJECT.tmp" "$PROJECT"

echo "bumped $CURRENT (build $BUILD) -> $VERSION (build $NEXT_BUILD)"
