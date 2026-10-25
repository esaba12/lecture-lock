import Foundation

// Checks for the pure functions: break rounds, schedule firing, streaks and formatting.
// Run with ./test.sh. Nothing here touches the lock, so it never locks the Mac.

var failures = 0

func check<T: Equatable>(_ got: T, _ want: T, _ what: String, line: Int = #line) {
    if got != want {
        failures += 1
        print("FAIL line \(line): \(what): got \(got), want \(want)")
    }
}

let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

func breakTests() {
    let min = 60.0
    // Session end and round count, from the spec's examples.
    for (total, plan, end, rounds) in [
        (120.0, BreakPlan.long, 110.0, 2),  // W50 B10 W50, trailing break dropped
        (90, .short, 85, 3),                // W25 B5 ×3, last break dropped
        (100, .long, 100, 2),               // W50 B10 W40
        (30, .short, 25, 1),                // W25, no trailing break
        (60, .long, 50, 1),
        (10, .short, 10, 1),                // shorter than one work block
        (45, .none, 45, 1),
    ] {
        let p = sessionPhase(total: total * min, plan: plan, elapsed: 0)
        check(p.sessionEnd, end * min, "\(Int(total)) min \(plan.title) ends at")
        check(p.rounds, rounds, "\(Int(total)) min \(plan.title) rounds")
    }

    // Where a 120-min 50+10 session stands over time.
    func at(_ m: Double) -> SessionPhase { sessionPhase(total: 120 * min, plan: .long, elapsed: m * min) }
    check(at(0), SessionPhase(onBreak: false, round: 1, rounds: 2, phaseEnd: 50 * min, sessionEnd: 110 * min), "start")
    check(at(49.9).onBreak, false, "just before the break")
    check(at(50), SessionPhase(onBreak: true, round: 1, rounds: 2, phaseEnd: 60 * min, sessionEnd: 110 * min), "break starts")
    check(at(60), SessionPhase(onBreak: false, round: 2, rounds: 2, phaseEnd: 110 * min, sessionEnd: 110 * min), "round 2")
    check(at(110).onBreak, false, "no break at the end")
    check(at(500).phaseEnd, 110 * min, "elapsed past the end clamps")
    check(at(-5).round, 1, "negative elapsed clamps")
    check(sessionPhase(total: 0, plan: .short, elapsed: 0).sessionEnd, 0, "zero total")
}

func scheduleTests() {
    let mon = date(2026, 10, 26)  // a Monday
    check(utc.component(.weekday, from: mon), 2, "test date is a Monday")
    let s = Schedule(days: [2, 4], hour: 10, minute: 0, appID: "com.google.Chrome", minutes: 75)
    let id = s.id.uuidString
    func due(_ now: Date, _ last: [String: String] = [:]) -> Bool {
        !dueSchedules([s], now: now, lastFired: last, calendar: utc).isEmpty
    }
    check(due(date(2026, 10, 26, 10, 0, 0)), true, "fires at the start")
    check(due(date(2026, 10, 26, 10, 1, 59)), true, "fires up to 2 min late")
    check(due(date(2026, 10, 26, 10, 2, 0)), false, "not 2 min after")
    check(due(date(2026, 10, 26, 9, 59, 59)), false, "not before")
    check(due(date(2026, 10, 27, 10, 0, 30)), false, "not on Tuesday")
    check(due(date(2026, 10, 28, 10, 0, 30)), true, "Wednesday")
    check(due(date(2026, 10, 26, 10, 0, 30), [id: "2026-10-26"]), false, "already fired today")
    check(due(date(2026, 10, 26, 10, 0, 30), [id: "2026-10-21"]), true, "fired last week")
    check(dayKey(date(2026, 3, 7, 23, 59), calendar: utc), "2026-03-07", "day key")
}

func historyTests() {
    func session(_ d: Int, finished: Bool = true, minutes: Double = 30) -> Session {
        let start = date(2026, 10, d, 12)
        return Session(start: start, end: start.addingTimeInterval(minutes * 60), mode: "timer", app: "Chrome", finished: finished)
    }
    let now = date(2026, 10, 25, 18)
    check(streakDays([], now: now, utc), 0, "no history")
    check(streakDays([session(25), session(24), session(23)], now: now, utc), 3, "three days in a row")
    check(streakDays([session(24), session(23)], now: now, utc), 2, "nothing yet today keeps yesterday's streak")
    check(streakDays([session(25), session(23)], now: now, utc), 1, "a gap ends the streak")
    check(streakDays([session(25), session(24, finished: false)], now: now, utc), 1, "emergency exits don't count")
    check(streakDays([session(22)], now: now, utc), 0, "old streak is over")
    check(minutesLocked([session(25), session(24, minutes: 45), session(10)], since: startOfWeek(now, utc)), 75, "minutes this week")
    check(hoursMinutes(45), "45M", "minutes")
    check(hoursMinutes(80), "1H 20M", "hours")
    check(clock(65), "01:05", "clock")
    check(clock(3725), "1:02:05", "clock with hours")
}

@main
enum LogicTests {
    static func main() {
        breakTests()
        scheduleTests()
        historyTests()
        if failures > 0 {
            print("\(failures) failed")
            exit(1)
        }
        print("All logic tests passed")
    }
}
