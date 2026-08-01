#!/bin/bash
# Compiles Claude Bounce and assembles the .app bundle into build/
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Claude Bounce"
BUNDLE_ID="com.byelior.claudebounce"
VERSION="1.0.0"
APP="build/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary so releases run on both Apple silicon and Intel.
echo "==> Compiling (arm64 + x86_64)"
mkdir -p build/obj
for arch in arm64 x86_64; do
  swiftc -swift-version 5 -O \
    -target "$arch-apple-macos13.0" \
    -framework AppKit -framework ApplicationServices \
    -o "build/obj/ClaudeBounce-$arch" \
    Sources/main.swift
done
lipo -create -output "$APP/Contents/MacOS/ClaudeBounce" \
  build/obj/ClaudeBounce-arm64 build/obj/ClaudeBounce-x86_64
rm -rf build/obj

# Ship the companion extension and the wiring scripts inside the bundle, so a DMG install
# is self-contained and does not need the repository.
echo "==> Embedding the VS Code extension and setup scripts"
mkdir -p "$APP/Contents/Resources/vscode-extension"
cp vscode-extension/package.json vscode-extension/extension.js \
   "$APP/Contents/Resources/vscode-extension/"
cp scripts/setup.sh uninstall.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/setup.sh" "$APP/Contents/Resources/uninstall.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>ClaudeBounce</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<!-- Starts with no Dock icon; the app flips to .regular only while bouncing. -->
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signing keeps the Accessibility grant stable across rebuilds; without it macOS
# revokes the permission every time the binary changes.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "==> Built $APP"
