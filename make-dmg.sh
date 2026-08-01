#!/bin/bash
# Builds a distributable disk image into dist/
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Claude Bounce"
VERSION="1.0.0"
DMG="dist/ClaudeBounce-$VERSION.dmg"

./build.sh

echo "==> Staging the disk image"
rm -rf dist/stage "$DMG"
mkdir -p dist/stage
cp -R "build/$APP_NAME.app" "dist/stage/"
ln -s /Applications "dist/stage/Applications"

cat > "dist/stage/Setup.command" <<'SETUP'
#!/bin/bash
# Double-click this after dragging Claude Bounce to Applications.
# It registers the Claude Code hooks, installs the VS Code extension, and starts the agent.
set -e
for candidate in "/Applications/Claude Bounce.app" "$HOME/Applications/Claude Bounce.app"; do
  [ -d "$candidate" ] && APP="$candidate" && break
done
if [ -z "${APP:-}" ]; then
  echo "Drag Claude Bounce.app into Applications first, then run this again."
  read -r -p "Press return to close."
  exit 1
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
"$APP/Contents/Resources/setup.sh" "$APP"
read -r -p "Press return to close."
SETUP
chmod +x "dist/stage/Setup.command"

cat > "dist/stage/README.txt" <<'READ'
Claude Bounce
=============

1. Drag "Claude Bounce.app" onto the Applications folder.

2. Run the setup, which registers the Claude Code hooks and installs the companion
   VS Code extension. Either double-click "Setup.command", or -- if macOS refuses to
   open it, since this build is not notarized -- paste this into Terminal:

       xattr -dr com.apple.quarantine "/Applications/Claude Bounce.app"
       "/Applications/Claude Bounce.app/Contents/Resources/setup.sh"

3. A chevron icon appears in your menu bar. Everything is configured from there.

4. Reload your open VS Code windows ("Developer: Reload Window") so they pick up the
   extension, and start a new Claude Code session so the hooks apply.

To remove everything later:

    "/Applications/Claude Bounce.app/Contents/Resources/uninstall.sh"

Source, documentation and issues: https://github.com/eliorpom-cmd/claude-bounce
GPL-3.0-or-later.
READ

echo "==> Creating $DMG"
mkdir -p dist
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder dist/stage \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf dist/stage
echo "==> Built $DMG ($(du -h "$DMG" | cut -f1))"
