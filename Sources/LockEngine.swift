import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications
import ServiceManagement

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

/// Timer-mode work/break rounds. The slider still sets the total session length.
enum BreakPlan: String, CaseIterable, Identifiable {
    case none, short, long
    var id: String { rawValue }
    var workMinutes: Int { switch self { case .none: 0; case .short: 25; case .long: 50 } }
    var breakMinutes: Int { switch self { case .none: 0; case .short: 5; case .long: 10 } }
    var title: String { self == .none ? "NO BREAKS" : "\(workMinutes) + \(breakMinutes)" }
}

struct SessionPhase: Equatable {
    var onBreak: Bool
    var round: Int, rounds: Int
    /// Seconds from session start until this phase / the whole session ends.
    var phaseEnd: Double, sessionEnd: Double
}

/// Where a session of `total` seconds stands after `elapsed` seconds. Work and break blocks
/// alternate starting with work; a break that would run into the end is dropped, so the
/// session ends where it would have started.
func sessionPhase(total: Double, plan: BreakPlan, elapsed: Double) -> SessionPhase {
    let work = Double(plan.workMinutes * 60), brk = Double(plan.breakMinutes * 60)
    guard plan != .none, total > 0 else {
        return SessionPhase(onBreak: false, round: 1, rounds: 1, phaseEnd: total, sessionEnd: total)
    }
    let cycle = work + brk
    let full = (total / cycle).rounded(.down)
    let rest = total - full * cycle
    let rounds = Int(full) + (rest > 0 ? 1 : 0)
    let end = rest == 0 ? total - brk : full * cycle + min(rest, work)
    let t = min(max(elapsed, 0), end)
    let i = min((t / cycle).rounded(.down), Double(rounds - 1))
    let into = t - i * cycle
    let onBreak = into >= work && t < end
    let phaseEnd = onBreak ? (i + 1) * cycle : min(i * cycle + work, end)
    return SessionPhase(onBreak: onBreak, round: Int(i) + 1, rounds: rounds, phaseEnd: phaseEnd, sessionEnd: end)
}

/// Always allowed, so files and the desktop stay reachable.
let finderID = "com.apple.finder"

/// The running lock, saved so it comes back after Force Quit or a restart.
struct LockSnapshot: Codable {
    static let key = "activeLock"
    var bundleID: String
    var bundleURL: URL?
    var mode: String
    var anchor: String?
    var lastGoodURL: String?
    var tabTitle: String?
    var lockedAt: Date
    var endsAt: Date
    var goalLink: String
    var goalText: String
    var course: String?
    var courseStart: Int
    var courseEnd: Int
    var completed: [Int]
    var maxWatched: Double
    var hardMode: Bool?
    var breaks: String?
    var phaseOrigin: Date?
    var sessionTotal: Double?

    /// A timer that ran out while LectureLock wasn't running.
    var isOver: Bool { mode == LockMode.timer.rawValue && Date() >= endsAt }
}

final class LockEngine: ObservableObject {
    static let shared = LockEngine()
    private let defaults = UserDefaults.standard

    @Published var apps: [NSRunningApplication] = []
    @Published var targetPID: pid_t? { didSet { if targetPID != oldValue { peekTab() } } }
    @Published var idleTabURL: String?
    @Published var locked = false
    @Published var lockedAt = Date()
    @Published var endsAt = Date()
    @Published var tabTitle: String?
    @Published var status = ""
    @Published var menuText = ""
    @Published var onBreak = false
    private(set) var phaseEndsAt = Date()
    private(set) var round = 1, rounds = 1

    // Live progress for the condition modes.
    @Published var video: VideoState?
    @Published var maxWatched: Double = 0
    @Published var lockedCourse: Course?
    @Published var courseRange = 0...0
    @Published var completed: Set<Int> = []
    @Published var typedLinkWarning = false

    // Settings, remembered between launches.
    @Published var minutes: Int { didSet { defaults.set(minutes, forKey: "minutes") } }
    @Published var mode: LockMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var scope: LockScope { didSet { defaults.set(scope.rawValue, forKey: "scope") } }
    @Published var allowed: Set<String> { didSet { defaults.set(Array(allowed), forKey: "allowed") } }
    @Published var menuBar: Bool { didSet { defaults.set(menuBar, forKey: "menuBar") } }
    @Published var sound: Bool { didSet { defaults.set(sound, forKey: "sound") } }
    @Published var notify: Bool { didSet { defaults.set(notify, forKey: "notify") } }
    /// Emergency exit stays closed for the first 15 minutes of a lock.
    @Published var hardMode: Bool { didSet { defaults.set(hardMode, forKey: "hardMode") } }
    @Published var breaks: BreakPlan { didSet { defaults.set(breaks.rawValue, forKey: "breaks") } }
    @Published var goalLink: String { didSet { defaults.set(goalLink, forKey: "goalLink") } }
    @Published var goalText: String { didSet { defaults.set(goalText, forKey: "goalText") } }
    @Published var courseGoal: [String: Int] { didSet { defaults.set(courseGoal, forKey: "courseGoal") } }
    @Published var history: [Session] { didSet { defaults.set(try? JSONEncoder().encode(history), forKey: "history") } }
    @Published var schedules: [Schedule] { didSet { defaults.set(try? JSONEncoder().encode(schedules), forKey: "schedules") } }
    private var scheduleLastFired: [String: String] { didSet { defaults.set(scheduleLastFired, forKey: "scheduleLastFired") } }
    private var scheduleTimer: Timer?

    private(set) var target: NSRunningApplication?
    private(set) var lockedMode: LockMode = .timer
    /// Hard mode as it was at lock time, so changing the setting mid-lock does nothing.
    private(set) var lockedHardMode = false
    static let hardModeDelay: TimeInterval = 15 * 60
    private(set) var lockedPlan: BreakPlan = .none
    /// Phases are measured from here; ending a break early moves it back.
    private var phaseOrigin = Date()
    private var sessionTotal: Double = 0
    private var lastGoodURL: String?
    private var lockedAnchor: String?
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var ticks = 0
    private var relaunching = false
    private var warnAtFive = false      // "5 minutes left" still to come this session
    private var warnCanFinish = false   // manual mode's "you can finish now" still to come

    /// All AppleScript runs here, one call at a time, so a hung browser can't freeze the UI.
    private let scriptQueue = DispatchQueue(label: "lecturelock.applescript")
    /// A tick's browser work is still running; later ticks skip theirs instead of queueing up.
    private var scriptBusy = false
    /// Bumped on lock and unlock so results from an earlier session are ignored.
    private var session = 0
    private var lastSnapshot: Data?

    init() {
        // Start the menu bar icon at the far right, where it's last to be hidden behind the notch.
        // ⌘-dragging it saves a new position over this.
        defaults.register(defaults: ["NSStatusItem Preferred Position Item-0": 1])
        let saved = defaults.integer(forKey: "minutes")
        minutes = saved == 0 ? 60 : min(max(saved / 5 * 5, 5), 180)
        mode = LockMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .timer
        scope = LockScope(rawValue: defaults.string(forKey: "scope") ?? "") ?? .page
        allowed = Set(defaults.stringArray(forKey: "allowed") ?? [])
        menuBar = defaults.object(forKey: "menuBar") as? Bool ?? true
        sound = defaults.object(forKey: "sound") as? Bool ?? true
        notify = defaults.object(forKey: "notify") as? Bool ?? true
        hardMode = defaults.bool(forKey: "hardMode")
        breaks = BreakPlan(rawValue: defaults.string(forKey: "breaks") ?? "") ?? .none
        goalLink = defaults.string(forKey: "goalLink") ?? ""
        goalText = defaults.string(forKey: "goalText") ?? ""
        courseGoal = defaults.dictionary(forKey: "courseGoal") as? [String: Int] ?? [:]
        history = defaults.data(forKey: "history").flatMap { try? JSONDecoder().decode([Session].self, from: $0) } ?? []
        schedules = defaults.data(forKey: "schedules").flatMap { try? JSONDecoder().decode([Schedule].self, from: $0) } ?? []
        scheduleLastFired = defaults.dictionary(forKey: "scheduleLastFired") as? [String: String] ?? [:]
        // Separate from the lock's 1s timer, which only runs while locked.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.checkSchedules() }
        RunLoop.main.add(t, forMode: .common)
        scheduleTimer = t
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
        scriptQueue.async { [weak self] in
            let url = currentTab(kind)?.url
            DispatchQueue.main.async {
                guard let self, self.targetPID == pid else { return }
                self.idleTabURL = url
            }
        }
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

    /// Display name for an allowed app, whether or not it's running.
    func appName(_ id: String) -> String {
        if let name = apps.first(where: { $0.bundleIdentifier == id })?.localizedName { return name }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id
    }

    /// Pick allowed apps from disk, so ones that aren't open yet can be added too.
    func pickAllowedApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { allowed.insert(id) }
        }
    }

    private func isAllowed(_ app: NSRunningApplication) -> Bool {
        app == target || app == .current || app.bundleIdentifier == finderID || allowed.contains(app.bundleIdentifier ?? "")
    }

    // MARK: Locking

    /// Locks with the saved settings, or a one-off mode/duration (the menu bar's quick timers).
    func lock(_ override: LockMode? = nil, minutes overrideMinutes: Int? = nil) {
        let mode = override ?? self.mode
        let minutes = overrideMinutes ?? self.minutes
        guard let pid = targetPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        let kind = BrowserKind.of(app)
        session += 1
        lastGoodURL = nil; lockedAnchor = nil; tabTitle = nil
        video = nil; maxWatched = 0; lockedCourse = nil; completed = []; typedLinkWarning = false

        if mode.needsBrowser && kind == nil {
            status = "\"\(mode.title)\" only works in a browser (Chrome, Safari, Arc, Brave, Edge)."
            return
        }
        var tabURL = ""
        if let kind {
            guard let tab = scriptQueue.sync(execute: { currentTab(kind) }) else {
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
        lockedHardMode = hardMode
        status = ""
        lockedAt = Date()
        // Quick timers from the menu bar ignore the break plan.
        lockedPlan = mode == .timer && override == nil && overrideMinutes == nil ? breaks : .none
        phaseOrigin = lockedAt
        sessionTotal = Double(minutes) * 60
        onBreak = false
        updatePhase()
        endsAt = mode == .timer || mode == .manual
            ? lockedAt.addingTimeInterval(sessionPhase(total: sessionTotal, plan: lockedPlan, elapsed: 0).sessionEnd)
            : .distantFuture
        warnAtFive = switch mode {
        case .timer: minutes > 5
        case .video: video.map { ($0.duration - $0.current) / $0.rate > 300 } ?? false
        default: false
        }
        warnCanFinish = mode == .manual
        if notify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
        arm()
    }

    /// Starts a lock that's been set up. Shared by LOCK IN and restoring a saved lock.
    private func arm() {
        locked = true
        ticks = 0
        updateMenuText()
        NSApp.hide(nil)
        enforce()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        saveSnapshot()
        startWatchdog()
    }

    /// Hides everything else, brings the lecture forward, and bounces back any app that gets activated.
    private func enforce() {
        for other in NSWorkspace.shared.runningApplications
        where other.activationPolicy == .regular && !isAllowed(other) {
            other.hide()
        }
        bringTarget()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let a = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handleActivation(a)
        }
    }

    private func saveSnapshot() {
        guard locked, let target, let id = target.bundleIdentifier else { return }
        let snap = LockSnapshot(
            bundleID: id, bundleURL: target.bundleURL, mode: lockedMode.rawValue, anchor: lockedAnchor,
            lastGoodURL: lastGoodURL, tabTitle: tabTitle, lockedAt: lockedAt, endsAt: endsAt,
            goalLink: goalLink, goalText: goalText, course: lockedCourse?.name,
            courseStart: courseRange.lowerBound, courseEnd: courseRange.upperBound,
            completed: completed.sorted(), maxWatched: maxWatched, hardMode: lockedHardMode,
            breaks: lockedPlan.rawValue, phaseOrigin: phaseOrigin, sessionTotal: sessionTotal)
        guard let data = try? JSONEncoder().encode(snap), data != lastSnapshot else { return }
        lastSnapshot = data
        defaults.set(data, forKey: LockSnapshot.key)
    }

    private func clearSnapshot() {
        lastSnapshot = nil
        defaults.removeObject(forKey: LockSnapshot.key)
    }

    /// At launch: pick a lock back up after Force Quit or a restart, reopening the app if it's gone.
    func restore() {
        guard !locked, let data = defaults.data(forKey: LockSnapshot.key) else { return }
        guard let s = try? JSONDecoder().decode(LockSnapshot.self, from: data),
              let mode = LockMode(rawValue: s.mode), !s.isOver else { clearSnapshot(); return }
        lockedMode = mode; lockedAnchor = s.anchor; lastGoodURL = s.lastGoodURL; tabTitle = s.tabTitle
        lockedAt = s.lockedAt; endsAt = s.endsAt
        goalLink = s.goalLink; goalText = s.goalText
        lockedCourse = courses.first { $0.name == s.course }
        courseRange = s.courseStart...max(s.courseStart, s.courseEnd); completed = Set(s.completed)
        video = nil; maxWatched = s.maxWatched; typedLinkWarning = false; status = ""
        lockedHardMode = s.hardMode ?? false
        lockedPlan = BreakPlan(rawValue: s.breaks ?? "") ?? .none
        phaseOrigin = s.phaseOrigin ?? s.lockedAt
        sessionTotal = s.sessionTotal ?? s.endsAt.timeIntervalSince(s.lockedAt)
        onBreak = false
        updatePhase()

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: s.bundleID).first(where: { !$0.isTerminated }) {
            target = app
            arm()
        } else if let appURL = s.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.bundleID) {
            launch(appURL) { app in
                guard !self.locked else { return }
                guard let app else { self.clearSnapshot(); return }
                self.target = app
                self.arm()
            }
        } else {
            clearSnapshot()
        }
    }

    /// Runs this same executable as `--watchdog`, which reopens LectureLock if it's killed mid-lock.
    /// It's a separate process, so it outlives a Force Quit, and exits by itself once the lock is cleared.
    private func startWatchdog() {
        guard let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--watchdog", String(getpid())]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Mode-specific checks before locking. Returns a message if locking shouldn't happen.
    private func prepare(_ kind: BrowserKind, anchor: String, tabURL: String, mode: LockMode) -> String? {
        func js(_ code: String) -> Result<String, LockError> {
            switch scriptQueue.sync(execute: { runInLectureTab(kind, anchor: anchor, js: code) }) {
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
                video = v; maxWatched = v.current
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

    // MARK: Schedules

    private func checkSchedules() {
        guard !locked, let s = dueSchedules(schedules, now: Date(), lastFired: scheduleLastFired).first else { return }
        // Recorded before trying, so a failed start doesn't retry every 30s.
        scheduleLastFired[s.id.uuidString] = dayKey(Date())
        fire(s)
    }

    /// Opens the schedule's app (and page), waits for it to come to the front, then locks to it.
    private func fire(_ s: Schedule) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.appID) else {
            failSchedule("Scheduled lock: couldn't find \(appName(s.appID)).")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if !s.url.isEmpty, BrowserKind.of(bundleID: s.appID) != nil,
           let url = URL(string: s.url.contains("://") ? s.url : "https://" + s.url) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
        }
        waitForFront(s, triesLeft: 20)
    }

    private func waitForFront(_ s: Schedule, triesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if locked { return }   // locked by hand in the meantime
            guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == s.appID else {
                if triesLeft > 0 { waitForFront(s, triesLeft: triesLeft - 1) }
                else { failSchedule("Scheduled lock: \(appName(s.appID)) didn't come to the front.") }
                return
            }
            refresh()
            targetPID = front.processIdentifier
            lock(.timer, minutes: s.minutes)
            if !locked { failSchedule(status) }
        }
    }

    /// Shows the window with why a scheduled lock didn't start.
    private func failSchedule(_ message: String) {
        status = message
        showMainWindow()
    }

    /// Pick one app from disk, for a schedule.
    func pickApp() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    /// One line describing the saved settings, for the menu bar.
    var settingsSummary: String {
        switch mode {
        case .timer: durationText(minutes).lowercased() + (breaks == .none ? "" : " · \(breaks.title) breaks")
        case .manual: "at least \(durationText(minutes).lowercased())"
        case .video: "until the video ends"
        case .link: "until I reach \(normalizeLink(goalLink).isEmpty ? "a link" : normalizeLink(goalLink))"
        case .course: "until the course is done"
        case .text: "until the page says \"\(goalText)\""
        }
    }

    /// Open at login, read live from the system so it stays right if changed in System Settings.
    var loginStatus: SMAppService.Status { SMAppService.mainApp.status }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Couldn't change Open at login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    func unlock() {
        locked = false
        session += 1
        clearSnapshot()
        onBreak = false
        timer?.invalidate(); timer = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        target = nil
    }

    /// Seconds until the emergency exit opens (0 = open now).
    var exitOpensIn: Int {
        guard lockedHardMode else { return 0 }
        return max(0, Int(lockedAt.addingTimeInterval(Self.hardModeDelay).timeIntervalSinceNow.rounded(.up)))
    }

    /// The emergency exit: giving up early, kept separate from finishing.
    func bail() {
        record(finished: false)
        unlock()
    }

    func finish(_ message: String) {
        record(finished: true)
        unlock()
        status = message
        if sound { NSSound(named: "Glass")?.play() }
        showMainWindow()
    }

    private func post(_ body: String) {
        guard notify else { return }
        let content = UNMutableNotificationContent()
        content.title = "Lecture Lock"
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Heads-ups while locked: five minutes left, or manual mode's minimum time is up.
    private func checkWarnings() {
        // With breaks, clockSeconds is the current block; the heads-up is about the whole session.
        let left = lockedMode == .timer ? Int(endsAt.timeIntervalSinceNow) : clockSeconds
        if warnAtFive, lockedMode != .video || video != nil, left <= 300 {
            warnAtFive = false
            post("5 minutes left.")
        }
        if warnCanFinish, canSayDone {
            warnCanFinish = false
            post("Minimum time's up. You can finish whenever you're done.")
        }
    }

    private func record(finished: Bool) {
        guard locked, Date().timeIntervalSince(lockedAt) >= 60 else { return }
        let s = Session(start: lockedAt, end: Date(), mode: lockedMode.rawValue,
                        app: target?.localizedName ?? "", finished: finished)
        history = Array((history + [s]).suffix(2000))
    }

    var todayMinutes: Int { minutesLocked(history, since: Calendar.current.startOfDay(for: Date())) }
    var weekMinutes: Int { minutesLocked(history, since: startOfWeek(Date(), .current)) }
    var streak: Int { streakDays(history, now: Date(), .current) }
    var weekBails: Int {
        let since = startOfWeek(Date(), .current)
        return history.filter { !$0.finished && $0.start >= since }.count
    }

    /// Manual mode: the "I'm done" button only works once the minimum time has passed.
    var canSayDone: Bool { lockedMode == .manual && Date() >= endsAt }

    private func handleActivation(_ app: NSRunningApplication) {
        guard locked, !onBreak, !isAllowed(app) else { return }
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
        if lockedPlan != .none {
            updatePhase()
            if onBreak { updateMenuText(); return }   // keep counting, stop enforcing
        }
        guard let target else { return }
        if target.isTerminated { relaunch(); return }

        let front = NSWorkspace.shared.frontmostApplication
        if let front { handleActivation(front) }
        if !scriptBusy, let kind = BrowserKind.of(target), let a = lockedAnchor {
            browserWork(kind, anchor: a, enforceURL: front == target ? lastGoodURL : nil,
                        pollJS: ticks % 2 == 0 ? pollJS() : nil)
        }
        checkWarnings()
        if ticks % 5 == 0 { saveSnapshot() }
        updateMenuText()
    }

    /// The page check for the current mode, if it has one.
    private func pollJS() -> String? {
        switch lockedMode {
        case .video: probeVideoJS
        case .link: locationJS
        case .course: lockedCourse?.doneJS
        case .text: pageHasTextJS(goalText.trimmingCharacters(in: .whitespacesAndNewlines))
        case .timer, .manual: nil
        }
    }

    /// Runs tab enforcement and the mode's page check on the script queue, then applies the results on main.
    private func browserWork(_ kind: BrowserKind, anchor: String, enforceURL: String?, pollJS: String?) {
        guard enforceURL != nil || pollJS != nil else { return }
        let token = session, mode = lockedMode
        scriptBusy = true
        scriptQueue.async { [weak self] in
            let cur = enforceURL.flatMap { enforceTab(kind, url: $0, anchor: anchor) }
            var result: String?
            if let pollJS, case .value(let s) = runInLectureTab(kind, anchor: anchor, js: pollJS), s != "notab" {
                result = s
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scriptBusy = false
                guard self.locked, token == self.session else { return }
                if let cur { self.lastGoodURL = cur }   // so a closed tab reopens where you were, not where you started
                if let result {
                    switch mode {
                    case .video: self.pollVideo(result)
                    case .link: self.pollLink(result)
                    case .course: self.pollCourse(result)
                    case .text: self.pollText(result)
                    case .timer, .manual: break
                    }
                }
                if self.locked { self.updateMenuText() }
            }
        }
    }

    /// Recomputes the work/break phase and handles the switch between them.
    private func updatePhase() {
        let p = sessionPhase(total: sessionTotal, plan: lockedPlan, elapsed: Date().timeIntervalSince(phaseOrigin))
        phaseEndsAt = phaseOrigin.addingTimeInterval(p.phaseEnd)
        round = p.round; rounds = p.rounds
        guard locked, p.onBreak != onBreak else { return }
        onBreak = p.onBreak
        if sound { NSSound(named: "Glass")?.play() }
        if onBreak {
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = nil
        } else {
            enforce()
            if let target, let kind = BrowserKind.of(target), let url = lastGoodURL, let a = lockedAnchor {
                scriptQueue.async { enforceTab(kind, url: url, anchor: a) }
            }
        }
    }

    /// BACK TO WORK: the rest of the session shifts earlier by the break time skipped.
    func endBreakEarly() {
        guard locked, onBreak else { return }
        let skipped = max(0, phaseEndsAt.timeIntervalSinceNow)
        phaseOrigin.addTimeInterval(-skipped)
        endsAt.addTimeInterval(-skipped)
        updatePhase()
        updateMenuText()
    }

    /// Tracks the furthest point reached; unlocks once the end has been reached.
    private func pollVideo(_ s: String) {
        guard let v = parseVideo(s) else { return }  // ad, loading, or reopening
        maxWatched = max(maxWatched, v.current)
        video = v
        if maxWatched >= v.duration - 2 { finish("Lecture finished. Nice work.") }
    }

    private func pollLink(_ s: String) {
        let parts = s.components(separatedBy: sep)
        guard normalizeLink(parts[0]).contains(normalizeLink(goalLink)) else { typedLinkWarning = false; return }
        if parts.count > 1, !parts[1].isEmpty {
            finish("Made it. Nice work.")
        } else {
            typedLinkWarning = true
        }
    }

    private func pollCourse(_ s: String) {
        guard let c = lockedCourse else { return }
        let parts = s.components(separatedBy: sep)
        if parts.count == 2, parts[1] == "1", let i = c.index(ofPath: parts[0]) { completed.insert(i) }
        if courseRange.allSatisfy(completed.contains) { finish("Course done. Nice work.") }
    }

    private func pollText(_ s: String) {
        if s == "1" {
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
        case .timer where lockedPlan != .none: return max(0, Int(phaseEndsAt.timeIntervalSinceNow))
        case .timer, .manual: return max(0, Int(endsAt.timeIntervalSinceNow))
        case .video:
            guard let v = video else { return 0 }
            return max(0, Int((v.duration - maxWatched) / v.rate))
        case .link, .course, .text: return Int(Date().timeIntervalSince(lockedAt))
        }
    }

    private func updateMenuText() {
        switch lockedMode {
        case .timer where onBreak: menuText = "☕ " + clock(clockSeconds)
        case .course: menuText = "\(coursesDone)/\(courseRange.count)"
        case .video where video?.paused == true: menuText = "❚❚ " + clock(clockSeconds)
        case .manual where canSayDone: menuText = "done?"
        default: menuText = clock(clockSeconds)
        }
    }

    /// The lecture app was quit: start it again (and reopen the page you were on if it was a browser).
    private func relaunch() {
        guard !relaunching, let appURL = target?.bundleURL else { return }
        relaunching = true
        launch(appURL) { app in
            self.relaunching = false
            if let app { self.target = app }
        }
    }

    /// Opens the app, on `lastGoodURL` if there is one. `done` runs on the main queue.
    private func launch(_ appURL: URL, done: @escaping (NSRunningApplication?) -> Void) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let done: (NSRunningApplication?, Error?) -> Void = { app, _ in
            DispatchQueue.main.async { done(app) }
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

// MARK: - History

struct Session: Codable {
    var start: Date
    var end: Date
    var mode: String
    var app: String
    var finished: Bool
}

/// Minutes locked in (finished or not) in sessions that started on or after `since`.
func minutesLocked(_ history: [Session], since: Date) -> Int {
    Int(history.filter { $0.start >= since }.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) } / 60)
}

func startOfWeek(_ now: Date, _ cal: Calendar) -> Date {
    cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now))!
}

/// Consecutive days with a finished session, ending today (or yesterday if nothing yet today).
func streakDays(_ history: [Session], now: Date, _ cal: Calendar) -> Int {
    let days = Set(history.filter(\.finished).map { cal.startOfDay(for: $0.start) })
    var day = cal.startOfDay(for: now)
    if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
    var n = 0
    while days.contains(day) {
        n += 1
        day = cal.date(byAdding: .day, value: -1, to: day)!
    }
    return n
}

/// "1H 20M", "45M".
func hoursMinutes(_ m: Int) -> String {
    m < 60 ? "\(m)M" : "\(m / 60)H \(m % 60)M"
}
