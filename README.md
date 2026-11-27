# Claude Bounce

Bounce your editor's Dock icon when Claude Code or OpenAI's Codex finishes a turn (or Claude
Code asks for permission), so you can go do something else while it works instead of
checking back every thirty seconds.

macOS only. Works with Claude Code and Codex, in their VS Code extensions and in any
terminal. See [Codex](#codex) for what differs there.

It bounces **only** when you are not already looking at the session: not when the editor is
frontmost, and not when the focused window is already the project that just finished.

## Install

### From the disk image

With [Homebrew](https://brew.sh):

```bash
brew install --cask eliorpom-cmd/tap/claude-bounce
"/Applications/Claude Bounce.app/Contents/Resources/setup.sh"
```

Or download `ClaudeBounce-1.0.2.dmg` from the
[latest release](https://github.com/eliorpom-cmd/claude-bounce/releases/latest), open it,
and drag **Claude Bounce** onto Applications. Then run the setup, which registers the Claude
Code hooks and the Codex notify program, and installs the companion VS Code extension:

```bash
"/Applications/Claude Bounce.app/Contents/Resources/setup.sh"
```

The disk image also ships a double-clickable `Setup.command` that does the same thing.

### From source

Needs Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/eliorpom-cmd/claude-bounce.git
cd claude-bounce
./install.sh
```

### Either way, two last steps

1. Reload any open VS Code window (`Developer: Reload Window`) so it picks up the extension.
2. Start a new Claude Code or Codex session — hooks only apply to sessions started after
   setup.

Then check it works: click the menu bar chevron → **Test bounce**.

To remove everything: `./uninstall.sh` from the repo, or
`"/Applications/Claude Bounce.app/Contents/Resources/uninstall.sh"` for a disk image install.

## Codex

Setup also wires up [Codex](https://github.com/openai/codex), in the terminal and in the
Codex extension for VS Code, when `~/.codex` exists (otherwise it skips this silently). It
adds one line at the top level of `~/.codex/config.toml`, after a timestamped backup:

```toml
notify = ["/Applications/Claude Bounce.app/Contents/MacOS/ClaudeBounce", "hook", "--kind", "stop", "--source", "codex"]
```

Codex runs that program when a turn finishes, with the event as a JSON argument; Claude
Bounce takes the project folder (`cwd`) and the session (`thread-id`) from it and then
behaves exactly as with Claude Code: same app detection, same native VS Code bounce, same
fallback helper. Running setup again keeps a single line.

What works, and what doesn't:

- **Turn finished**: bounces, governed by **Bounce when the agent finishes** in the menu.
- **Approval requests**: no bounce. Codex's `notify` program only receives
  `agent-turn-complete` events, so Codex bounces only when a turn ends.
- **`codex exec`** (non-interactive runs, scripts): never bounces, like `claude -p`.

**If you already have a `notify` program**, Codex only takes one, so setup leaves yours
untouched and prints "Codex already has a notify program. Claude Bounce did not replace it:
see README, Codex." To use Claude Bounce instead, replace your `notify` line with the one
above and run setup again. To keep both, point `notify` at a small script of your own that
calls each program with the JSON argument it received.

**To turn it off**, delete the `notify = [...ClaudeBounce...]` line from
`~/.codex/config.toml`, or run `uninstall.sh`, which removes that line and only that line.

---

## The interesting part: making the *real* VS Code icon bounce

macOS exposes no API, public or private, that lets one process request user attention on
behalf of another. `requestUserAttention(_:)` is an instance method on `NSApplication` —
self only, and its own documentation says "call this method only if your application is not
already active". `NSRunningApplication` only offers `activate…`, which steals focus.

VS Code, being Electron, *can* bounce its own icon. `app.dock.bounce()` is right there in
its main process, in `showNotifyFocus()`, alongside `app.setBadgeCount()` for the persistent
Dock badge. But the workbench only reaches it from three places:

| Trigger | Setting | Reachable from outside? |
|---|---|---|
| Chat response received | `chat.notifyWindowOnResponseReceived` | No — needs VS Code's native chat |
| Chat confirmation pending | `chat.notifyWindowOnConfirmation` | No — same |
| Task finished | `task.notifyWindowOnTaskCompletion` | **Yes** |

No command exposes it either: `workbench.action.focusWindow` uses focus mode 2, which steals
focus rather than notifying. And the Claude Code extension does not use VS Code's native chat
API — it ships its own webviews — so the first two never fire for it.

That leaves task completion, which has one catch. VS Code deliberately skips the
notification when the task was started through the extension API:

```js
if (i === -1 || (i > 0 && t < i) || this._taskRunSources.get(e.taskId) === 5) return;
//                                                                        ^ TaskRunSource.API
```

So `vscode.tasks.executeTask()` is a dead end. But running the same task through the
**command** goes down a different path — `_runTaskCommand` calls `this.run(task, …, 1)`,
where `1` is `TaskRunSource.User`. Not filtered.

The companion extension therefore registers a task provider whose task runs `/usr/bin/true`,
and fires it with `workbench.action.tasks.runTask`. With `task.notifyWindowOnTaskCompletion`
set to `0`, any completion qualifies:

```
extension (in the window's extension host)
  └─ executeCommand('workbench.action.tasks.runTask', {type:'claudeBounce', task:'bounce'})
       └─ _handleLongRunningTaskCompletion
            • window.document.hasFocus() → bail out if you are already looking at it
            └─ hostService.focus(win, {mode: 1})
                 └─ showNotifyFocus()
                      ├─ app.setBadgeCount()   ← persistent Dock badge
                      └─ app.dock.bounce()     ← the real VS Code icon
```

Two useful side effects of going through VS Code's own machinery: the window-focus check is
done by VS Code, per window, with no Accessibility permission needed; and the badge stays on
the icon until you actually come back.

One limitation: VS Code passes `"informational"`, which bounces exactly once. The extension
re-fires the task on an interval (default every 3s, up to 8 times) until the window regains
focus, which reads as a continuous bounce.

## Architecture

```
Claude Code hook (Stop / Notification)        Codex notify (turn finished)
  └─ ClaudeBounce hook --kind stop              └─ ClaudeBounce hook --kind stop --source codex
       reads the hook JSON on stdin (cwd, session_id, message)  — or, from Codex, the JSON
       in its last argument (cwd, thread-id)
       walks up the process tree to find the host GUI app
       writes trigger.json  ─────────────┐  and posts a distributed notification ─┐
       exits immediately, never blocks   │                                        │
                                         ▼                                        ▼
                          VS Code extension (per window)              helper agent (resident)
                          claims the signal, bounces                  waits ~700ms for a claim;
                          the real icon natively                      if none comes, bounces its
                                                                      own icon wearing the target's
```

**Finding the right app.** Rather than hardcoding VS Code, the hook walks `pid → ppid` until
it hits a process that is a GUI application. From the VS Code extension the chain is
`hook → claude → Code Helper (Plugin) → Code`. Run Claude Code in Terminal or iTerm and that
app bounces instead. Codex works the same way: its VS Code extension runs `codex` under the
editor, so the walk finds VS Code, and in a terminal it finds the terminal.

**The fallback helper.** When no VS Code window claims a signal — Claude running in a
terminal, an untrusted workspace, the extension not installed — a small agent bounces *its
own* Dock icon, wearing the target app's icon with a small badge, using
`requestUserAttention(.criticalRequest)`. Unlike VS Code's single informational bounce, that
one bounces continuously until you click it. Clicking it raises the matching project window
and gets out of the way.

**Avoiding a double bounce.** The extension calls `ClaudeBounce claim --id <uuid>` as soon as
it decides to handle a signal; the helper cancels its pending bounce. If the extension then
fails, it calls `claim --id <uuid> --release` and the helper takes over.

## Settings

Menu bar icon:

| Setting | Default |
|---|---|
| Enabled | on |
| Bounce when the agent finishes (Claude Code `Stop`, Codex `notify`) | on |
| Bounce when Claude needs permission (`Notification`) | on |
| Bounce when a subagent finishes (`SubagentStop`) | off — hook not installed |
| Prefer VS Code's own icon | on |
| Window-level detection | on — needs Accessibility access |
| Launch at login | on |

Stored in `~/Library/Application Support/ClaudeBounce/config.json`.
Log: `~/Library/Application Support/ClaudeBounce/claude-bounce.log`.

Per-window VS Code settings live under `claudeBounce.*` (`enabled`, `repeatCount`,
`repeatIntervalMs`).

Window-level detection is only used by the fallback helper, and it is the one feature that
needs Accessibility access: it compares the focused window's title to the session's project
folder. Without the permission it degrades to an application-level check. The native VS Code
path never needs it.

## What gets installed

- `~/Applications/Claude Bounce.app`
- `~/Library/LaunchAgents/com.byelior.claudebounce.plist`
- `~/.claude/settings.json` → `Stop` and `Notification` hooks
- `~/.codex/config.toml` → a top-level `notify` line, when Codex is installed and has no
  other `notify` program
- `~/.vscode/extensions/byelior.claude-bounce-bridge-1.0.0/`
- `task.notifyWindowOnTaskCompletion: 0` in your VS Code user settings

Timestamped backups are written before any settings file is touched. `./uninstall.sh`
reverses all of it except the VS Code setting, which is stock VS Code and yours to keep.

## Notes and caveats

- Hooks only apply to Claude Code (and Codex) sessions started **after** installation.
- Already-open VS Code windows may need `Developer: Reload Window` before the extension
  starts bouncing the real icon.
- Releases are signed with a Developer ID and notarized by Apple (since 1.0.1), so they open
  without a warning. A local `./build.sh` signs ad-hoc (`codesign --sign -`), which keeps the
  Accessibility grant stable across rebuilds. Updating from 1.0.0 changes the signature:
  macOS may ask for the Accessibility permission again.
- Release binaries are universal (arm64 + x86_64), macOS 13 and later.
- Running a task requires a trusted workspace. In an untrusted one the extension steps aside
  and the fallback helper bounces instead.
- The task leaves one hidden, reused terminal per window (`reveal: never`, `panel: shared`).
  It has to stay alive: VS Code looks the terminal instance up when the task ends, and skips
  the notification if it is gone.
- Verified against VS Code 1.10x. The task-completion path is internal behaviour, not public
  API, so a future release could change it. If it does, turn off "Prefer VS Code's own icon"
  and the helper takes over.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
