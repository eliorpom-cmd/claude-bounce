#!/bin/bash
# Removes Claude Bounce: launch agent, helper app, Claude Code hooks, Codex notify program,
# VS Code extension.
# Leaves your config and log behind in ~/Library/Application Support/ClaudeBounce.
set -euo pipefail

APP_NAME="Claude Bounce"
BUNDLE_ID="com.byelior.claudebounce"
LEGACY_BUNDLE_ID="com.elior.claudebounce"
DEST="$HOME/Applications/$APP_NAME.app"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

echo "==> Stopping the agent"
for label in "$BUNDLE_ID" "$LEGACY_BUNDLE_ID"; do
  /bin/launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
pkill -f "Contents/MacOS/ClaudeBounce" 2>/dev/null || true

echo "==> Removing the app"
rm -rf "$DEST"

echo "==> Removing the VS Code extension"
for root in "$HOME/.vscode/extensions" "$HOME/.vscode-insiders/extensions"; do
  [ -d "$root" ] || continue
  rm -rf "$root"/byelior.claude-bounce-bridge-* "$root"/elior.claude-bounce-bridge-*
done

if [ -f "$CLAUDE_SETTINGS" ]; then
  echo "==> Removing the Claude Code hooks"
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
for event, matchers in list(hooks.items()):
    for matcher in matchers:
        matcher["hooks"] = [
            h for h in matcher.get("hooks", [])
            if "ClaudeBounce" not in h.get("command", "")
        ]
    hooks[event] = [m for m in matchers if m.get("hooks")]
    if not hooks[event]:
        del hooks[event]
if not hooks:
    settings.pop("hooks", None)

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PY
fi

CODEX_CONFIG="$HOME/.codex/config.toml"
if [ -f "$CODEX_CONFIG" ] && grep -q "ClaudeBounce" "$CODEX_CONFIG"; then
  echo "==> Removing the Codex notify program"
  cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  python3 - "$CODEX_CONFIG" <<'PY'
import re, sys

# Only the top-level `notify = [... ClaudeBounce ...]` line written by setup.sh; every other
# line, including another program's notify, stays as it is.
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

header = re.compile(r"^\s*\[\[?\s*[A-Za-z0-9_.\"' -]+\]\]?\s*(#.*)?$")
notify = re.compile(r"^\s*notify\s*=")
end = next((i for i, text in enumerate(lines) if header.match(text)), len(lines))
lines = [
    text for i, text in enumerate(lines)
    if not (i < end and notify.match(text) and "ClaudeBounce" in text)
]

with open(path, "w") as f:
    f.writelines(lines)
PY
fi

cat <<'EOS'

Removed.

  Left untouched on purpose:
    * "task.notifyWindowOnTaskCompletion" in your VS Code settings -- it is a stock VS Code
      setting and you may want to keep it. Delete the line to restore the 60s default.
    * ~/Library/Application Support/ClaudeBounce (config and log).

EOS
