import Foundation

enum PriceZone: String {
    case extremeHigh, high, neutral, low, extremeLow
}

/// Rolling 24 hours of prices recorded by the app, because Luno's public API has no high or low.
/// Time when the app wasn't running is missing, so highs and lows from those gaps aren't seen.
struct PriceHistory: Codable, Equatable {
    private struct Bucket: Codable, Equatable {
        let minute: Int
        var low: Double
        var high: Double
    }

    static let minimumMinutes = 360
    static let minimumRangeFraction = 0.01
    private static let windowMinutes = 24 * 60

    private var buckets: [Bucket] = []

    var bucketCount: Int { buckets.count }
    var low: Double? { buckets.map(\.low).min() }
    var high: Double? { buckets.map(\.high).max() }

    mutating func record(price: Double, at date: Date) {
        let minute = Int(date.timeIntervalSince1970 / 60)
        if let last = buckets.indices.last, buckets[last].minute == minute {
            buckets[last].low = min(buckets[last].low, price)
            buckets[last].high = max(buckets[last].high, price)
        } else {
            buckets.append(Bucket(minute: minute, low: price, high: price))
        }
        buckets.removeAll { $0.minute <= minute - Self.windowMinutes }
    }

    /// Requires enough real readings, and a range wide enough that its extremes mean something.
    func isReady(for price: Double) -> Bool {
        guard buckets.count >= Self.minimumMinutes, let low, let high, price > 0 else { return false }
        return (high - low) / price >= Self.minimumRangeFraction
    }

    func zone(for price: Double) -> PriceZone {
        guard isReady(for: price), let low, let high else { return .neutral }
        let position = (price - low) / (high - low)
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
