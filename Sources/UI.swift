import SwiftUI
import AppKit

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
    @State private var draft: Schedule?

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
        .frame(width: 440, height: !engine.locked && showAdvanced ? 800 : 620)
        .onAppear { engine.refresh() }
        .animation(.easeOut(duration: 0.25), value: engine.locked)
    }

    // MARK: Setup screen

    var idleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scrolls when the settings outgrow the window (e.g. Advanced open on a small screen); LOCK IN stays put.
            ScrollView(.vertical, showsIndicators: false) { setup }
                .mask(VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 24)
                })
            if !engine.status.isEmpty {
                Text(engine.status).font(mono(10)).foregroundColor(.signal)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 10)
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
            .padding(.top, engine.status.isEmpty ? 12 : 0)
        }
    }

    var setup: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nothing but\nthe lecture.").font(mono(34, .bold)).foregroundColor(.paper).lineSpacing(2)
            if !engine.history.isEmpty { stats.padding(.top, 10) }
            label("01 — SOURCE").padding(.top, engine.history.isEmpty ? 30 : 20)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// TODAY 1H 20M · WEEK 6H 5M · STREAK 4D · 2 EXITS
    var stats: some View {
        let dim = { (s: String) in Text(s).foregroundColor(.dim) }
        let num = { (s: String) in Text(s).foregroundColor(.paper) }
        var line = dim("TODAY ") + num(hoursMinutes(engine.todayMinutes))
            + dim(" · WEEK ") + num(hoursMinutes(engine.weekMinutes))
            + dim(" · STREAK ") + num("\(engine.streak)D")
        if engine.weekBails > 0 { line = line + dim(" · \(engine.weekBails) EXIT\(engine.weekBails == 1 ? "" : "S")") }
        return line.font(mono(10, .bold)).lineLimit(1)
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
            if engine.mode == .timer {
                HStack(spacing: 0) {
                    ForEach(BreakPlan.allCases) { p in
                        segment(p.title, selected: engine.breaks == p) { engine.breaks = p }
                    }
                }
                .padding(.top, 8)
                if engine.breaks != .none {
                    let p = sessionPhase(total: Double(engine.minutes) * 60, plan: engine.breaks, elapsed: 0)
                    hint("\(p.rounds) \(p.rounds == 1 ? "round" : "rounds"), ends after \(durationText(Int(p.sessionEnd) / 60).lowercased()). No break at the end.")
                }
            }

        case .video:
            header("02 — UNTIL", "VIDEO ENDS")
            hint("Unlocks when the video finishes.")

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
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(engine.allowed.sorted { engine.appName($0) < engine.appName($1) }, id: \.self) { id in
                                HStack {
                                    Text(engine.appName(id)).font(mono(12)).foregroundColor(.paper)
                                    Spacer()
                                    Button { engine.allowed.remove(id) } label: { Text("×").font(mono(14, .bold)) }
                                        .buttonStyle(.plain).foregroundColor(.dim)
                                }
                                .padding(.horizontal, 10).frame(height: 28)
                                .overlay(Rectangle().stroke(Color.paper.opacity(0.25), lineWidth: 1))
                            }
                            Menu {
                                ForEach(engine.apps.filter { $0.processIdentifier != engine.targetPID && $0.bundleIdentifier != finderID && !engine.allowed.contains($0.bundleIdentifier ?? "") }, id: \.processIdentifier) { app in
                                    Button(app.localizedName ?? "?") { if let id = app.bundleIdentifier { engine.allowed.insert(id) } }
                                }
                                Divider()
                                Button("Other app…") { engine.pickAllowedApps() }
                            } label: {
                                Text(engine.allowed.isEmpty ? "+ ADD APP (e.g. a notes app)" : "+ ADD APP").font(mono(12, .bold))
                            }
                            .menuStyle(.borderlessButton)
                            .padding(.horizontal, 10).frame(height: 28)
                            .overlay(Rectangle().stroke(Color.paper.opacity(0.25), lineWidth: 1))
                        }
                    }
                    setting("SCHEDULE") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(engine.schedules) { s in
                                HStack {
                                    Text(scheduleText(s)).font(mono(12)).foregroundColor(.paper).lineLimit(1)
                                    Spacer()
                                    Button { engine.schedules.removeAll { $0.id == s.id } } label: { Text("×").font(mono(14, .bold)) }
                                        .buttonStyle(.plain).foregroundColor(.dim)
                                }
                                .padding(.horizontal, 10).frame(height: 28)
                                .overlay(Rectangle().stroke(Color.paper.opacity(0.25), lineWidth: 1))
                            }
                            Button { draft = newSchedule() } label: {
                                Text("+ ADD SCHEDULE").font(mono(12, .bold)).foregroundColor(.paper)
                                    .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading).frame(height: 28)
                                    .overlay(Rectangle().stroke(Color.paper.opacity(0.25), lineWidth: 1))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            hint("Fires while LectureLock is running — turn on Open at login.")
                        }
                    }
                    .sheet(item: $draft) { _ in scheduleSheet }
                    HStack(alignment: .top, spacing: 24) {
                        setting("MENU BAR ICON") {
                            HStack(spacing: 0) {
                                segment("ON", selected: engine.menuBar) { engine.menuBar = true }
                                segment("OFF", selected: !engine.menuBar) { engine.menuBar = false }
                            }
                            .frame(width: 140)
                        }
                        setting("FINISH SOUND") {
                            HStack(spacing: 0) {
                                segment("ON", selected: engine.sound) { engine.sound = true }
                                segment("OFF", selected: !engine.sound) { engine.sound = false }
                            }
                            .frame(width: 140)
                        }
                    }
                    HStack(alignment: .top, spacing: 24) {
                        setting("NOTIFICATIONS") {
                            HStack(spacing: 0) {
                                segment("ON", selected: engine.notify) { engine.notify = true }
                                segment("OFF", selected: !engine.notify) { engine.notify = false }
                            }
                            .frame(width: 140)
                        }
                        setting("OPEN AT LOGIN") {
                            let on = engine.loginStatus == .enabled || engine.loginStatus == .requiresApproval
                            HStack(spacing: 0) {
                                segment("ON", selected: on) { engine.setOpenAtLogin(true) }
                                segment("OFF", selected: !on) { engine.setOpenAtLogin(false) }
                            }
                            .frame(width: 140)
                            if engine.loginStatus == .requiresApproval {
                                hint("Approve in System Settings › General › Login Items.").frame(width: 140, alignment: .leading)
                            }
                        }
                    }
                    setting("EMERGENCY EXIT") {
                        HStack(spacing: 0) {
                            segment("ANYTIME", selected: !engine.hardMode) { engine.hardMode = false }
                            segment("AFTER 15 MIN", selected: engine.hardMode) { engine.hardMode = true }
                        }
                        .frame(width: 304)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity)
            }
        }
    }

    // MARK: Schedule editor

    static let dayNames = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]

    /// "MON WED · 10:00 · Chrome · 75 MIN"
    func scheduleText(_ s: Schedule) -> String {
        let days = s.days.count == 7 ? "EVERY DAY" : weekdayOrder.filter(s.days.contains).map { Self.dayNames[$0 - 1] }.joined(separator: " ")
        return "\(days) · \(String(format: "%02d:%02d", s.hour, s.minute)) · \(engine.appName(s.appID)) · \(durationText(s.minutes))"
    }

    func newSchedule() -> Schedule {
        let now = Calendar.current.dateComponents([.weekday, .hour], from: Date())
        let app = engine.targetPID.flatMap(NSRunningApplication.init(processIdentifier:))?.bundleIdentifier ?? ""
        return Schedule(days: [now.weekday ?? 2], hour: ((now.hour ?? 0) + 1) % 24, minute: 0, appID: app, minutes: engine.minutes)
    }

    @ViewBuilder var scheduleSheet: some View {
        if let d = Binding($draft) {
            VStack(alignment: .leading, spacing: 16) {
                label("NEW SCHEDULE")
                setting("DAYS") {
                    HStack(spacing: 0) {
                        ForEach(weekdayOrder, id: \.self) { day in
                            segment(String(Self.dayNames[day - 1].prefix(1)), selected: d.days.wrappedValue.contains(day)) {
                                if d.days.wrappedValue.contains(day) { d.days.wrappedValue.remove(day) } else { d.days.wrappedValue.insert(day) }
                            }
                        }
                    }
                }
                setting("TIME") {
                    DatePicker("", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: d.hour.wrappedValue, minute: d.minute.wrappedValue, second: 0, of: Date()) ?? Date() },
                        set: { t in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: t)
                            d.hour.wrappedValue = c.hour ?? 0; d.minute.wrappedValue = c.minute ?? 0
                        }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden().fixedSize()
                }
                setting("APP") {
                    Menu {
                        ForEach(engine.apps.filter { $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? "?") { d.appID.wrappedValue = app.bundleIdentifier ?? "" }
                        }
                        Divider()
                        Button("Other app…") { if let id = engine.pickApp() { d.appID.wrappedValue = id } }
                    } label: {
                        Text(d.appID.wrappedValue.isEmpty ? "PICK AN APP" : engine.appName(d.appID.wrappedValue)).font(mono(12, .bold))
                    }
                    .menuStyle(.borderlessButton)
                    .padding(.horizontal, 10).frame(height: 28)
                    .overlay(Rectangle().stroke(Color.paper.opacity(0.25), lineWidth: 1))
                }
                setting("PAGE (OPTIONAL)") {
                    field("Page to open, e.g. canvas…", text: d.url)
                }
                VStack(alignment: .leading, spacing: 0) {
                    header("DURATION", durationText(d.minutes.wrappedValue))
                    DurationSlider(minutes: d.minutes)
                }
                HStack(spacing: 8) {
                    segment("CANCEL", selected: false) { draft = nil }
                    Button {
                        engine.schedules.append(d.wrappedValue)
                        draft = nil
                    } label: {
                        Text("SAVE").font(mono(12, .heavy)).tracking(2)
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .foregroundColor(.ink).background(Color.signal)
                    }
                    .buttonStyle(.plain)
                    .disabled(d.days.wrappedValue.isEmpty || d.appID.wrappedValue.isEmpty)
                    .opacity(d.days.wrappedValue.isEmpty || d.appID.wrappedValue.isEmpty ? 0.4 : 1)
                }
            }
            .padding(28)
            .frame(width: 400)
            .background(Color.ink)
            .environment(\.colorScheme, .dark)
        }
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
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if engine.exitOpensIn > 0 {
                    // A timer lock shorter than the hard-mode delay ends before the exit would open.
                    label(engine.lockedMode == .timer && engine.exitOpensIn >= Int(engine.endsAt.timeIntervalSinceNow)
                          ? "EMERGENCY EXIT CLOSED UNTIL THE END"
                          : "EMERGENCY EXIT OPENS IN \(clock(engine.exitOpensIn))")
                } else {
                    emergencyExit
                }
            }
        }
    }

    var emergencyExit: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("EMERGENCY EXIT — TYPE: \(unlockPhrase)")
            HStack(spacing: 8) {
                TextField("", text: $phrase)
                    .textFieldStyle(.plain).font(mono(12)).foregroundColor(.paper)
                    .padding(8).overlay(Rectangle().stroke(Color.paper.opacity(0.25), lineWidth: 1))
                    .onSubmit(tryUnlock)
                    // Type it, don't paste it: reject any edit that adds more than one character at once.
                    .onChange(of: phrase) { old, new in
                        if new.count - old.count > 1 { phrase = old }
                    }
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
            if engine.lockedPlan == .none {
                label("REMAINING")
            } else if engine.onBreak {
                label("BREAK · BACK AT \(engine.phaseEndsAt.formatted(date: .omitted, time: .shortened).uppercased())")
                Button { engine.endBreakEarly() } label: {
                    Text("BACK TO WORK →").font(mono(16, .heavy)).tracking(3)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .foregroundColor(.ink).background(Color.signal)
                }
                .buttonStyle(.plain)
            } else {
                label("WORK · ROUND \(engine.round) OF \(engine.rounds)")
            }
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
        guard engine.exitOpensIn == 0 else { return }
        if phrase.lowercased().trimmingCharacters(in: .whitespaces) == unlockPhrase {
            phrase = ""
            engine.bail()
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
