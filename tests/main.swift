import Foundation

var failures = 0

func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL line \(line): \(name)")
    }
}

let start = Date(timeIntervalSince1970: 1_800_000_000)

let dayStart = DayRange.dayStart(for: start)

func trade(_ secondsAfterMidnight: Int64, _ price: Double) -> Trade {
    Trade(timestamp: dayStart + secondsAfterMidnight * 1000, price: String(price))
}

// Midnight is in Malaysia time
do {
    let formatter = DateFormatter()
    formatter.timeZone = DayRange.timeZone
    formatter.dateFormat = "HH:mm:ss"
    let midnight = Date(timeIntervalSince1970: Double(dayStart) / 1000)
    check(formatter.string(from: midnight) == "00:00:00", "day starts at 00:00 MYT")
    check(dayStart <= Int64(start.timeIntervalSince1970 * 1000), "day start is not in the future")
    check(Int64(start.timeIntervalSince1970 * 1000) - dayStart < 86_400_000, "day start is within 24 hours")
}

// Open, high and low from trades, in any order
do {
    var d = DayRange(dayStart: dayStart)
    let more = d.apply([trade(300, 305_000), trade(60, 300_000), trade(600, 310_000), trade(900, 295_000)])
    check(!more, "a short page means no more pages")
    check(d.open == 300_000, "open is the earliest trade")
    check(d.high == 310_000 && d.highAt == dayStart + 600_000, "high and its time")
    check(d.low == 295_000 && d.lowAt == dayStart + 900_000, "low and its time")
    check(d.since == dayStart + 900_001, "next page starts after the newest trade")
}

// Paging
do {
    var d = DayRange(dayStart: dayStart)
    let page = (0..<100).map { trade(Int64($0), 300_000 + Double($0)) }
    check(d.apply(page), "a full page means more may follow")
    check(!d.apply([]), "an empty page stops")
    check(d.since == dayStart + 99_001, "an empty page keeps since")
}

// Trades from before midnight are ignored
do {
    var d = DayRange(dayStart: dayStart)
    _ = d.apply([Trade(timestamp: dayStart - 1, price: "999999"), trade(10, 300_000)])
    check(d.high == 300_000 && d.open == 300_000, "yesterday's trade does not count")
}

// Percentages
do {
    var d = DayRange(dayStart: dayStart)
    _ = d.apply([trade(1, 300_000), trade(2, 310_000), trade(3, 290_000)])
    let below = d.percentBelowHigh(300_000)!
    check(abs(below - 3.2258) < 0.001, "percent below high is relative to the high")
    check(abs(d.percentAboveLow(300_000)! - 3.4483) < 0.001, "percent above low is relative to the low")
    check(d.percentBelowHigh(310_000) == 0, "at the high is 0 below")
    check(d.percentAboveLow(290_000) == 0, "at the low is 0 above")
    check(abs(d.percentFromOpen(303_000)! - 1.0) < 0.0001, "change from open")
    check(DayRange(dayStart: dayStart).percentBelowHigh(300_000) == nil, "empty range has no percent")
}

// Ticker readings extend the range
do {
    var d = DayRange(dayStart: dayStart)
    _ = d.apply([trade(1, 300_000)])
    d.record(price: 312_000, at: dayStart + 5_000)
    check(d.high == 312_000 && d.highAt == dayStart + 5_000, "ticker price can set a new high")
    check(d.since == dayStart + 1_001, "ticker readings do not move since")
}

// Zones
do {
    var d = DayRange(dayStart: dayStart)
    _ = d.apply([trade(1, 300_000), trade(2, 310_000)])
    check(d.zone(for: 309_600) == .extremeHigh, "top 5% is extreme high")
    check(d.zone(for: 309_200) == .high, "top 5-10% is high")
    check(d.zone(for: 305_000) == .neutral, "middle is neutral")
    check(d.zone(for: 300_800) == .low, "bottom 5-10% is low")
    check(d.zone(for: 300_400) == .extremeLow, "bottom 5% is extreme low")

    var narrow = DayRange(dayStart: dayStart)
    _ = narrow.apply([trade(1, 300_000), trade(2, 302_000)])
    check(narrow.zone(for: 301_990) == .neutral, "range under 1% is neutral")
}

// Persistence
do {
    var d = DayRange(dayStart: dayStart)
    _ = d.apply([trade(1, 300_000), trade(2, 310_000)])
    let decoded = try! JSONDecoder().decode(DayRange.self, from: JSONEncoder().encode(d))
    check(decoded == d, "day range survives encode and decode")
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

// US market session times in Malaysia time
do {
    let iso = ISO8601DateFormatter()
    func myt(_ s: String) -> Date { iso.date(from: s + "+08:00")! }

    // Monday 16 Nov 2026, EST: open 22:30 MYT, close 05:00 MYT next day.
    let s = USMarket.session(on: myt("2026-11-16T23:00:00"))
    check(s?.open == myt("2026-11-16T22:30:00"), "winter open is 22:30 MYT")
    check(s?.close == myt("2026-11-17T05:00:00"), "winter close is 05:00 MYT")

    // EDT in July: open 21:30 MYT.
    check(USMarket.session(on: myt("2026-07-15T22:00:00"))?.open == myt("2026-07-15T21:30:00"),
          "summer open is 21:30 MYT")

    check(USMarket.session(on: myt("2026-11-21T23:00:00")) == nil, "no session on Saturday")
    check(USMarket.session(on: myt("2026-11-26T23:00:00")) == nil, "no session on Thanksgiving")
    check(USMarket.session(on: myt("2026-11-27T23:00:00"))?.close == myt("2026-11-28T02:00:00"),
          "early close at 13:00 ET")

    check(USMarket.dueAlert(now: myt("2026-11-16T22:19:00"), lastAlerted: nil) == nil, "11 minutes before: not yet")
    let due = USMarket.dueAlert(now: myt("2026-11-16T22:20:30"), lastAlerted: nil)
    check(due == USMarket.Event(kind: .open, date: myt("2026-11-16T22:30:00")), "10 minutes before open warns")
    check(USMarket.dueAlert(now: myt("2026-11-16T22:25:00"), lastAlerted: due?.date) == nil, "warns once")
    check(USMarket.dueAlert(now: myt("2026-11-17T04:29:00"), lastAlerted: due?.date) == nil,
          "31 minutes before close: not yet")
    check(USMarket.dueAlert(now: myt("2026-11-17T04:30:30"), lastAlerted: due?.date)?.kind == .close,
          "30 minutes before close warns")
    check(USMarket.dueAlert(now: myt("2026-11-16T22:31:00"), lastAlerted: nil) == nil, "no warning after open")

    // Friday close, then next event is Monday open.
    check(USMarket.nextEvent(after: myt("2026-11-21T06:00:00")) == USMarket.Event(kind: .open, date: myt("2026-11-23T22:30:00")),
          "after Friday close the next event is Monday open")
}

if failures == 0 {
    print("All tests passed")
} else {
    print("\(failures) test(s) failed")
    exit(1)
}
