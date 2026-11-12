import Foundation

enum PriceZone: String {
    case extremeHigh, high, neutral, low, extremeLow
}

/// One trade from Luno's public `/api/1/trades` endpoint.
struct Trade: Decodable, Equatable {
    let timestamp: Int64
    let price: String
}

struct TradesPage: Decodable {
    let trades: [Trade]?
}

/// Today's open, high and low since 00:00 Malaysia time, built from Luno's public trades
/// because the ticker has no high or low. The trades endpoint returns at most 100 trades
/// after `since`, so the range is filled a page at a time and then kept up to date.
struct DayRange: Codable, Equatable {
    static let pageSize = 100
    static let minimumRangeFraction = 0.01
    static let timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!

    /// Milliseconds since 1970 of 00:00 MYT for this day.
    let dayStart: Int64
    /// Next trade timestamp to ask for.
    private(set) var since: Int64
    private(set) var open: Double?
    private(set) var high: Double?
    private(set) var low: Double?
    private(set) var highAt: Int64?
    private(set) var lowAt: Int64?

    init(dayStart: Int64) {
        self.dayStart = dayStart
        self.since = dayStart
    }

    static func dayStart(for date: Date) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return Int64(calendar.startOfDay(for: date).timeIntervalSince1970 * 1000)
    }

    /// Applies one page of trades. Returns true when a full page came back, so more may follow.
    mutating func apply(_ trades: [Trade]) -> Bool {
        let sorted = trades.sorted { $0.timestamp < $1.timestamp }
        for trade in sorted where trade.timestamp >= dayStart {
            guard let price = Double(trade.price) else { continue }
            if open == nil { open = price }
            record(price: price, at: trade.timestamp)
        }
        if let last = sorted.last, last.timestamp >= since {
            since = last.timestamp + 1
        }
        return trades.count >= Self.pageSize
    }

    /// Records a price seen outside the trades feed, such as the ticker's last trade.
    mutating func record(price: Double, at timestamp: Int64) {
        if open == nil { open = price }
        if high == nil || price > high! {
            high = price
            highAt = timestamp
        }
        if low == nil || price < low! {
            low = price
            lowAt = timestamp
        }
    }

    /// How far the price sits below today's high, in percent (0 at the high).
    func percentBelowHigh(_ price: Double) -> Double? {
        guard let high, high > 0 else { return nil }
        return max(0, (high - price) / high * 100)
    }

    /// How far the price sits above today's low, in percent (0 at the low).
    func percentAboveLow(_ price: Double) -> Double? {
        guard let low, low > 0 else { return nil }
        return max(0, (price - low) / low * 100)
    }

    func percentFromOpen(_ price: Double) -> Double? {
        guard let open, open > 0 else { return nil }
        return (price - open) / open * 100
    }

    /// Where the price sits in today's range, 0 at the low and 1 at the high.
    func position(of price: Double) -> Double? {
        guard let low, let high, high > low else { return nil }
        return (price - low) / (high - low)
    }

    /// A range narrower than 1% makes its extremes meaningless, for example just after midnight.
    func isReady(for price: Double) -> Bool {
        guard let low, let high, price > 0 else { return false }
        return (high - low) / price >= Self.minimumRangeFraction
    }

    func zone(for price: Double) -> PriceZone {
        guard isReady(for: price), let position = position(of: price) else { return .neutral }
        switch position {
        case 0.95...: return .extremeHigh
        case 0.90...: return .high
        case ...0.05: return .extremeLow
        case ...0.10: return .low
        default: return .neutral
        }
    }
}

/// Decides when a price should start blinking.
struct BlinkPolicy {
    /// During a steady rally every reading is a new high, so these repeats are limited.
    static let newRecordInterval: TimeInterval = 300

    private var highArmed = true
    private var lowArmed = true
    private var lastBlink: Date?

    /// Returns true when a blink should start. A side re-arms only after the price leaves its
    /// wider 10% zone, so a price hovering on the 5% line doesn't keep triggering.
    mutating func update(zone: PriceZone, isNewHigh: Bool, isNewLow: Bool, now: Date) -> Bool {
        if zone != .extremeHigh && zone != .high { highArmed = true }
        if zone != .extremeLow && zone != .low { lowArmed = true }

        let shouldBlink: Bool
        switch zone {
        case .extremeHigh:
            shouldBlink = highArmed || (isNewHigh && newRecordIntervalPassed(now))
            highArmed = false
        case .extremeLow:
            shouldBlink = lowArmed || (isNewLow && newRecordIntervalPassed(now))
            lowArmed = false
        default:
            shouldBlink = false
        }
        if shouldBlink { lastBlink = now }
        return shouldBlink
    }

    private func newRecordIntervalPassed(_ now: Date) -> Bool {
        guard let lastBlink else { return true }
        return now.timeIntervalSince(lastBlink) >= Self.newRecordInterval
    }
}
