// Claude Bounce Bridge — bounces the *real* VS Code Dock icon.
//
// VS Code knows how to bounce its own icon (`app.dock.bounce()` lives in its main process),
// but only reaches that call from three internal places. The only one an extension can
// drive is task completion:
//
//   workbench.action.tasks.runTask command   (run source 1 = User, so it is not filtered,
//     │                                       unlike tasks.executeTask which is 5 = API)
//     ▼
//   _handleLongRunningTaskCompletion
//     • task.notifyWindowOnTaskCompletion = 0  → any duration qualifies
//     • window.document.hasFocus()             → VS Code checks window focus itself
//     ▼
//   hostService.focus(win, {mode: 1}) → showNotifyFocus() → app.dock.bounce() + setBadgeCount()
//
// The extension runs in every window's extension host, so each window only reacts to
// signals whose `cwd` belongs to its own workspace.

const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

const SUPPORT_DIR = path.join(os.homedir(), 'Library', 'Application Support', 'ClaudeBounce');
const TRIGGER_FILE = path.join(SUPPORT_DIR, 'trigger.json');
const LOG_FILE = path.join(SUPPORT_DIR, 'claude-bounce.log');
const DEFAULT_HELPER = path.join(
  os.homedir(), 'Applications', 'Claude Bounce.app', 'Contents', 'MacOS', 'ClaudeBounce');

const TASK_TYPE = 'claudeBounce';
const TASK_NAME = 'bounce';

let lastHandledId = '';
let repeatTimer = null;
let watcher = null;

function log(message) {
  const tag = (vscode.workspace.workspaceFolders || []).map((f) => f.name).join('+') || 'no-folder';
  try {
    fs.appendFileSync(LOG_FILE, `[${new Date().toISOString()}] ext(${tag}) ${message}\n`);
  } catch {
    // Logging must never break anything.
  }
}

function config() {
  return vscode.workspace.getConfiguration('claudeBounce');
}

function helperBinary() {
  return config().get('helperBinary') || DEFAULT_HELPER;
}

/// Tells the helper app either "I've got this one" or, with release, "never mind, go ahead".
function tellHelper(id, release) {
  return new Promise((resolve) => {
    const args = ['claim', '--id', id];
    if (release) args.push('--release');
    execFile(helperBinary(), args, { timeout: 2000 }, () => resolve());
  });
}

/// Does the signal's working directory belong to this window?
function ownsPath(target) {
  if (!target) return false;
  return (vscode.workspace.workspaceFolders || []).some((folder) => {
    const base = folder.uri.fsPath;
    return target === base || target.startsWith(base + path.sep);
  });
}

// MARK: - The throwaway task whose *completion* triggers the bounce

function makeTask() {
  const scope = (vscode.workspace.workspaceFolders || [])[0] || vscode.TaskScope.Workspace;
  const task = new vscode.Task(
    { type: TASK_TYPE, task: TASK_NAME },
    scope,
    TASK_NAME,
    TASK_TYPE,
    new vscode.ProcessExecution('/usr/bin/true'),
    []
  );
  // reveal:Never keeps the panel where it is; panel:Shared reuses a single terminal;
  // close:false matters most — the terminal has to outlive the task, otherwise VS Code
  // cannot find the instance in _handleLongRunningTaskCompletion and skips the notify.
  task.presentationOptions = {
    reveal: vscode.TaskRevealKind.Never,
    panel: vscode.TaskPanelKind.Shared,
    echo: false,
    focus: false,
    showReuseMessage: false,
    clear: false,
    close: false,
  };
  task.isBackground = false;
  return task;
}

/// We go through the *command* rather than vscode.tasks.executeTask(): the latter tags the
/// run with source 5 (API), which VS Code explicitly excludes from completion notifications.
async function runBounceTask() {
  await vscode.commands.executeCommand('workbench.action.tasks.runTask', {
    type: TASK_TYPE,
    task: TASK_NAME,
  });
}

function stopRepeating() {
  if (repeatTimer) {
    clearInterval(repeatTimer);
    repeatTimer = null;
  }
}

/// `dock.bounce("informational")` bounces once, so we re-trigger it until the window is
/// focused again. The Dock badge stays up on its own in the meantime.
async function startBouncing(reason) {
  const settings = config();
  const maxRepeats = settings.get('repeatCount', 8);
  const interval = settings.get('repeatIntervalMs', 3000);
  let count = 0;

  stopRepeating();

  const tick = async () => {
    if (vscode.window.state.focused || count >= maxRepeats) {
      stopRepeating();
      return;
    }
    count += 1;
    try {
      await runBounceTask();
    } catch (error) {
      log(`could not run the task: ${error && error.message}`);
      stopRepeating();
    }
  };

  log(`native bounce (${reason})`);
  await tick();
  repeatTimer = setInterval(tick, interval);
}

// MARK: - Signal handling

async function onTrigger() {
  let payload;
  try {
    payload = JSON.parse(fs.readFileSync(TRIGGER_FILE, 'utf8'));
  } catch {
    return;
  }
  if (!payload.id || payload.id === lastHandledId) return;
  if (!ownsPath(payload.cwd)) return;
  lastHandledId = payload.id;

  if (!config().get('enabled', true)) {
    log('signal ignored (disabled for this window)');
    return;
  }
  // In an untrusted workspace the runTask command raises a trust prompt, so hand the signal
  // back to the helper rather than trapping the user behind a dialog.
  if (!vscode.workspace.isTrusted) {
    log('workspace is not trusted, leaving it to the helper');
    return;
  }

  // Reserve the signal so the helper app does not bounce a second icon.
  await tellHelper(payload.id, false);

  if (vscode.window.state.focused) {
    log('window already focused, nothing to do');
    return;
  }

  try {
    await startBouncing(payload.kind || 'stop');
  } catch (error) {
    log(`failed, handing back to the helper: ${error && error.message}`);
    await tellHelper(payload.id, true);
  }
}

function activate(context) {
  try {
    fs.mkdirSync(SUPPORT_DIR, { recursive: true });
  } catch {
    // Nothing to do.
  }

  context.subscriptions.push(
    vscode.tasks.registerTaskProvider(TASK_TYPE, {
      provideTasks: () => [makeTask()],
      resolveTask: (task) => (task.definition.type === TASK_TYPE ? makeTask() : undefined),
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('claudeBounce.test', () => startBouncing('manual test'))
  );

  context.subscriptions.push(
    vscode.window.onDidChangeWindowState((state) => {
      if (state.focused) stopRepeating();
    })
  );

  // The hook writes trigger.json atomically (write + rename), so watch the directory
  // rather than the file — a file watcher would lose its target on rename.
  let debounce = null;
  watcher = fs.watch(SUPPORT_DIR, (_event, filename) => {
    if (filename !== 'trigger.json') return;
    clearTimeout(debounce);
    debounce = setTimeout(() => { onTrigger(); }, 30);
  });
  context.subscriptions.push({ dispose: () => watcher && watcher.close() });

  log('bridge active');
}

function deactivate() {
  stopRepeating();
  if (watcher) watcher.close();
}

module.exports = { activate, deactivate };
