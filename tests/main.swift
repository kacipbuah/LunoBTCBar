import Foundation

var failures = 0

func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL line \(line): \(name)")
    }
}

let start = Date(timeIntervalSince1970: 1_800_000_000)

/// A history with one reading a minute for `minutes` minutes, spanning low...high.
func history(minutes: Int, low: Double, high: Double) -> PriceHistory {
    var result = PriceHistory()
    for minute in 0..<minutes {
        let price = minute % 2 == 0 ? low : high
        result.record(price: price, at: start.addingTimeInterval(Double(minute) * 60))
    }
    return result
}

let afterSixHours = start.addingTimeInterval(360 * 60)

// Range and zones
do {
    let h = history(minutes: 360, low: 300_000, high: 310_000)
    check(h.low == 300_000, "low is lowest recorded price")
    check(h.high == 310_000, "high is highest recorded price")
    check(h.zone(for: 309_600) == .extremeHigh, "top 5% is extreme high")
    check(h.zone(for: 309_200) == .high, "top 5-10% is high")
    check(h.zone(for: 305_000) == .neutral, "middle is neutral")
    check(h.zone(for: 300_800) == .low, "bottom 5-10% is low")
    check(h.zone(for: 300_400) == .extremeLow, "bottom 5% is extreme low")
    check(h.zone(for: 309_500) == .extremeHigh, "exactly 95% is extreme high")
    check(h.zone(for: 300_500) == .extremeLow, "exactly 5% is extreme low")
}

// Not enough data means no colour
do {
    check(history(minutes: 359, low: 300_000, high: 310_000).zone(for: 309_900) == .neutral,
          "under 6 hours of readings is neutral")
    check(history(minutes: 360, low: 300_000, high: 302_000).zone(for: 301_990) == .neutral,
          "range under 1% is neutral")
    check(PriceHistory().zone(for: 300_000) == .neutral, "empty history is neutral")
}

// Sleep gaps don't count as recorded time
do {
    var h = PriceHistory()
    h.record(price: 300_000, at: start)
    h.record(price: 310_000, at: start.addingTimeInterval(7 * 3600))
    check(!h.isReady(for: 310_000), "two readings 7 hours apart are not 6 hours of data")
}

// Rolling 24 hour window
do {
    var h = history(minutes: 360, low: 300_000, high: 310_000)
    h.record(price: 305_000, at: start.addingTimeInterval(31 * 3600))
    check(h.low == 305_000 && h.high == 305_000, "readings older than 24 hours are dropped")
}

// Readings in the same minute merge
do {
    var h = PriceHistory()
    h.record(price: 300_000, at: start)
    h.record(price: 310_000, at: start.addingTimeInterval(15))
    h.record(price: 290_000, at: start.addingTimeInterval(30))
    check(h.bucketCount == 1, "same minute uses one bucket")
    check(h.low == 290_000 && h.high == 310_000, "bucket keeps low and high")
}

// Persistence
do {
    let h = history(minutes: 3, low: 300_000, high: 310_000)
    let decoded = try! JSONDecoder().decode(PriceHistory.self, from: JSONEncoder().encode(h))
    check(decoded == h, "history survives encode and decode")
}

// Blink policy
do {
    var p = BlinkPolicy()
    check(p.update(zone: .extremeHigh, isNewHigh: false, isNewLow: false, now: start),
          "entering extreme high blinks")
    check(!p.update(zone: .extremeHigh, isNewHigh: false, isNewLow: false, now: start.addingTimeInterval(15)),
          "staying in extreme high does not blink again")
    check(!p.update(zone: .high, isNewHigh: false, isNewLow: false, now: start.addingTimeInterval(30)),
          "dropping to high does not blink")
    check(!p.update(zone: .extremeHigh, isNewHigh: false, isNewLow: false, now: start.addingTimeInterval(45)),
          "returning from high zone does not blink again")
    check(!p.update(zone: .neutral, isNewHigh: false, isNewLow: false, now: start.addingTimeInterval(60)),
          "neutral does not blink")
    check(p.update(zone: .extremeHigh, isNewHigh: false, isNewLow: false, now: start.addingTimeInterval(75)),
          "re-entering after leaving the zone blinks")
}

do {
    var p = BlinkPolicy()
    check(p.update(zone: .extremeLow, isNewHigh: false, isNewLow: false, now: start), "entering extreme low blinks")
    check(!p.update(zone: .low, isNewHigh: false, isNewLow: false, now: start.addingTimeInterval(15)),
          "low zone does not blink")
    check(!p.update(zone: .extremeLow, isNewHigh: false, isNewLow: false, now: start.addingTimeInterval(30)),
          "returning from low zone does not blink again")
    check(p.update(zone: .extremeHigh, isNewHigh: false, isNewLow: false, now: start.addingTimeInterval(45)),
          "the high side is armed separately")
}

do {
    var p = BlinkPolicy()
    _ = p.update(zone: .extremeHigh, isNewHigh: false, isNewLow: false, now: start)
    check(!p.update(zone: .extremeHigh, isNewHigh: true, isNewLow: false, now: start.addingTimeInterval(60)),
          "a new high inside 5 minutes does not blink again")
    check(p.update(zone: .extremeHigh, isNewHigh: true, isNewLow: false, now: start.addingTimeInterval(301)),
          "a new high after 5 minutes blinks again")
    check(!p.update(zone: .extremeHigh, isNewHigh: false, isNewLow: false, now: start.addingTimeInterval(700)),
          "no new high means no blink")
}

if failures == 0 {
    print("All tests passed")
} else {
    print("\(failures) test(s) failed")
    exit(1)
}
