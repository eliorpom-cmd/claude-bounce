#!/bin/bash
# Wires an installed Claude Bounce.app into the system: launch agent, Claude Code hooks,
# and the companion VS Code extension.
#
# Usage: setup.sh [/path/to/Claude Bounce.app]
#
# Shared by install.sh (building from source) and Setup.command (installing from the DMG),
# and shipped inside the app bundle at Contents/Resources/setup.sh.
set -euo pipefail

BUNDLE_ID="com.byelior.claudebounce"
LEGACY_BUNDLE_ID="com.elior.claudebounce"
EXT_ID="byelior.claude-bounce-bridge-1.0.0"

APP="${1:-}"
if [ -z "$APP" ]; then
  for candidate in "/Applications/Claude Bounce.app" "$HOME/Applications/Claude Bounce.app"; do
    [ -d "$candidate" ] && APP="$candidate" && break
  done
fi
if [ ! -d "$APP" ]; then
  echo "error: could not find Claude Bounce.app. Pass its path as the first argument." >&2
  exit 1
fi

APP="$(cd "$APP" && pwd)"
BIN="$APP/Contents/MacOS/ClaudeBounce"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

# The extension lives inside the bundle for DMG installs, next to the repo otherwise.
EXT_SRC="$APP/Contents/Resources/vscode-extension"
if [ ! -d "$EXT_SRC" ]; then
  EXT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../vscode-extension" 2>/dev/null && pwd || true)"
fi

echo "==> Using $APP"

echo "==> Installing the launch agent"
for label in "$BUNDLE_ID" "$LEGACY_BUNDLE_ID"; do
  /bin/launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
done
rm -f "$HOME/Library/LaunchAgents/$LEGACY_BUNDLE_ID.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$BUNDLE_ID</string>
	<key>ProgramArguments</key>
	<array><string>$BIN</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><false/>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST_EOF
/bin/launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "==> Registering Claude Code hooks in $CLAUDE_SETTINGS"
mkdir -p "$HOME/.claude"
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"

BIN="$BIN" python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, os, sys

path = sys.argv[1]
binary = os.environ["BIN"]
with open(path) as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})
wanted = {"Stop": "stop", "Notification": "notification"}

for event, kind in wanted.items():
    command = f'"{binary}" hook --kind {kind}'
    matchers = hooks.setdefault(event, [])
    # Idempotent: drop any Claude Bounce entry that is already there.
    for matcher in matchers:
        matcher["hooks"] = [
            h for h in matcher.get("hooks", [])
            if "ClaudeBounce" not in h.get("command", "")
        ]
    matchers[:] = [m for m in matchers if m.get("hooks")]
    matchers.append({"hooks": [{"type": "command", "command": command, "timeout": 5}]})

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print("    Stop and Notification hooks registered")
PY

install_for_editor() {
  local ext_root="$1" settings_file="$2" label="$3"
  [ -d "$ext_root" ] || return 0
  [ -d "$EXT_SRC" ] || { echo "    (extension sources not found, skipping $label)"; return 0; }

  echo "==> Installing the $label extension"
  rm -rf "$ext_root/elior.claude-bounce-bridge-1.0.0"   # pre-rename layout
  mkdir -p "$ext_root/$EXT_ID"
  cp "$EXT_SRC/package.json" "$EXT_SRC/extension.js" "$ext_root/$EXT_ID/"

  if [ -f "$settings_file" ]; then
    cp "$settings_file" "$settings_file.bak.$(date +%Y%m%d%H%M%S)"
  else
    mkdir -p "$(dirname "$settings_file")"
    printf '{\n}\n' > "$settings_file"
  fi

  python3 - "$settings_file" <<'PY'
import sys

# VS Code settings are JSONC (comments, trailing commas), so a JSON round-trip would eat
# the user's comments. Insert the key textually instead, right after the opening brace.
path = sys.argv[1]
key = "task.notifyWindowOnTaskCompletion"
text = open(path).read()

if key in text:
    print(f"    {key} already set, leaving it alone")
    sys.exit(0)

brace = text.index("{")
addition = (
    '\n    // Claude Bounce: 0 means "notify the window when any task finishes, however\n'
    '    // short" (default 60000 ms). This is what lets the Dock icon bounce.\n'
    f'    "{key}": 0,'
)
open(path, "w").write(text[: brace + 1] + addition + text[brace + 1 :])
print(f"    {key} set to 0")
PY
}

install_for_editor "$HOME/.vscode/extensions" \
  "$HOME/Library/Application Support/Code/User/settings.json" "VS Code"
install_for_editor "$HOME/.vscode-insiders/extensions" \
  "$HOME/Library/Application Support/Code - Insiders/User/settings.json" "VS Code Insiders"

echo "==> Starting"
open -g "$APP" || true

cat <<'EOS'

Done.

  * A chevron icon now sits in your menu bar: enable/disable, pick which events bounce,
    toggle launch at login, and test the bounce from there.
  * For window-level detection, grant Accessibility access:
    menu -> "Grant Accessibility access...", then tick "Claude Bounce" under
    System Settings -> Privacy & Security -> Accessibility.
  * Reload your open VS Code windows ("Developer: Reload Window") so they pick up the
    extension and start bouncing the real editor icon.
  * Hooks only apply to Claude Code sessions started after this setup.

EOS
