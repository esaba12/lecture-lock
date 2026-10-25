import SwiftUI
import AppKit
import Carbon

/// Brings up the main window even if it was closed: reopening ourselves makes SwiftUI recreate it.
func showMainWindow() {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg)
}

/// ⌃⌥L from anywhere locks in with the saved settings. Carbon hot keys need no Accessibility permission.
private var hotKeyRef: EventHotKeyRef?

func registerHotKey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async {
            let engine = LockEngine.shared
            guard !engine.locked else { return }
            if !engine.lockFrontmost() {
                NSSound(named: "Basso")?.play()
                showMainWindow()
            }
        }
        return noErr
    }, 1, &spec, nil, nil)
    let id = EventHotKeyID(signature: OSType(0x4C4C4B21), id: 1)  // 'LLK!'
    RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        registerHotKey()
        DispatchQueue.main.async { LockEngine.shared.restore() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LockEngine.shared.locked ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }
}

/// The menu bar icon's menu.
struct MenuBarMenu: View {
    @ObservedObject var engine = LockEngine.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if engine.locked {
            Text("Locked to \(engine.target?.localizedName ?? "—")")
            if engine.lockedMode == .timer && engine.lockedPlan != .none {
                Text(engine.onBreak
                     ? "On break · back at \(engine.phaseEndsAt.formatted(date: .omitted, time: .shortened))"
                     : "Work · round \(engine.round) of \(engine.rounds)")
            }
            Text(engine.lockedMode == .course
                 ? "\(engine.coursesDone) of \(engine.courseRange.count) lessons done"
                 : engine.lockedMode == .timer || engine.lockedMode == .video || engine.lockedMode == .manual
                    ? "\(clock(engine.clockSeconds)) left"
                    : "Locked in for \(clock(engine.clockSeconds))")
            Divider()
            Button("Show Lecture Lock…") { show() }
        } else {
            Button("Lock In · \(engine.settingsSummary)") { lock() }
                .keyboardShortcut("l", modifiers: [.control, .option])
            Menu("Quick timer") {
                ForEach([30, 60, 90], id: \.self) { m in
                    Button("\(m) minutes") { lock(.timer, minutes: m) }
                }
            }
            Text("Locks to the app you're using now")
            Divider()
            if !engine.history.isEmpty {
                Text("Today: \(hoursMinutes(engine.todayMinutes).lowercased())"
                     + (engine.streak > 0 ? " · \(engine.streak)-day streak" : ""))
            }
            Button("Open Lecture Lock…") { show() }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    func lock(_ mode: LockMode? = nil, minutes: Int? = nil) {
        // If it can't lock (e.g. no video on the page), open the window so the reason is visible.
        if !engine.lockFrontmost(mode, minutes: minutes) { show() }
    }

    func show() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

// MARK: - Watchdog

/// `LectureLock --watchdog <pid>`: no window, no Dock icon. Reopens LectureLock while a lock is saved.
enum Watchdog {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.ethansaba.lecturelock"
    static let pidFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lecturelock-watchdog.pid")

    /// Read straight from cfprefsd each time, so the main app's writes show up.
    static func snapshot() -> LockSnapshot? {
        CFPreferencesAppSynchronize(bundleID as CFString)
        guard let data = CFPreferencesCopyAppValue(LockSnapshot.key as CFString, bundleID as CFString) as? Data else { return nil }
        return try? JSONDecoder().decode(LockSnapshot.self, from: data)
    }

    static var appURL: URL? {
        Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL
            : NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Whether `pid` is a live process running this executable.
    static func isUs(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        return String(cString: buf) == Bundle.main.executablePath
    }

    static func run() {
        let me = getpid()
        // Only one at a time.
        if let s = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(s), pid != me, isUs(pid) { return }
        try? String(me).write(to: pidFile, atomically: true, encoding: .utf8)
        defer {
            if (try? String(contentsOf: pidFile, encoding: .utf8)) == String(me) { try? FileManager.default.removeItem(at: pidFile) }
        }
        var lastLaunch = Date.distantPast
        while let s = snapshot(), !s.isOver {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains { $0.processIdentifier != me && !$0.isTerminated }
            // Give a relaunch time to come up before trying again.
            if !running, Date().timeIntervalSince(lastLaunch) > 10, let url = appURL {
                lastLaunch = Date()
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
    }
}

#if !TESTING
@main
#endif
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--watchdog") { Watchdog.run() } else { LectureLockApp.main() }
    }
}

struct LectureLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var engine = LockEngine.shared

    var body: some Scene {
        Window("Lecture Lock", id: "main") { ContentView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
        // SwiftUI writes this back on every update; skipping no-op writes stops a redraw loop that pins the CPU.
        MenuBarExtra(isInserted: Binding(get: { engine.menuBar }, set: { if engine.menuBar != $0 { engine.menuBar = $0 } })) {
            MenuBarMenu()
        } label: {
            // Just the countdown while locked: a full menu bar hides the widest items first.
            if engine.locked {
                Text(engine.menuText).monospacedDigit()
            } else {
                Image(systemName: "lock.open")
            }
        }
    }
}
