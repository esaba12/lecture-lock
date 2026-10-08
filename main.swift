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

// MARK: - Video detection (JavaScript run inside the lecture tab)

enum TabJS { case value(String), jsDisabled, failed }

/// Runs `js` inside the first tab whose URL contains `anchor`. Returns "notab" if there is none.
func runInLectureTab(_ kind: BrowserKind, anchor: String, js: String) -> TabJS {
    let a = esc(anchor), j = esc(js)
    let (app, exec) = switch kind {
    case .chromium(let name): (name, "execute t javascript \"\(j)\"")
    case .safari: ("Safari", "do JavaScript \"\(j)\" in t")
    }
    let src = """
    tell application "\(app)"
      repeat with w in windows
        repeat with t in tabs of w
          set tu to ""
          try
            set tu to URL of t
          end try
          if tu contains "\(a)" then return (\(exec))
        end repeat
      end repeat
      return "notab"
    end tell
    """
    var err: NSDictionary?
    let result = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err {
        let msg = err[NSAppleScript.errorMessage] as? String ?? ""
        return msg.contains("JavaScript") ? .jsDisabled : .failed
    }
    return .value(result?.stringValue ?? "")
}

/// Picks the longest video on the page (skips previews/thumbnails).
private let pickVideo = "var vs=[].slice.call(document.querySelectorAll('video')).filter(function(v){return isFinite(v.duration)&&v.duration>0});vs.sort(function(a,b){return b.duration-a.duration});var v=vs[0];"
let probeVideoJS = "(function(){if(document.querySelector('.ad-showing'))return 'ad';\(pickVideo)if(!v)return 'none';return [v.currentTime,v.duration,v.paused?1:0,v.playbackRate].join(',')})()"
func seekVideoJS(_ t: Double) -> String { "(function(){\(pickVideo)if(v)v.currentTime=\(t);return 'ok'})()" }

func enableJSHint(_ kind: BrowserKind) -> String {
    switch kind {
    case .chromium(let name): "Turn on \(name) › View › Developer › Allow JavaScript from Apple Events, then try again."
    case .safari: "Turn on Safari › Develop › Allow JavaScript from Apple Events (enable the Develop menu in Settings › Advanced first), then try again."
    }
}

struct VideoState { var current, duration, rate: Double; var paused: Bool }

// MARK: - Lock engine

enum LockMode: String { case timer, video }

final class LockEngine: ObservableObject {
    static let shared = LockEngine()
    private let defaults = UserDefaults.standard

    @Published var apps: [NSRunningApplication] = []
    @Published var targetPID: pid_t?
    @Published var minutes = 60
    @Published var locked = false
    @Published var endsAt = Date()
    @Published var tabTitle: String?
    @Published var status = ""
    @Published var video: VideoState?
    @Published var maxWatched: Double = 0
    @Published var menuText = ""

    // Advanced settings, remembered between launches.
    @Published var mode: LockMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var allowed: Set<String> { didSet { defaults.set(Array(allowed), forKey: "allowed") } }
    @Published var menuBar: Bool { didSet { defaults.set(menuBar, forKey: "menuBar") } }

    private(set) var target: NSRunningApplication?
    private(set) var lockedMode: LockMode = .timer
    private var lockedURL: String?
    private var lockedAnchor: String?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var ticks = 0
    private var lastPoll = Date()
    private var relaunching = false

    init() {
        mode = LockMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .timer
        allowed = Set(defaults.stringArray(forKey: "allowed") ?? [])
        menuBar = defaults.object(forKey: "menuBar") as? Bool ?? true
    }

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

    private func isAllowed(_ app: NSRunningApplication) -> Bool {
        app == target || app == .current || allowed.contains(app.bundleIdentifier ?? "")
    }

    func lock() {
        guard let pid = targetPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        let kind = BrowserKind.of(app)
        lockedURL = nil; lockedAnchor = nil; tabTitle = nil; video = nil; maxWatched = 0
        if let kind {
            guard let tab = currentTab(kind) else {
                status = "Couldn't read the browser tab. Allow LectureLock under System Settings › Privacy & Security › Automation, then try again."
                return
            }
            lockedURL = tab.url; lockedAnchor = anchor(for: tab.url); tabTitle = tab.title
        }
        if mode == .video {
            guard let kind, let a = lockedAnchor else {
                status = "\"Until video ends\" only works in a browser. Use the timer for other apps."
                return
            }
            switch runInLectureTab(kind, anchor: a, js: probeVideoJS) {
            case .jsDisabled: status = enableJSHint(kind); return
            case .failed: status = "Couldn't talk to the browser. Try again."; return
            case .value(let s):
                guard let v = parseVideo(s) else {
                    status = s == "ad"
                        ? "An ad is playing. Lock in once the lecture starts."
                        : "No video found on this tab. If it's embedded (e.g. Panopto inside Canvas), open the video directly, or use the timer."
                    return
                }
                video = v; maxWatched = v.current; lastPoll = Date()
            }
        }
        target = app
        lockedMode = mode
        status = ""
        endsAt = mode == .timer ? Date().addingTimeInterval(Double(minutes) * 60) : .distantFuture
        locked = true
        updateMenuText()

        for other in NSWorkspace.shared.runningApplications
        where other.activationPolicy == .regular && !isAllowed(other) {
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

    private func finish(_ message: String) {
        unlock()
        status = message
        NSSound(named: "Glass")?.play()
        NSApp.activate()
    }

    private func handleActivation(_ app: NSRunningApplication) {
        guard locked, !isAllowed(app) else { return }
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
        ticks += 1
        if Date() >= endsAt { finish("Time's up. Nice work."); return }
        guard let target else { return }
        if target.isTerminated { relaunch(); return }

        let front = NSWorkspace.shared.frontmostApplication
        if let front { handleActivation(front) }
        if front == target, let kind = BrowserKind.of(target), let url = lockedURL, let a = lockedAnchor {
            enforceTab(kind, url: url, anchor: a)
        }
        if lockedMode == .video, ticks % 2 == 0 { pollVideo() }
        updateMenuText()
    }

    /// Tracks real watch progress; snaps back skips; unlocks once the end has actually been reached.
    private func pollVideo() {
        guard let target, let kind = BrowserKind.of(target), let a = lockedAnchor,
              case .value(let s) = runInLectureTab(kind, anchor: a, js: probeVideoJS),
              var v = parseVideo(s) else { return }   // ad, page loading, or tab being reopened
        let now = Date()
        let slack = now.timeIntervalSince(lastPoll) * max(v.rate, 1) + 3
        lastPoll = now
        if v.current > maxWatched + slack {
            _ = runInLectureTab(kind, anchor: a, js: seekVideoJS(maxWatched))
            v.current = maxWatched
        } else {
            maxWatched = max(maxWatched, v.current)
        }
        video = v
        if maxWatched >= v.duration - 2 { finish("Lecture finished. Nice work.") }
    }

    private func parseVideo(_ s: String) -> VideoState? {
        let p = s.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4 else { return nil }
        return VideoState(current: p[0], duration: p[1], rate: p[3] > 0 ? p[3] : 1, paused: p[2] == 1)
    }

    /// Seconds of real time left (video time is divided by playback speed).
    var secondsLeft: Int {
        if lockedMode == .video {
            guard let v = video else { return 0 }
            return max(0, Int((v.duration - maxWatched) / v.rate))
        }
        return max(0, Int(endsAt.timeIntervalSinceNow))
    }

    private func updateMenuText() {
        let left = secondsLeft
        let clock = left >= 3600
            ? String(format: "%d:%02d:%02d", left / 3600, left / 60 % 60, left % 60)
            : String(format: "%02d:%02d", left / 60, left % 60)
        menuText = (video?.paused == true && lockedMode == .video ? "❚❚ " : "◉ ") + clock
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

func durationText(_ m: Int) -> String {
    m < 60 ? "\(m) MIN" : m % 60 == 0 ? "\(m / 60) HR" : "\(m / 60) HR \(m % 60) MIN"
}

/// Flat track, signal-orange fill, square thumb. 5–180 minutes in 5-minute steps.
struct DurationSlider: View {
    @Binding var minutes: Int
    let range = 5...180
    let step = 5

    var body: some View {
        GeometryReader { geo in
            let thumb: CGFloat = 16
            let span = geo.size.width - thumb
            let frac = CGFloat(minutes - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.paper.opacity(0.15)).frame(height: 2)
                Rectangle().fill(Color.signal).frame(width: thumb / 2 + span * frac, height: 2)
                Rectangle().fill(Color.signal).frame(width: thumb, height: thumb)
                    .offset(x: span * frac)
                    .animation(.easeOut(duration: 0.08), value: minutes)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = min(max((g.location.x - thumb / 2) / span, 0), 1)
                let raw = Double(range.lowerBound) + Double(f) * Double(range.upperBound - range.lowerBound)
                minutes = Int((raw / Double(step)).rounded()) * step
            })
        }
        .frame(height: 28)
    }
}

struct ContentView: View {
    @ObservedObject var engine = LockEngine.shared
    @State private var phrase = ""
    @State private var showAdvanced = false

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
        .frame(width: 440, height: !engine.locked && showAdvanced ? 720 : 560)
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

            if engine.mode == .timer {
                HStack(alignment: .firstTextBaseline) {
                    label("02 — DURATION")
                    Spacer()
                    Text(durationText(engine.minutes)).font(mono(15, .bold)).foregroundColor(.signal)
                }
                .padding(.top, 22)
                DurationSlider(minutes: $engine.minutes).padding(.bottom, 12)
                HStack(spacing: 0) {
                    ForEach([30, 45, 60, 90, 120], id: \.self) { m in
                        segment("\(m)", selected: engine.minutes == m) { engine.minutes = m }
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    label("02 — DURATION")
                    Spacer()
                    Text("UNTIL VIDEO ENDS").font(mono(15, .bold)).foregroundColor(.signal)
                }
                .padding(.top, 22)
                Text("Unlocks when the video finishes. Skipping ahead snaps back; playback speed is fine.")
                    .font(mono(10)).foregroundColor(.dim).fixedSize(horizontal: false, vertical: true)
            }

            advanced.padding(.top, 22)

            Spacer(minLength: 12)
            if !engine.status.isEmpty {
                Text(engine.status).font(mono(10)).foregroundColor(.signal)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
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

    var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.2)) { showAdvanced.toggle() } } label: {
                HStack {
                    label("03 — ADVANCED")
                    Spacer()
                    Text(showAdvanced ? "−" : "+").font(mono(14, .bold)).foregroundColor(.paper).padding(.bottom, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 16) {
                    setting("UNLOCK WHEN") {
                        HStack(spacing: 0) {
                            segment("TIMER ENDS", selected: engine.mode == .timer) { engine.mode = .timer }
                            segment("VIDEO ENDS", selected: engine.mode == .video) { engine.mode = .video }
                        }
                    }
                    setting("ALSO ALLOW") {
                        Menu {
                            ForEach(engine.apps.filter { $0.processIdentifier != engine.targetPID }, id: \.processIdentifier) { app in
                                let id = app.bundleIdentifier ?? ""
                                Toggle(app.localizedName ?? id, isOn: Binding(
                                    get: { engine.allowed.contains(id) },
                                    set: { on in if on { engine.allowed.insert(id) } else { engine.allowed.remove(id) } }
                                ))
                            }
                        } label: {
                            Text(allowedSummary).font(mono(12))
                        }
                        .menuStyle(.borderlessButton)
                        .padding(.horizontal, 10).frame(height: 32)
                        .overlay(Rectangle().stroke(Color.paper.opacity(0.25), lineWidth: 1))
                    }
                    setting("MENU BAR TIMER") {
                        HStack(spacing: 0) {
                            segment("ON", selected: engine.menuBar) { engine.menuBar = true }
                            segment("OFF", selected: !engine.menuBar) { engine.menuBar = false }
                        }
                        .frame(width: 140)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
    }

    var allowedSummary: String {
        let names = engine.apps.filter { engine.allowed.contains($0.bundleIdentifier ?? "") }.compactMap(\.localizedName)
        return names.isEmpty ? "Nothing else (e.g. pick a notes app)" : names.joined(separator: ", ")
    }

    var lockedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("LOCKED TO")
            Text(engine.target?.localizedName ?? "—").font(mono(20, .bold)).foregroundColor(.paper)
            if let t = engine.tabTitle {
                Text(t).font(mono(11)).foregroundColor(.dim).lineLimit(2).padding(.top, 4)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let left = engine.secondsLeft
                Text(left >= 3600
                     ? String(format: "%d:%02d:%02d", left / 3600, left / 60 % 60, left % 60)
                     : String(format: "%02d:%02d", left / 60, left % 60))
                    .font(mono(88, .heavy)).foregroundColor(.signal)
                    .minimumScaleFactor(0.4).lineLimit(1)
            }
            if engine.lockedMode == .video, let v = engine.video {
                label("LEFT IN VIDEO" + (v.rate != 1 ? " AT \(String(format: "%g", v.rate))×" : "") + (v.paused ? " · PAUSED" : ""))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.paper.opacity(0.15))
                        Rectangle().fill(Color.signal)
                            .frame(width: geo.size.width * min(1, engine.maxWatched / max(v.duration, 1)))
                    }
                }
                .frame(height: 4)
            } else {
                label("REMAINING")
            }
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

    func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(mono(12, .bold))
                .frame(maxWidth: .infinity).frame(height: 32)
                .foregroundColor(selected ? .ink : .paper)
                .background(selected ? Color.paper : Color.clear)
                .overlay(Rectangle().stroke(Color.paper.opacity(0.25), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func setting<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(mono(9, .bold)).tracking(2).foregroundColor(.dim).padding(.bottom, 6)
            content()
        }
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
    @ObservedObject var engine = LockEngine.shared

    var body: some Scene {
        Window("Lecture Lock", id: "main") { ContentView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
        MenuBarExtra(isInserted: Binding(get: { engine.locked && engine.menuBar }, set: { _ in })) {
            Button("Show Lecture Lock") {
                NSApp.activate()
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
        } label: {
            Text(engine.menuText).monospacedDigit()
        }
    }
}
