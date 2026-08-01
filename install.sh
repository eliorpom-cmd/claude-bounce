#!/bin/bash
# Builds Claude Bounce from source, installs it into ~/Applications, and wires it up.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Claude Bounce"
DEST="$HOME/Applications/$APP_NAME.app"

./build.sh

echo "==> Installing into ~/Applications"
mkdir -p "$HOME/Applications"
pkill -f "Contents/MacOS/ClaudeBounce" 2>/dev/null || true
rm -rf "$DEST"
cp -R "build/$APP_NAME.app" "$DEST"

exec scripts/setup.sh "$DEST"
