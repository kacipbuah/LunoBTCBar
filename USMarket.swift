import Foundation

/// NYSE regular session times, used to warn shortly before the US cash open and close,
/// when BTC often moves on ETF and equity flows. Times are worked out in New York time,
/// so daylight saving is handled by the calendar.
enum USMarket {
    static let timeZone = TimeZone(identifier: "America/New_York")!
    /// How long before each event to warn: 10 minutes before the open, 30 before the close.
    static func leadTime(for kind: Kind) -> TimeInterval {
        kind == .open ? 10 * 60 : 30 * 60
    }

    enum Kind: String {
        case open, close
    }

    struct Event: Equatable {
        let kind: Kind
        let date: Date
    }

    /// NYSE full-day holidays, as yyyy-MM-dd in New York.
    static let holidays: Set<String> = [
        "2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25",
        "2026-06-19", "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25",
        "2027-01-01", "2027-01-18", "2027-02-15", "2027-03-26", "2027-05-31",
        "2027-06-18", "2027-07-05", "2027-09-06", "2027-11-25", "2027-12-24",
    ]

    /// Days the NYSE closes at 13:00 New York time.
    static let earlyCloses: Set<String> = [
        "2026-11-27", "2026-12-24",
        "2027-11-26",
    ]

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The open and close on the New York trading day containing `date`, or none on
    /// weekends and holidays.
    static func session(on date: Date) -> (open: Date, close: Date)? {
        let calendar = calendar
        let weekday = calendar.component(.weekday, from: date)
        let key = dayKey.string(from: date)
        guard weekday != 1, weekday != 7, !holidays.contains(key) else { return nil }
        let midnight = calendar.startOfDay(for: date)
        let closeHour = earlyCloses.contains(key) ? 13 : 16
        guard let open = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: midnight),
              let close = calendar.date(bySettingHour: closeHour, minute: 0, second: 0, of: midnight)
        else { return nil }
        return (open, close)
    }

    /// The next open or close strictly after `now`, looking up to two weeks ahead.
    static func nextEvent(after now: Date) -> Event? {
        let calendar = calendar
        var day = now
        for _ in 0..<14 {
            if let session = session(on: day) {
                if session.open > now { return Event(kind: .open, date: session.open) }
                if session.close > now { return Event(kind: .close, date: session.close) }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { return nil }
            day = next
        }
        return nil
    }

    /// The event to warn about now: one starting within its lead time. An event already
    /// warned about, or one missed while the Mac slept, is not returned.
    static func dueAlert(now: Date, lastAlerted: Date?) -> Event? {
        guard let event = nextEvent(after: now),
              event.date.timeIntervalSince(now) <= leadTime(for: event.kind),
              event.date != lastAlerted else { return nil }
        return event
    }
}
