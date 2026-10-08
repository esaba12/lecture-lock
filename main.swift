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

    var appName: String {
        switch self {
        case .chromium(let name): name
        case .safari: "Safari"
        }
    }
    /// AppleScript for the front window's visible tab.
    var frontTab: String {
        switch self {
        case .chromium: "active tab of window 1"
        case .safari: "current tab of front window"
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

/// A JavaScript string literal for `s`.
func jsString(_ s: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
}

func currentTab(_ kind: BrowserKind) -> (url: String, title: String)? {
    let title = if case .safari = kind { "name" } else { "title" }
    let src = "tell application \"\(kind.appName)\" to return {URL of \(kind.frontTab), \(title) of \(kind.frontTab)}"
    guard let d = runScript(src), d.numberOfItems == 2,
          let url = d.atIndex(1)?.stringValue else { return nil }
    return (url, d.atIndex(2)?.stringValue ?? url)
}

/// What must stay in the URL when locked to one page: the video id on YouTube, otherwise host + path.
func pageAnchor(_ urlString: String) -> String {
    guard let c = URLComponents(string: urlString), let host = c.host else { return urlString }
    if host.hasSuffix("youtube.com"), let v = c.queryItems?.first(where: { $0.name == "v" })?.value { return "v=\(v)" }
    if host == "youtu.be" { return "v=" + c.path.dropFirst() }
    return host + c.path
}

/// What must stay in the URL when locked to a whole site.
func siteAnchor(_ urlString: String) -> String {
    let host = URLComponents(string: urlString)?.host ?? urlString
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

/// "https://www.sqlbolt.com/lesson/end/" -> "sqlbolt.com/lesson/end", for forgiving link matching.
func normalizeLink(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for p in ["https://", "http://", "www."] where t.hasPrefix(p) { t.removeFirst(p.count) }
    while t.hasSuffix("/") { t.removeLast() }
    return t
}

/// Make sure a tab matching `anchor` is the one in front; reopen `url` if none is left.
/// Returns the front tab's URL when it matches.
@discardableResult
func enforceTab(_ kind: BrowserKind, url: String, anchor: String) -> String? {
    let u = esc(url), a = esc(anchor)
    let src: String
    switch kind {
    case .chromium(let name):
        src = """
        tell application "\(name)"
          if (count of windows) is 0 then
            make new window
            set URL of active tab of window 1 to "\(u)"
            return ""
          end if
          set cur to ""
          try
            set cur to URL of active tab of window 1
          end try
          if cur contains "\(a)" then return cur
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
                return ""
              end if
            end repeat
          end repeat
          tell window 1 to make new tab with properties {URL:"\(u)"}
          return ""
        end tell
        """
    case .safari:
        src = """
        tell application "Safari"
          if (count of windows) is 0 then
            make new document with properties {URL:"\(u)"}
            return ""
          end if
          set cur to ""
          try
            set cur to URL of current tab of front window
          end try
          if cur contains "\(a)" then return cur
          repeat with w in windows
            repeat with t in tabs of w
              set tu to ""
              try
                set tu to URL of t
              end try
              if tu contains "\(a)" then
                set current tab of w to t
                set index of w to 1
                return ""
              end if
            end repeat
          end repeat
          tell front window to set current tab to (make new tab with properties {URL:"\(u)"})
          return ""
        end tell
        """
    }
    let cur = runScript(src)?.stringValue ?? ""
    return cur.isEmpty ? nil : cur
}

// MARK: - Page inspection (JavaScript run inside the lecture tab)

enum TabJS { case value(String), jsDisabled, failed }

/// Runs `js` in the front tab if it matches `anchor`, else the first tab that does. Returns "notab" if none.
func runInLectureTab(_ kind: BrowserKind, anchor: String, js: String) -> TabJS {
    let a = esc(anchor), j = esc(js)
    let exec = switch kind {
    case .chromium: "execute t javascript \"\(j)\""
    case .safari: "do JavaScript \"\(j)\" in t"
    }
    let src = """
    tell application "\(kind.appName)"
      if (count of windows) > 0 then
        set t to \(kind.frontTab)
        set tu to ""
        try
          set tu to URL of t
        end try
        if tu contains "\(a)" then return (\(exec))
      end if
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

func enableJSHint(_ kind: BrowserKind) -> String {
    switch kind {
    case .chromium(let name): "Turn on \(name) › View › Developer › Allow JavaScript from Apple Events, then try again."
    case .safari: "Turn on Safari › Develop › Allow JavaScript from Apple Events (enable the Develop menu in Settings › Advanced first), then try again."
    }
}

let sep = "|~|"

/// Picks the longest video on the page (skips previews/thumbnails).
private let pickVideo = "var vs=[].slice.call(document.querySelectorAll('video')).filter(function(v){return isFinite(v.duration)&&v.duration>0});vs.sort(function(a,b){return b.duration-a.duration});var v=vs[0];"
let probeVideoJS = "(function(){if(document.querySelector('.ad-showing'))return 'ad';\(pickVideo)if(!v)return 'none';return [v.currentTime,v.duration,v.paused?1:0,v.playbackRate].join(',')})()"
func seekVideoJS(_ t: Double) -> String { "(function(){\(pickVideo)if(v)v.currentTime=\(t);return 'ok'})()" }

/// URL plus referrer: an empty referrer means the page was typed in, not clicked to.
let locationJS = "(function(){return location.href+'\(sep)'+document.referrer})()"
func pageHasTextJS(_ phrase: String) -> String {
    "(function(){return document.body&&document.body.innerText.toLowerCase().indexOf(\(jsString(phrase.lowercased())))>=0?'1':'0'})()"
}

struct VideoState { var current, duration, rate: Double; var paused: Bool }

// MARK: - Course presets

struct Course {
    let name: String
    let host: String
    let lessons: [(slug: String, title: String)]
    /// JS returning "<path>|~|<1 if this lesson is done>".
    let doneJS: String

    func index(ofURL url: String) -> Int? {
        guard let path = URLComponents(string: url)?.path else { return nil }
        return index(ofPath: path)
    }
    func index(ofPath path: String) -> Int? {
        let slug = path.split(separator: "/").last.map(String.init) ?? ""
        return lessons.firstIndex { $0.slug == slug }
    }
}

let courses: [Course] = [
    Course(
        name: "SQLBolt", host: "sqlbolt.com",
        lessons: [
            ("select_queries_introduction", "1 · SELECT queries 101"),
            ("select_queries_with_constraints", "2 · Constraints (Pt. 1)"),
            ("select_queries_with_constraints_pt_2", "3 · Constraints (Pt. 2)"),
            ("filtering_sorting_query_results", "4 · Filtering and sorting"),
            ("select_queries_review", "5 · Review: simple SELECTs"),
            ("select_queries_with_joins", "6 · JOINs"),
            ("select_queries_with_outer_joins", "7 · OUTER JOINs"),
            ("select_queries_with_nulls", "8 · NULLs"),
            ("select_queries_with_expressions", "9 · Expressions"),
            ("select_queries_with_aggregates", "10 · Aggregates (Pt. 1)"),
            ("select_queries_with_aggregates_pt_2", "11 · Aggregates (Pt. 2)"),
            ("select_queries_order_of_execution", "12 · Order of execution"),
            ("inserting_rows", "13 · Inserting rows"),
            ("updating_rows", "14 · Updating rows"),
            ("deleting_rows", "15 · Deleting rows"),
            ("creating_tables", "16 · Creating tables"),
            ("altering_tables", "17 · Altering tables"),
            ("dropping_tables", "18 · Dropping tables"),
        ],
        // A lesson's Continue button loses `disabled` once every exercise on it is solved.
        doneJS: "(function(){var c=document.querySelector('.continue');return location.pathname+'\(sep)'+(c&&!/disabled/.test(c.className)?1:0)})()"
    ),
]

func course(forURL url: String) -> Course? {
    let host = siteAnchor(url)
    return courses.first { host == $0.host || host.hasSuffix("." + $0.host) }
}

// MARK: - Lock engine

enum LockMode: String, CaseIterable, Identifiable {
    case timer, video, link, course, text, manual
    var id: String { rawValue }

    var title: String {
        switch self {
        case .timer: "Timer ends"
        case .video: "Video ends"
        case .link: "I reach a link"
        case .course: "I finish a course"
        case .text: "Page shows text"
        case .manual: "I say I'm done"
        }
    }
    var needsBrowser: Bool { self != .timer && self != .manual }
    /// These follow you around a site, so locking to one page would block progress.
    var siteWide: Bool { self == .link || self == .course || self == .text }
}

enum LockScope: String { case page, site }

final class LockEngine: ObservableObject {
    static let shared = LockEngine()
    private let defaults = UserDefaults.standard

    @Published var apps: [NSRunningApplication] = []
    @Published var targetPID: pid_t? { didSet { if targetPID != oldValue { peekTab() } } }
    @Published var idleTabURL: String?
    @Published var minutes = 60
    @Published var locked = false
    @Published var lockedAt = Date()
    @Published var endsAt = Date()
    @Published var tabTitle: String?
    @Published var status = ""
    @Published var menuText = ""

    // Live progress for the condition modes.
    @Published var video: VideoState?
    @Published var maxWatched: Double = 0
    @Published var lockedCourse: Course?
    @Published var courseRange = 0...0
    @Published var completed: Set<Int> = []
    @Published var typedLinkWarning = false

    // Settings, remembered between launches.
    @Published var mode: LockMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var scope: LockScope { didSet { defaults.set(scope.rawValue, forKey: "scope") } }
    @Published var allowed: Set<String> { didSet { defaults.set(Array(allowed), forKey: "allowed") } }
    @Published var menuBar: Bool { didSet { defaults.set(menuBar, forKey: "menuBar") } }
    @Published var goalLink: String { didSet { defaults.set(goalLink, forKey: "goalLink") } }
    @Published var goalText: String { didSet { defaults.set(goalText, forKey: "goalText") } }
    @Published var courseGoal: [String: Int] { didSet { defaults.set(courseGoal, forKey: "courseGoal") } }

    private(set) var target: NSRunningApplication?
    private(set) var lockedMode: LockMode = .timer
    private var lastGoodURL: String?
    private var lockedAnchor: String?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var ticks = 0
    private var lastPoll = Date()
    private var relaunching = false

    init() {
        mode = LockMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .timer
        scope = LockScope(rawValue: defaults.string(forKey: "scope") ?? "") ?? .page
        allowed = Set(defaults.stringArray(forKey: "allowed") ?? [])
        menuBar = defaults.object(forKey: "menuBar") as? Bool ?? true
        goalLink = defaults.string(forKey: "goalLink") ?? ""
        goalText = defaults.string(forKey: "goalText") ?? ""
        courseGoal = defaults.dictionary(forKey: "courseGoal") as? [String: Int] ?? [:]
    }

    func refresh() {
        let me = getpid()
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        if targetPID == nil || !apps.contains(where: { $0.processIdentifier == targetPID }) {
            targetPID = frontmostOtherApp() ?? apps.first?.processIdentifier
        }
        peekTab()
    }

    /// Reads the browser's current tab so the setup screen can offer the right course.
    func peekTab() {
        guard let pid = targetPID, let app = NSRunningApplication(processIdentifier: pid),
              let kind = BrowserKind.of(app) else { idleTabURL = nil; return }
        idleTabURL = currentTab(kind)?.url
    }

    var idleCourse: Course? { idleTabURL.flatMap(course(forURL:)) }

    func goalIndex(for c: Course) -> Int { min(courseGoal[c.name] ?? c.lessons.count - 1, c.lessons.count - 1) }

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

    // MARK: Locking

    /// Locks with the saved settings, or a one-off mode/duration (the menu bar's quick timers).
    func lock(_ override: LockMode? = nil, minutes overrideMinutes: Int? = nil) {
        let mode = override ?? self.mode
        let minutes = overrideMinutes ?? self.minutes
        guard let pid = targetPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        let kind = BrowserKind.of(app)
        lastGoodURL = nil; lockedAnchor = nil; tabTitle = nil
        video = nil; maxWatched = 0; lockedCourse = nil; completed = []; typedLinkWarning = false

        if mode.needsBrowser && kind == nil {
            status = "\"\(mode.title)\" only works in a browser (Chrome, Safari, Arc, Brave, Edge)."
            return
        }
        var tabURL = ""
        if let kind {
            guard let tab = currentTab(kind) else {
                status = "Couldn't read the browser tab. Allow LectureLock under System Settings › Privacy & Security › Automation, then try again."
                return
            }
            tabURL = tab.url
            lastGoodURL = tab.url; tabTitle = tab.title
            lockedAnchor = mode.siteWide || scope == .site ? siteAnchor(tab.url) : pageAnchor(tab.url)
        }
        if let kind, let anchor = lockedAnchor, let problem = prepare(kind, anchor: anchor, tabURL: tabURL, mode: mode) {
            status = problem
            return
        }

        target = app
        lockedMode = mode
        status = ""
        lockedAt = Date()
        endsAt = mode == .timer || mode == .manual ? Date().addingTimeInterval(Double(minutes) * 60) : .distantFuture
        locked = true
        ticks = 0
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

    /// Mode-specific checks before locking. Returns a message if locking shouldn't happen.
    private func prepare(_ kind: BrowserKind, anchor: String, tabURL: String, mode: LockMode) -> String? {
        func js(_ code: String) -> Result<String, LockError> {
            switch runInLectureTab(kind, anchor: anchor, js: code) {
            case .jsDisabled: .failure(LockError(enableJSHint(kind)))
            case .failed: .failure(LockError("Couldn't talk to the browser. Try again."))
            case .value(let s): .success(s)
            }
        }
        switch mode {
        case .timer, .manual:
            return nil

        case .video:
            switch js(probeVideoJS) {
            case .failure(let e): return e.message
            case .success(let s):
                guard let v = parseVideo(s) else {
                    return s == "ad"
                        ? "An ad is playing. Lock in once the lecture starts."
                        : "No video found on this tab. If it's embedded (e.g. Panopto inside Canvas), open the video directly, or use the timer."
                }
                video = v; maxWatched = v.current; lastPoll = Date()
                return nil
            }

        case .link:
            let goal = normalizeLink(goalLink)
            if goal.isEmpty { return "Paste the link that means you're done." }
            if siteAnchor("https://" + goal) != anchor {
                return "That link isn't on \(anchor). Open the site you'll be working on, then lock in."
            }
            if normalizeLink(tabURL).contains(goal) { return "You're already on that link. Pick one you haven't reached yet." }
            if case .failure(let e) = js(locationJS) { return e.message }
            return nil

        case .course:
            guard let c = course(forURL: tabURL) else {
                return "Open a supported course in the browser first (\(courses.map(\.name).joined(separator: ", ")))."
            }
            let start = c.index(ofURL: tabURL) ?? 0
            let goal = goalIndex(for: c)
            if start > goal { return "You're already past your goal lesson. Pick a later one." }
            if case .failure(let e) = js(c.doneJS) { return e.message }
            lockedCourse = c; courseRange = start...goal
            return nil

        case .text:
            let phrase = goalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if phrase.isEmpty { return "Type the text that shows up when you're done." }
            switch js(pageHasTextJS(phrase)) {
            case .failure(let e): return e.message
            case .success(let s):
                if s == "1" { return "\"\(phrase)\" is already on this page. Pick text that only shows up when you're done." }
                return nil
            }
        }
    }

    /// From the menu bar: lock to whatever app you're using right now. Returns false if it couldn't.
    @discardableResult
    func lockFrontmost(_ override: LockMode? = nil, minutes: Int? = nil) -> Bool {
        refresh()
        if let front = NSWorkspace.shared.frontmostApplication, front != .current {
            targetPID = front.processIdentifier
        }
        lock(override, minutes: minutes)
        return locked
    }

    /// One line describing the saved settings, for the menu bar.
    var settingsSummary: String {
        switch mode {
        case .timer: durationText(minutes).lowercased()
        case .manual: "at least \(durationText(minutes).lowercased())"
        case .video: "until the video ends"
        case .link: "until I reach \(normalizeLink(goalLink).isEmpty ? "a link" : normalizeLink(goalLink))"
        case .course: "until the course is done"
        case .text: "until the page says \"\(goalText)\""
        }
    }

    func unlock() {
        locked = false
        timer?.invalidate(); timer = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        target = nil
    }

    func finish(_ message: String) {
        unlock()
        status = message
        NSSound(named: "Glass")?.play()
        NSApp.activate()
    }

    /// Manual mode: the "I'm done" button only works once the minimum time has passed.
    var canSayDone: Bool { lockedMode == .manual && Date() >= endsAt }

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
        if lockedMode == .timer, Date() >= endsAt { finish("Time's up. Nice work."); return }
        guard let target else { return }
        if target.isTerminated { relaunch(); return }

        let front = NSWorkspace.shared.frontmostApplication
        if let front { handleActivation(front) }
        if front == target, let kind = BrowserKind.of(target), let url = lastGoodURL, let a = lockedAnchor,
           let cur = enforceTab(kind, url: url, anchor: a) {
            lastGoodURL = cur   // so a closed tab reopens where you were, not where you started
        }
        if ticks % 2 == 0 {
            switch lockedMode {
            case .video: pollVideo()
            case .link: pollLink()
            case .course: pollCourse()
            case .text: pollText()
            case .timer, .manual: break
            }
        }
        updateMenuText()
    }

    private func inTab(_ code: String) -> String? {
        guard let target, let kind = BrowserKind.of(target), let a = lockedAnchor,
              case .value(let s) = runInLectureTab(kind, anchor: a, js: code), s != "notab" else { return nil }
        return s
    }

    /// Tracks real watch progress; snaps back skips; unlocks once the end has actually been reached.
    private func pollVideo() {
        guard let s = inTab(probeVideoJS), var v = parseVideo(s) else { return }  // ad, loading, or reopening
        let now = Date()
        let slack = now.timeIntervalSince(lastPoll) * max(v.rate, 1) + 3
        lastPoll = now
        if v.current > maxWatched + slack {
            _ = inTab(seekVideoJS(maxWatched))
            v.current = maxWatched
        } else {
            maxWatched = max(maxWatched, v.current)
        }
        video = v
        if maxWatched >= v.duration - 2 { finish("Lecture finished. Nice work.") }
    }

    private func pollLink() {
        guard let s = inTab(locationJS) else { return }
        let parts = s.components(separatedBy: sep)
        guard normalizeLink(parts[0]).contains(normalizeLink(goalLink)) else { typedLinkWarning = false; return }
        if parts.count > 1, !parts[1].isEmpty {
            finish("Made it. Nice work.")
        } else {
            typedLinkWarning = true
        }
    }

    private func pollCourse() {
        guard let c = lockedCourse, let s = inTab(c.doneJS) else { return }
        let parts = s.components(separatedBy: sep)
        if parts.count == 2, parts[1] == "1", let i = c.index(ofPath: parts[0]) { completed.insert(i) }
        if courseRange.allSatisfy(completed.contains) { finish("Course done. Nice work.") }
    }

    private func pollText() {
        if inTab(pageHasTextJS(goalText.trimmingCharacters(in: .whitespacesAndNewlines))) == "1" {
            finish("Done. Nice work.")
        }
    }

    private func parseVideo(_ s: String) -> VideoState? {
        let p = s.split(separator: ",").compactMap { Double($0) }
        guard p.count == 4 else { return nil }
        return VideoState(current: p[0], duration: p[1], rate: p[3] > 0 ? p[3] : 1, paused: p[2] == 1)
    }

    var coursesDone: Int { courseRange.filter(completed.contains).count }

    /// For countdown modes: real seconds left (video time is divided by playback speed).
    /// For the others: seconds locked in so far.
    var clockSeconds: Int {
        switch lockedMode {
        case .timer, .manual: return max(0, Int(endsAt.timeIntervalSinceNow))
        case .video:
            guard let v = video else { return 0 }
            return max(0, Int((v.duration - maxWatched) / v.rate))
        case .link, .course, .text: return Int(Date().timeIntervalSince(lockedAt))
        }
    }

    private func updateMenuText() {
        switch lockedMode {
        case .course: menuText = "\(coursesDone)/\(courseRange.count)"
        case .video where video?.paused == true: menuText = "❚❚ " + clock(clockSeconds)
        case .manual where canSayDone: menuText = "done?"
        default: menuText = clock(clockSeconds)
        }
    }

    /// The lecture app was quit: start it again (and reopen the page you were on if it was a browser).
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
        if let s = lastGoodURL, let url = URL(string: s) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg, completionHandler: done)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg, completionHandler: done)
        }
    }
}

struct LockError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

func clock(_ s: Int) -> String {
    s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
              : String(format: "%02d:%02d", s / 60, s % 60)
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

/// Orange-on-dim progress bar.
struct Bar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.paper.opacity(0.15))
                Rectangle().fill(Color.signal).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
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
        .frame(width: 440, height: !engine.locked && showAdvanced ? 800 : 580)
        .onAppear { engine.refresh() }
        .animation(.easeOut(duration: 0.25), value: engine.locked)
    }

    // MARK: Setup screen

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
            hint(engine.mode.siteWide || engine.scope == .site
                 ? "Browsers lock to the site that's open right now."
                 : "Browsers lock to the tab that's open right now.")

            VStack(alignment: .leading, spacing: 0) { untilSection }.padding(.top, 22)
            advanced.padding(.top, 22)

            Spacer(minLength: 12)
            if !engine.status.isEmpty {
                Text(engine.status).font(mono(10)).foregroundColor(.signal)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            }
            Button { engine.lock() } label: {
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

    /// Section 02 changes with the unlock condition picked under Advanced.
    @ViewBuilder var untilSection: some View {
        switch engine.mode {
        case .timer, .manual:
            header(engine.mode == .timer ? "02 — DURATION" : "02 — MINIMUM TIME", durationText(engine.minutes))
            DurationSlider(minutes: $engine.minutes).padding(.bottom, 12)
            HStack(spacing: 0) {
                ForEach([30, 45, 60, 90, 120], id: \.self) { m in
                    segment("\(m)", selected: engine.minutes == m) { engine.minutes = m }
                }
            }
            if engine.mode == .manual { hint("An I'M DONE button unlocks after this.") }

        case .video:
            header("02 — UNTIL", "VIDEO ENDS")
            hint("Unlocks when the video finishes. Skipping ahead snaps back; playback speed is fine.")

        case .link:
            header("02 — UNTIL I REACH", "A LINK")
            field("Paste the link that means you're done", text: $engine.goalLink)
            hint("Only counts if you click your way there, not if you type it in.")

        case .course:
            if let c = engine.idleCourse {
                header("02 — FINISH \(c.name.uppercased()) THROUGH", "")
                Picker("", selection: Binding(
                    get: { engine.goalIndex(for: c) },
                    set: { engine.courseGoal[c.name] = $0 }
                )) {
                    ForEach(c.lessons.indices, id: \.self) { i in Text(c.lessons[i].title).tag(i) }
                }
                .labelsHidden()
                hint("A lesson counts once all its exercises are solved. Starts from the lesson you're on.")
            } else {
                header("02 — UNTIL", "COURSE DONE")
                hint("Open a supported course in your browser, then press ↻. Supported: \(courses.map(\.name).joined(separator: ", ")).")
            }

        case .text:
            header("02 — UNTIL THE PAGE SAYS", "")
            field("e.g. Accepted, Submitted, Congratulations", text: $engine.goalText)
            hint("Unlocks when this text appears anywhere on the site.")
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
                        Picker("", selection: $engine.mode) {
                            ForEach(LockMode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                    setting("STAY ON") {
                        if engine.mode.siteWide {
                            Text("Whole site (needed for this unlock condition)")
                                .font(mono(11)).foregroundColor(.paper)
                        } else {
                            HStack(spacing: 0) {
                                segment("THIS PAGE", selected: engine.scope == .page) { engine.scope = .page }
                                segment("WHOLE SITE", selected: engine.scope == .site) { engine.scope = .site }
                            }
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
                    setting("MENU BAR ICON") {
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

    // MARK: Locked screen

    var lockedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("LOCKED TO")
            Text(engine.target?.localizedName ?? "—").font(mono(20, .bold)).foregroundColor(.paper)
            if let t = engine.tabTitle {
                Text(t).font(mono(11)).foregroundColor(.dim).lineLimit(2).padding(.top, 4)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 0) {
                    Text(engine.lockedMode == .course ? "\(engine.coursesDone)/\(engine.courseRange.count)" : clock(engine.clockSeconds))
                        .font(mono(88, .heavy)).foregroundColor(.signal)
                        .minimumScaleFactor(0.4).lineLimit(1)
                    progress
                }
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

    /// What's under the big number, per unlock condition.
    @ViewBuilder var progress: some View {
        switch engine.lockedMode {
        case .timer:
            label("REMAINING")
        case .manual:
            if engine.canSayDone {
                Button { engine.finish("Nice work.") } label: {
                    Text("I'M DONE →").font(mono(16, .heavy)).tracking(3)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .foregroundColor(.ink).background(Color.signal)
                }
                .buttonStyle(.plain)
            } else {
                label("UNTIL YOU CAN SAY YOU'RE DONE")
            }
        case .video:
            if let v = engine.video {
                label("LEFT IN VIDEO" + (v.rate != 1 ? " AT \(String(format: "%g", v.rate))×" : "") + (v.paused ? " · PAUSED" : ""))
                Bar(fraction: engine.maxWatched / max(v.duration, 1))
            }
        case .course:
            label("LESSONS DONE")
            Bar(fraction: Double(engine.coursesDone) / Double(max(engine.courseRange.count, 1)))
            if let c = engine.lockedCourse {
                hint("Goal: \(c.lessons[engine.courseRange.upperBound].title)")
            }
        case .link:
            label("LOCKED IN · UNTIL YOU REACH")
            Text(normalizeLink(engine.goalLink)).font(mono(11)).foregroundColor(.paper).lineLimit(2)
            if engine.typedLinkWarning {
                Text("Typed links don't count. Click your way there.").font(mono(10)).foregroundColor(.signal).padding(.top, 6)
            }
        case .text:
            label("LOCKED IN · UNTIL THE PAGE SAYS")
            Text("\"\(engine.goalText)\"").font(mono(11)).foregroundColor(.paper).lineLimit(2)
        }
    }

    func tryUnlock() {
        if phrase.lowercased().trimmingCharacters(in: .whitespaces) == unlockPhrase {
            phrase = ""
            engine.unlock()
        }
    }

    // MARK: Pieces

    func label(_ s: String) -> some View {
        Text(s).font(mono(10, .bold)).tracking(2).foregroundColor(.dim).padding(.bottom, 8)
    }

    func hint(_ s: String) -> some View {
        Text(s).font(mono(10)).foregroundColor(.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
    }

    func header(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            label(title)
            Spacer()
            Text(value).font(mono(15, .bold)).foregroundColor(.signal)
        }
    }

    func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(mono(12)).foregroundColor(.paper)
            .padding(8).overlay(Rectangle().stroke(Color.paper.opacity(0.25), lineWidth: 1))
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

/// The menu bar icon's menu.
struct MenuBarMenu: View {
    @ObservedObject var engine = LockEngine.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if engine.locked {
            Text("Locked to \(engine.target?.localizedName ?? "—")")
            Text(engine.lockedMode == .course
                 ? "\(engine.coursesDone) of \(engine.courseRange.count) lessons done"
                 : engine.lockedMode == .timer || engine.lockedMode == .video || engine.lockedMode == .manual
                    ? "\(clock(engine.clockSeconds)) left"
                    : "Locked in for \(clock(engine.clockSeconds))")
            Divider()
            Button("Show Lecture Lock…") { show() }
        } else {
            Button("Lock In · \(engine.settingsSummary)") { lock() }
            Menu("Quick timer") {
                ForEach([30, 60, 90], id: \.self) { m in
                    Button("\(m) minutes") { lock(.timer, minutes: m) }
                }
            }
            Text("Locks to the app you're using now")
            Divider()
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

@main
struct LectureLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var engine = LockEngine.shared

    var body: some Scene {
        Window("Lecture Lock", id: "main") { ContentView() }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
        MenuBarExtra(isInserted: $engine.menuBar) {
            MenuBarMenu()
        } label: {
            if engine.locked {
                Image(systemName: "lock.fill")
                Text(engine.menuText).monospacedDigit()
            } else {
                Image(systemName: "lock.open")
            }
        }
    }
}
