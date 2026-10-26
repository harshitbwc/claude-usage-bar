#!/bin/bash
# Builds the app and packages it as a drag-to-Applications disk image
# for a GitHub Release → dist/ClaudeUsageBar.dmg
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

mkdir -p dist
STAGE="$(mktemp -d)"
cp -R build/ClaudeUsageBar.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f dist/ClaudeUsageBar.dmg
hdiutil create -quiet -volname "Claude Usage Bar" -srcfolder "$STAGE" -ov -format UDZO dist/ClaudeUsageBar.dmg
rm -rf "$STAGE"
echo "✓ dist/ClaudeUsageBar.dmg"
shasum -a 256 dist/ClaudeUsageBar.dmg
