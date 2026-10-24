import Foundation

// MARK: - Schedules

/// A timer lock that starts by itself, e.g. every Mon/Wed at 10:00 in Chrome for 75 min.
struct Schedule: Codable, Identifiable, Equatable {
    var id = UUID()
    var days: Set<Int>      // Calendar weekdays, 1 = Sunday … 7 = Saturday
    var hour: Int
    var minute: Int
    var appID: String       // bundle id
    var url = ""            // "" = none
    var minutes: Int
}

/// Weekdays in display order, Monday first.
let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

/// "2026-10-24" in `calendar`'s time zone: the key a schedule's last fire is stored under.
func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}

/// Schedules that should fire at `now`: on one of their days, within 2 minutes of their start,
/// and not already fired today. Pure, so the 30s check can't double-fire or fire late.
func dueSchedules(_ schedules: [Schedule], now: Date, lastFired: [String: String], calendar: Calendar = .current) -> [Schedule] {
    let c = calendar.dateComponents([.weekday, .hour, .minute, .second], from: now)
    let secs = (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    let today = dayKey(now, calendar: calendar)
    return schedules.filter { s in
        let start = s.hour * 3600 + s.minute * 60
        return s.days.contains(c.weekday ?? 0) && secs >= start && secs < start + 120
            && lastFired[s.id.uuidString] != today
    }
}
