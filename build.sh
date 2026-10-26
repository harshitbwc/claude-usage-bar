#!/bin/bash
# Builds Claude Usage Bar into a standalone macOS .app bundle (no Xcode GUI needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="ClaudeUsageBar"
BUNDLE="build/$APP.app"
MACOS="$BUNDLE/Contents/MacOS"

echo "→ Compiling…"
rm -rf "$BUNDLE"
mkdir -p "$MACOS"

# Universal binary (Apple Silicon + Intel), macOS 13+.
TMP="build/.tmp"
rm -rf "$TMP"; mkdir -p "$TMP"
for ARCH in arm64 x86_64; do
  swiftc -O -target "$ARCH-apple-macos13.0" \
    -framework SwiftUI -framework AppKit -framework Foundation -framework ServiceManagement \
    -o "$TMP/$APP-$ARCH" \
    Sources/Usage.swift Sources/App.swift
done
lipo -create "$TMP/$APP-arm64" "$TMP/$APP-x86_64" -output "$MACOS/$APP"
rm -rf "$TMP"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Usage Bar</string>
  <key>CFBundleDisplayName</key><string>Claude Usage Bar</string>
  <key>CFBundleIdentifier</key><string>app.claudeusagebar</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS will run it locally.
codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true

echo "✓ Built $BUNDLE"
echo "  Run:  open \"$BUNDLE\""
