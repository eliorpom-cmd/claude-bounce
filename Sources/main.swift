// Claude Bounce — bounce the Dock icon when Claude Code is done talking.
//
// One binary, three modes:
//   • no arguments           → the resident agent (menu bar item, listens, bounces)
//   • `hook --kind <event>`  → invoked by a Claude Code hook: reads the hook's JSON
//                              payload on stdin, signals the agent, exits immediately
//   • `claim --id <uuid>`    → invoked by the companion VS Code extension to say
//                              "I'll handle this one natively, stand down"
//
// Why a helper app at all: macOS exposes no API, public or private, that lets one process
// request user attention on behalf of another. `requestUserAttention(_:)` is an instance
// method on NSApplication — self only. So the helper bounces *its own* icon, wearing the
// target application's icon. When the companion extension is installed, VS Code bounces
// its real icon instead and the helper stays out of the way. See README.md.

import AppKit
import ApplicationServices
import Darwin
import Foundation

// MARK: - Constants

let bundleIdentifier = "com.byelior.claudebounce"
let notifyNotification = Notification.Name("\(bundleIdentifier).notify")
let claimNotification = Notification.Name("\(bundleIdentifier).claim")
let fallbackTargetPath = "/Applications/Visual Studio Code.app"
let fallbackTargetBundleID = "com.microsoft.VSCode"

func supportDirectory() -> URL {
    let directory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClaudeBounce", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

let configURL = supportDirectory().appendingPathComponent("config.json")
let logURL = supportDirectory().appendingPathComponent("claude-bounce.log")
let triggerURL = supportDirectory().appendingPathComponent("trigger.json")

let logDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func log(_ message: String) {
    let stamp = logDateFormatter.string(from: Date())
    guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: - Configuration

struct Config: Codable {
    var enabled = true
    /// Bounce when Claude finishes a turn (the `Stop` hook).
    var onStop = true
    /// Bounce when Claude asks for permission or waits for input (the `Notification` hook).
    var onNotification = true
    /// Bounce when a subagent finishes (the `SubagentStop` hook, not installed by default).
    var onSubagentStop = false
    /// Also compare the focused window against the session's project, not just the frontmost
    /// application. Requires Accessibility access; degrades to app-level checks without it.
    var windowLevelDetection = true
    /// Wear the target application's icon rather than a generic one.
    var useTargetIcon = true
    /// Overlay a Claude badge so the bouncing icon is distinguishable from the real app.
    var badgeIcon = true
    /// Give the companion VS Code extension a chance to bounce the *real* editor icon
    /// before falling back to this helper's icon.
    var preferNativeBounce = true
    /// How long to wait for the extension to claim a signal, in milliseconds.
    var claimGraceMs = 700

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: configURL)
    }
}

// MARK: - Hook mode

/// Walks up the process tree. The goal is to find the GUI application hosting this Claude
/// session, so the right app bounces. From the VS Code extension the chain looks like
/// hook → claude → Code Helper (Plugin) → Code. From a terminal it resolves to that
/// terminal instead, which is exactly what we want.
func ancestorPIDs() -> [Int32] {
    var parentOf = [Int32: Int32]()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-Ao", "pid=,ppid="]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return []
    }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, let pid = Int32(fields[0]), let parent = Int32(fields[1])
        else { continue }
        parentOf[pid] = parent
    }

    var chain = [Int32]()
    var current = getpid()
    while chain.count < 24 {
        guard let parent = parentOf[current], parent > 1 else { break }
        chain.append(parent)
        current = parent
    }
    return chain
}

func runHookMode(kind: String) {
    // Hooks receive their payload as JSON on stdin. This must never block Claude: on any
    // problem we simply exit 0 without doing anything.
    let data = FileHandle.standardInput.readDataToEndOfFile()
    var cwd = ProcessInfo.processInfo.environment["PWD"] ?? FileManager.default.currentDirectoryPath
    var sessionID = ""
    var message = ""

    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        cwd = (object["cwd"] as? String) ?? cwd
        sessionID = (object["session_id"] as? String) ?? ""
        message = (object["message"] as? String) ?? ""
    }

    let identifier = UUID().uuidString

    // 1. The helper app, as a safety net (terminals, no matching window, no extension).
    //    Notified first so it has registered the signal by the time the extension claims
    //    it. The helper also tolerates a claim arriving early, so this is belt and braces.
    let userInfo: [String: String] = [
        "id": identifier,
        "kind": kind,
        "cwd": cwd,
        "session": sessionID,
        "message": message,
        "pids": ancestorPIDs().map(String.init).joined(separator: ","),
    ]
    DistributedNotificationCenter.default().postNotificationName(
        notifyNotification, object: nil, userInfo: userInfo, deliverImmediately: true)

    // 2. The trigger file, watched by the VS Code extension (real editor icon bounce).
    //    Written atomically; the extension watches the directory and reads on rename.
    let payload: [String: String] = [
        "id": identifier, "kind": kind, "cwd": cwd, "session": sessionID, "message": message,
    ]
    if let encoded = try? JSONSerialization.data(withJSONObject: payload) {
        try? encoded.write(to: triggerURL, options: .atomic)
    }
    exit(0)
}

/// Called by the VS Code extension. `--release` means "I could not handle it, go ahead".
func runClaimMode(id: String, release: Bool) {
    DistributedNotificationCenter.default().postNotificationName(
        claimNotification, object: nil,
        userInfo: ["id": id, "release": release ? "1" : "0"],
        deliverImmediately: true)
    exit(0)
}

// MARK: - Accessibility (window-level detection)

func focusedWindowTitle(pid: Int32) -> String? {
    let application = AXUIElementCreateApplication(pid)
    var windowRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        application, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
        let window = windowRef
    else { return nil }

    var titleRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        window as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success
    else { return nil }
    return titleRef as? String
}

/// Raises the window whose title matches the project, if we can find it.
func raiseWindow(pid: Int32, matching needle: String) {
    guard AXIsProcessTrusted(), !needle.isEmpty else { return }
    let application = AXUIElementCreateApplication(pid)
    var windowsRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        application, kAXWindowsAttribute as CFString, &windowsRef) == .success,
        let windows = windowsRef as? [AXUIElement]
    else { return }

    for window in windows {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef) == .success,
            let title = titleRef as? String,
            title.localizedCaseInsensitiveContains(needle)
        else { continue }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return
    }
}

// MARK: - Dock icon

/// The target application's icon, with a small Claude badge so it stays distinguishable
/// from the real thing once both sit side by side in the Dock.
func dockIcon(for application: NSRunningApplication?, config: Config) -> NSImage {
    let base: NSImage
    if config.useTargetIcon, let icon = application?.icon {
        base = icon
    } else if config.useTargetIcon, FileManager.default.fileExists(atPath: fallbackTargetPath) {
        base = NSWorkspace.shared.icon(forFile: fallbackTargetPath)
    } else {
        base = NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    guard config.badgeIcon else { return base }

    let side: CGFloat = 512
    let composed = NSImage(size: NSSize(width: side, height: side))
    composed.lockFocus()
    base.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
              from: .zero, operation: .copy, fraction: 1.0)

    let radius: CGFloat = side * 0.30
    let center = NSPoint(x: side - radius - side * 0.03, y: radius + side * 0.03)
    let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                             width: radius * 2, height: radius * 2))
    NSColor(calibratedRed: 0.85, green: 0.42, blue: 0.24, alpha: 1.0).setFill()
    circle.fill()
    NSColor(calibratedWhite: 1.0, alpha: 0.9).setStroke()
    circle.lineWidth = side * 0.015
    circle.stroke()

    let glyph = "✻" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: radius * 1.7, weight: .medium),
        .foregroundColor: NSColor.white,
    ]
    let size = glyph.size(withAttributes: attributes)
    glyph.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
               withAttributes: attributes)

    composed.unlockFocus()
    return composed
}

// MARK: - Agent

struct PendingBounce {
    let kind: String
    let cwd: String
    let message: String
    let targetPID: Int32?
    let date: Date

    var projectName: String {
        cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private var statusItem: NSStatusItem!
    private var pending: [PendingBounce] = []
    private var attentionRequest: Int = 0
    private var bouncing = false
    /// Signals waiting to see whether the VS Code extension claims them.
    private var graceWork: [String: DispatchWorkItem] = [:]
    private var gracePayload: [String: (PendingBounce, NSRunningApplication?)] = [:]
    /// Claims that arrived before the matching signal did. The extension watches the trigger
    /// file, so it can beat the distributed notification to us.
    private var earlyClaims: [String: Date] = [:]

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleSignal(_:)), name: notifyNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleClaim(_:)), name: claimNotification, object: nil)

        // If the target app comes back to the front on its own (cmd-tab, clicking its Dock
        // icon), stop bouncing: the message got through.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        log("agent started (enabled=\(config.enabled))")
    }

    // MARK: Incoming signals

    @objc private func handleSignal(_ note: Notification) {
        guard let info = note.userInfo as? [String: String] else { return }
        let kind = info["kind"] ?? "stop"
        let cwd = info["cwd"] ?? ""
        let pids = (info["pids"] ?? "").split(separator: ",").compactMap { Int32($0) }

        guard config.enabled else { log("\(kind) ignored (disabled)"); return }
        guard wants(kind: kind) else { log("\(kind) ignored (event turned off)"); return }

        let target = resolveTargetApplication(from: pids)
        let item = PendingBounce(kind: kind, cwd: cwd, message: info["message"] ?? "",
                                 targetPID: target?.processIdentifier, date: Date())

        guard shouldBounce(target: target, cwd: cwd) else {
            log("\(kind) [\(item.projectName)] ignored: already in the foreground")
            return
        }

        scheduleOrFire(item, target: target, identifier: info["id"] ?? UUID().uuidString)
    }

    /// The VS Code extension may bounce the real icon instead. Give it a moment to claim the
    /// signal before we put the helper's stand-in icon in the Dock.
    private func scheduleOrFire(_ item: PendingBounce, target: NSRunningApplication?,
                                identifier: String) {
        guard config.preferNativeBounce else {
            fire(item, target: target)
            return
        }

        if earlyClaims.removeValue(forKey: identifier) != nil {
            log("already claimed by VS Code: bouncing the real icon natively")
            return
        }

        gracePayload[identifier] = (item, target)
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  let payload = self.gracePayload.removeValue(forKey: identifier) else { return }
            self.graceWork[identifier] = nil
            self.fire(payload.0, target: payload.1)
        }
        graceWork[identifier] = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(config.claimGraceMs), execute: work)
    }

    private func fire(_ item: PendingBounce, target: NSRunningApplication?) {
        pending.append(item)
        startBouncing(target: target)
        log("helper bounce: \(item.kind) [\(item.projectName)] target=\(target?.localizedName ?? "?")")
    }

    /// The VS Code extension announces that it is taking over (or handing back).
    @objc private func handleClaim(_ note: Notification) {
        guard let info = note.userInfo as? [String: String],
              let identifier = info["id"] else { return }
        guard let work = graceWork.removeValue(forKey: identifier) else {
            // The claim beat the signal. Remember it so we skip the bounce when the signal
            // shows up, and drop entries old enough that no signal is coming.
            if info["release"] != "1" {
                earlyClaims = earlyClaims.filter { Date().timeIntervalSince($0.value) < 30 }
                earlyClaims[identifier] = Date()
                log("claim arrived before its signal, noted")
            }
            return
        }
        work.cancel()
        guard let payload = gracePayload.removeValue(forKey: identifier) else { return }

        if info["release"] == "1" {
            log("claim released by VS Code, helper taking over")
            fire(payload.0, target: payload.1)
        } else {
            log("claimed by VS Code: bouncing the real icon natively")
        }
    }

    private func wants(kind: String) -> Bool {
        switch kind {
        case "stop": return config.onStop
        case "notification": return config.onNotification
        case "subagent": return config.onSubagentStop
        default: return true
        }
    }

    /// First GUI application found walking up from the hook process. Falls back to VS Code.
    private func resolveTargetApplication(from pids: [Int32]) -> NSRunningApplication? {
        for pid in pids {
            guard let application = NSRunningApplication(processIdentifier: pid) else { continue }
            if application.activationPolicy == .regular { return application }
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == fallbackTargetBundleID
        }
    }

    // MARK: Decision

    private func shouldBounce(target: NSRunningApplication?, cwd: String) -> Bool {
        guard let target else { return true }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return true }

        // Target application is not in front → bounce.
        if frontmost.processIdentifier != target.processIdentifier { return true }

        // It is in front. Without window-level detection we assume the user has seen it.
        guard config.windowLevelDetection, AXIsProcessTrusted() else { return false }

        let project = URL(fileURLWithPath: cwd).lastPathComponent
        guard !project.isEmpty,
              let title = focusedWindowTitle(pid: target.processIdentifier)
        else { return false }

        // Focused window belongs to another project → the user will not see this response.
        return !title.localizedCaseInsensitiveContains(project)
    }

    // MARK: Bouncing

    private func startBouncing(target: NSRunningApplication?) {
        NSApp.applicationIconImage = dockIcon(for: target, config: config)

        if !bouncing {
            NSApp.setActivationPolicy(.regular)
            // .criticalRequest bounces continuously until the app is activated, unlike
            // .informationalRequest which bounces exactly once.
            attentionRequest = NSApp.requestUserAttention(.criticalRequest)
            bouncing = true
        }

        NSApp.dockTile.badgeLabel = pending.count > 1 ? "\(pending.count)" : nil
        NSApp.dockTile.display()
        updateStatusIcon()
        rebuildMenu()
    }

    private func stopBouncing() {
        guard bouncing else { return }
        NSApp.cancelUserAttentionRequest(attentionRequest)
        NSApp.dockTile.badgeLabel = nil
        NSApp.dockTile.display()
        bouncing = false
        pending.removeAll()
        updateStatusIcon()
        rebuildMenu()
        // Let the focus change settle before removing the Dock icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !self.bouncing { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// Clicking the bouncing icon takes you to the right window of the target application.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard bouncing, let item = pending.last else { return }
        let target = item.targetPID.flatMap { NSRunningApplication(processIdentifier: $0) }
        stopBouncing()
        guard let target else { return }
        raiseWindow(pid: target.processIdentifier, matching: item.projectName)
        target.activate(options: [])
        log("activated \(target.localizedName ?? "?") [\(item.projectName)]")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        false
    }

    @objc private func applicationActivated(_ note: Notification) {
        guard bouncing,
              let application = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }
        if pending.contains(where: { $0.targetPID == application.processIdentifier }) {
            log("target came back to the front, stopping")
            stopBouncing()
        }
    }

    // MARK: Menu bar

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let symbol = NSImage.SymbolConfiguration(
            pointSize: 14, weight: bouncing ? .bold : .regular)
        let image = NSImage(systemSymbolName: "chevron.up.2", accessibilityDescription: "Claude Bounce")
            ?? NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Claude Bounce")
        button.image = image?.withSymbolConfiguration(symbol)
        button.image?.isTemplate = true
        button.contentTintColor = bouncing ? .controlAccentColor : nil
        button.title = pending.count > 1 ? " \(pending.count)" : ""
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let headerTitle: String
        if bouncing {
            headerTitle = "\(pending.count) session\(pending.count > 1 ? "s" : "") waiting"
        } else {
            headerTitle = config.enabled ? "Idle" : "Disabled"
        }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for item in pending.suffix(5) {
            let label = "   \(item.projectName) — "
                + (item.kind == "notification" ? "needs permission" : "finished")
            let entry = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        menu.addItem(.separator())

        menu.addItem(toggle("Enabled", #selector(toggleEnabled), config.enabled))
        menu.addItem(.separator())

        menu.addItem(toggle("Bounce when Claude finishes", #selector(toggleOnStop), config.onStop))
        menu.addItem(toggle("Bounce when Claude needs permission",
                            #selector(toggleOnNotification), config.onNotification))
        menu.addItem(toggle("Bounce when a subagent finishes",
                            #selector(toggleOnSubagentStop), config.onSubagentStop))
        menu.addItem(.separator())

        menu.addItem(toggle("Prefer VS Code's own icon", #selector(togglePreferNative),
                            config.preferNativeBounce))
        menu.addItem(toggle("Window-level detection", #selector(toggleWindowLevel),
                            config.windowLevelDetection))
        if config.windowLevelDetection && !AXIsProcessTrusted() {
            let warning = NSMenuItem(title: "   ⚠︎ Grant Accessibility access…",
                                     action: #selector(requestAccessibility), keyEquivalent: "")
            warning.target = self
            menu.addItem(warning)
        }
        menu.addItem(.separator())

        menu.addItem(toggle("Launch at login", #selector(toggleLaunchAtLogin),
                            launchAgentInstalled()))
        menu.addItem(item("Test bounce", #selector(testBounce)))
        menu.addItem(item("Open log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Claude Bounce", #selector(quit)))

        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    private func toggle(_ title: String, _ action: Selector, _ on: Bool) -> NSMenuItem {
        let menuItem = item(title, action)
        menuItem.state = on ? .on : .off
        return menuItem
    }

    // MARK: Menu actions

    @objc private func toggleEnabled() { config.enabled.toggle(); persist() }
    @objc private func toggleOnStop() { config.onStop.toggle(); persist() }
    @objc private func toggleOnNotification() { config.onNotification.toggle(); persist() }
    @objc private func toggleOnSubagentStop() { config.onSubagentStop.toggle(); persist() }
    @objc private func togglePreferNative() { config.preferNativeBounce.toggle(); persist() }

    @objc private func toggleWindowLevel() {
        config.windowLevelDetection.toggle()
        if config.windowLevelDetection && !AXIsProcessTrusted() { requestAccessibility() }
        persist()
    }

    private func persist() {
        config.save()
        rebuildMenu()
    }

    @objc private func requestAccessibility() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Goes through the whole pipeline, exactly like a real hook, so what you see is what
    /// you get: VS Code bounces its own icon if a window claims the signal, and only
    /// otherwise does the stand-in icon appear. The "*" working directory means "any
    /// window may claim this one", since a test belongs to no particular project.
    @objc private func testBounce() {
        let identifier = UUID().uuidString
        let payload: [String: String] = [
            "id": identifier, "kind": "test", "cwd": "*", "session": "", "message": "test",
        ]
        if let encoded = try? JSONSerialization.data(withJSONObject: payload) {
            try? encoded.write(to: triggerURL, options: .atomic)
        }

        let target = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == fallbackTargetBundleID
        }
        let item = PendingBounce(kind: "test", cwd: "", message: "test",
                                 targetPID: target?.processIdentifier, date: Date())
        scheduleOrFire(item, target: target, identifier: identifier)
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: logURL.path) { log("—") }
        NSWorkspace.shared.open(logURL)
    }

    @objc private func quit() {
        stopBouncing()
        NSApp.terminate(nil)
    }

    // MARK: Launch agent

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(bundleIdentifier).plist")
    }

    private func launchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @objc private func toggleLaunchAtLogin() {
        if launchAgentInstalled() {
            runLaunchctl(["bootout", "gui/\(getuid())/\(bundleIdentifier)"])
            try? FileManager.default.removeItem(at: launchAgentURL)
        } else {
            let binary = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": bundleIdentifier,
                "ProgramArguments": [binary],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
            ]
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0) {
                try? FileManager.default.createDirectory(
                    at: launchAgentURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try? data.write(to: launchAgentURL)
                runLaunchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
            }
        }
        rebuildMenu()
    }

    private func runLaunchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "hook" {
    var kind = "stop"
    if let index = arguments.firstIndex(of: "--kind"), index + 1 < arguments.count {
        kind = arguments[index + 1]
    }
    runHookMode(kind: kind)
}

if arguments.first == "claim" {
    var identifier = ""
    if let index = arguments.firstIndex(of: "--id"), index + 1 < arguments.count {
        identifier = arguments[index + 1]
    }
    runClaimMode(id: identifier, release: arguments.contains("--release"))
}

// Only one agent at a time.
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
    .filter { $0.processIdentifier != getpid() }
if !others.isEmpty {
    log("another instance is already running, exiting")
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
