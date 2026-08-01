#!/bin/bash
# Compiles Claude Bounce and assembles the .app bundle into build/
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Claude Bounce"
BUNDLE_ID="com.byelior.claudebounce"
APP="build/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling"
swiftc -swift-version 5 -O \
  -framework AppKit -framework ApplicationServices \
  -o "$APP/Contents/MacOS/ClaudeBounce" \
  Sources/main.swift

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
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
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
