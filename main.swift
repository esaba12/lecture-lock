import SwiftUI
import AppKit

// MARK: - Browser control (AppleScript)

enum BrowserKind {
    case chromium(String)   // AppleScript app name
    case safari

    static func of(_ app: NSRunningApplication) -> BrowserKind? {
        switch app.bundleIdentifier {
        case "com.google.Chrome": return .chromium("Google Chrome")
        case "com.brave.Browser": return .chromium("Brave Browser")
        case "com.microsoft.edgemac": return .chromium("Microsoft Edge")
        case "company.thebrowser.Browser": return .chromium("Arc")
        case "com.apple.Safari": return .safari
        default: return nil
        }
    }
}

@discardableResult
func runScript(_ source: String) -> NSAppleEventDescriptor? {
    var err: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
    return err == nil ? result : nil
}

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

func currentTab(_ kind: BrowserKind) -> (url: String, title: String)? {
    let src: String
    switch kind {
    case .chromium(let name):
        src = "tell application \"\(name)\" to return {URL of active tab of front window, title of active tab of front window}"
    case .safari:
        src = "tell application \"Safari\" to return {URL of current tab of front window, name of current tab of front window}"
    }
    guard let d = runScript(src), d.numberOfItems == 2,
          let url = d.atIndex(1)?.stringValue else { return nil }
    return (url, d.atIndex(2)?.stringValue ?? url)
}

/// The part of the URL that must stay present: the video id on YouTube, otherwise host + path.
func anchor(for urlString: String) -> String {
    guard let c = URLComponents(string: urlString), let host = c.host else { return urlString }
    if host.hasSuffix("youtube.com"), let v = c.queryItems?.first(where: { $0.name == "v" })?.value { return "v=\(v)" }
    if host == "youtu.be" { return "v=" + c.path.dropFirst() }
    return host + c.path
}

/// Make sure the lecture tab is the one in front; reopen it if it's gone.
func enforceTab(_ kind: BrowserKind, url: String, anchor: String) {
    let u = esc(url), a = esc(anchor)
    let src: String
    switch kind {
    case .chromium(let name):
        src = """
        tell application "\(name)"
          if (count of windows) is 0 then
            make new window
            set URL of active tab of window 1 to "\(u)"
            return
          end if
          set cur to ""
          try
            set cur to URL of active tab of window 1
          end try
          if cur contains "\(a)" then return
          repeat with w in windows
            set i to 0
            repeat with t in tabs of w
              set i to i + 1
              set tu to ""
              try
                set tu to URL of t
              end try
              if tu contains "\(a)" then
                set active tab index of w to i
                set index of w to 1
                return
              end if
            end repeat
          end repeat
          tell window 1 to make new tab with properties {URL:"\(u)"}
        end tell
        """
    case .safari:
        src = """
        tell application "Safari"
          if (count of windows) is 0 then
            make new document with properties {URL:"\(u)"}
            return
          end if
          set cur to ""
          try
            set cur to URL of current tab of front window
          end try
          if cur contains "\(a)" then return
          repeat with w in windows
            repeat with t in tabs of w
              set tu to ""
              try
                set tu to URL of t
              end try
              if tu contains "\(a)" then
                set current tab of w to t
                set index of w to 1
                return
              end if
            end repeat
          end repeat
          tell front window to set current tab to (make new tab with properties {URL:"\(u)"})
        end tell
        """
    }
    runScript(src)
}

// MARK: - Lock engine

final class LockEngine: ObservableObject {
    static let shared = LockEngine()

    @Published var apps: [NSRunningApplication] = []
    @Published var targetPID: pid_t?
    @Published var minutes = 60
    @Published var locked = false
    @Published var endsAt = Date()
    @Published var tabTitle: String?
    @Published var status = ""

    private(set) var target: NSRunningApplication?
    private var lockedURL: String?
    private var lockedAnchor: String?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var relaunching = false

    func refresh() {
        let me = getpid()
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        if targetPID == nil || !apps.contains(where: { $0.processIdentifier == targetPID }) {
            targetPID = frontmostOtherApp() ?? apps.first?.processIdentifier
        }
    }

    /// The app whose window sits directly behind ours, i.e. what you were just looking at.
    private func frontmostOtherApp() -> pid_t? {
        let me = getpid()
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
               apps.contains(where: { $0.processIdentifier == pid }) { return pid }
        }
        return nil
    }

    func lock() {
        guard let pid = targetPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        target = app
        lockedURL = nil; lockedAnchor = nil; tabTitle = nil
        if let kind = BrowserKind.of(app) {
            guard let tab = currentTab(kind) else {
                status = "Couldn't read the browser tab. Allow LectureLock under System Settings › Privacy & Security › Automation, then try again."
                return
            }
            lockedURL = tab.url; lockedAnchor = anchor(for: tab.url); tabTitle = tab.title
        }
        status = ""
        endsAt = Date().addingTimeInterval(Double(minutes) * 60)
        locked = true

        for other in NSWorkspace.shared.runningApplications
        where other.activationPolicy == .regular && other != app && other != .current {
            other.hide()
        }
        NSApp.hide(nil)
        bringTarget()

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handleActivation(a)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func unlock() {
        locked = false
        timer?.invalidate(); timer = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        target = nil
    }

    private func handleActivation(_ app: NSRunningApplication) {
        guard locked, let target, app != target, app != .current else { return }
        app.hide()
        bringTarget()
    }

    private func bringTarget() {
        guard let url = target?.bundleURL else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
    }

    private func tick() {
        guard locked else { return }
        if Date() >= endsAt {
            unlock()
            NSSound(named: "Glass")?.play()
            NSApp.activate()
            return
        }
        guard let target else { return }
        if target.isTerminated { relaunch(); return }

        let front = NSWorkspace.shared.frontmostApplication
        if let front, front != target, front != .current { handleActivation(front) }
        if front == target, let kind = BrowserKind.of(target), let url = lockedURL, let a = lockedAnchor {
            enforceTab(kind, url: url, anchor: a)
        }
    }

    /// The lecture app was quit: start it again (and reopen the lecture if it was a browser tab).
    private func relaunch() {
        guard !relaunching, let old = target, let appURL = old.bundleURL else { return }
        relaunching = true
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let done: (NSRunningApplication?, Error?) -> Void = { app, _ in
            DispatchQueue.main.async {
                self.relaunching = false
                if let app { self.target = app }
            }
        }
        if let s = lockedURL, let url = URL(string: s) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg, completionHandler: done)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg, completionHandler: done)
        }
    }
}

// MARK: - UI

extension Color {
    static let ink = Color(red: 0.04, green: 0.04, blue: 0.04)
    static let paper = Color(red: 0.93, green: 0.92, blue: 0.89)
    static let dim = Color(red: 0.45, green: 0.44, blue: 0.42)
    static let signal = Color(red: 1.0, green: 0.37, blue: 0.12)
}

func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

let unlockPhrase = "i am choosing to stop learning"

struct ContentView: View {
    @ObservedObject var engine = LockEngine.shared
    @State private var phrase = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("LECTURE/LOCK").font(mono(11, .bold)).tracking(3).foregroundColor(.paper)
                    Spacer()
                    Circle().fill(engine.locked ? Color.signal : Color.dim).frame(width: 8, height: 8)
                    Text(engine.locked ? "ARMED" : "IDLE").font(mono(11, .bold)).tracking(2)
                        .foregroundColor(engine.locked ? .signal : .dim)
                }
                Rectangle().fill(Color.paper.opacity(0.15)).frame(height: 1).padding(.vertical, 18)
                if engine.locked { lockedView } else { idleView }
            }
            .padding(28)
        }
        .frame(width: 440, height: 540)
        .onAppear { engine.refresh() }
        .animation(.easeOut(duration: 0.25), value: engine.locked)
    }

    var idleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nothing but\nthe lecture.").font(mono(34, .bold)).foregroundColor(.paper).lineSpacing(2)
            label("01 — SOURCE").padding(.top, 30)
            HStack(spacing: 8) {
                Picker("", selection: $engine.targetPID) {
                    ForEach(engine.apps, id: \.processIdentifier) { app in
                        Text(app.localizedName ?? "?").tag(Optional(app.processIdentifier))
                    }
                }
                .labelsHidden()
                Button(action: engine.refresh) { Text("↻").font(mono(14, .bold)) }
                    .buttonStyle(.plain).foregroundColor(.paper)
            }
            Text("Browsers lock to the tab that's open right now.")
                .font(mono(10)).foregroundColor(.dim).padding(.top, 6)

            label("02 — DURATION").padding(.top, 22)
            HStack(spacing: 0) {
                ForEach([30, 45, 60, 90, 120], id: \.self) { m in
                    Button { engine.minutes = m } label: {
                        Text("\(m)").font(mono(13, .bold))
                            .frame(maxWidth: .infinity).frame(height: 34)
                            .foregroundColor(engine.minutes == m ? .ink : .paper)
                            .background(engine.minutes == m ? Color.paper : Color.clear)
                            .overlay(Rectangle().stroke(Color.paper.opacity(0.25), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            Text("minutes").font(mono(10)).foregroundColor(.dim).padding(.top, 6)

            Spacer()
            if !engine.status.isEmpty {
                Text(engine.status).font(mono(10)).foregroundColor(.signal).padding(.bottom, 10)
            }
            Button(action: engine.lock) {
                HStack {
                    Text("LOCK IN").font(mono(18, .heavy)).tracking(4)
                    Spacer()
                    Text("→").font(mono(22, .bold))
                }
                .padding(.horizontal, 20).frame(height: 58)
                .foregroundColor(.ink).background(Color.signal)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(engine.targetPID == nil)
        }
    }

    var lockedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("LOCKED TO")
            Text(engine.target?.localizedName ?? "—").font(mono(20, .bold)).foregroundColor(.paper)
            if let t = engine.tabTitle {
                Text(t).font(mono(11)).foregroundColor(.dim).lineLimit(2).padding(.top, 4)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(engine.endsAt.timeIntervalSince(ctx.date)))
                Text(String(format: "%02d:%02d", left / 60, left % 60))
                    .font(mono(88, .heavy)).foregroundColor(.signal)
                    .minimumScaleFactor(0.5).lineLimit(1)
            }
            label("REMAINING")
            Spacer()
            label("EMERGENCY EXIT — TYPE: \(unlockPhrase)")
            HStack(spacing: 8) {
                TextField("", text: $phrase)
                    .textFieldStyle(.plain).font(mono(12)).foregroundColor(.paper)
                    .padding(8).overlay(Rectangle().stroke(Color.paper.opacity(0.25), lineWidth: 1))
                    .onSubmit(tryUnlock)
                Button(action: tryUnlock) {
                    Text("EXIT").font(mono(12, .bold)).padding(.horizontal, 14).frame(height: 32)
                        .foregroundColor(.paper).overlay(Rectangle().stroke(Color.paper.opacity(0.4), lineWidth: 1))
                }.buttonStyle(.plain)
            }
        }
    }

    func tryUnlock() {
        if phrase.lowercased().trimmingCharacters(in: .whitespaces) == unlockPhrase {
            phrase = ""
            engine.unlock()
        }
    }

    func label(_ s: String) -> some View {
        Text(s).font(mono(10, .bold)).tracking(2).foregroundColor(.dim).padding(.bottom, 8)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LockEngine.shared.locked ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { true }
}

@main
struct LectureLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Lecture Lock", id: "main") { ContentView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
    }
}
