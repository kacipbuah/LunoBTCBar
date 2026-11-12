import AppKit
import ServiceManagement
import os

private let tickerURL = URL(string: "https://api.luno.com/api/1/ticker?pair=XBTMYR")!
private let tradesURL = URL(string: "https://api.luno.com/api/1/trades")!
private let tradeURL = URL(string: "https://www.luno.com/trade/markets/XBTMYR")!
private let refreshInterval: TimeInterval = 15
private let blinkDuration: TimeInterval = 30
private let blinkAlertsKey = "blinkAlerts"
/// Upper bound on trade pages per refresh; a busy day needs about 30 on first launch.
private let maxTradePages = 80

struct Ticker: Decodable {
    let timestamp: Int64
    let bid: String
    let ask: String
    let lastTrade: String
    let volume: String

    enum CodingKeys: String, CodingKey {
        case timestamp, bid, ask
        case lastTrade = "last_trade"
        case volume = "rolling_24_hour_volume"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private let lastItem = NSMenuItem(title: "Last: —", action: nil, keyEquivalent: "")
    private let bidItem = NSMenuItem(title: "Bid: —", action: nil, keyEquivalent: "")
    private let askItem = NSMenuItem(title: "Ask: —", action: nil, keyEquivalent: "")
    private let volumeItem = NSMenuItem(title: "24h volume: —", action: nil, keyEquivalent: "")
    private let statusLine = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    private let dayHeader = NSMenuItem(title: "Today since 00:00 MYT", action: nil, keyEquivalent: "")
    private let openItem = NSMenuItem(title: "Open: —", action: nil, keyEquivalent: "")
    private let highItem = NSMenuItem(title: "High: —", action: nil, keyEquivalent: "")
    private let lowItem = NSMenuItem(title: "Low: —", action: nil, keyEquivalent: "")
    private let rangeItem = NSMenuItem(title: "Range: —", action: nil, keyEquivalent: "")
    private let blinkItem = NSMenuItem(title: "Blink Alerts", action: #selector(toggleBlink), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let logger = Logger(subsystem: "com.izwan.LunoBTCBar", category: "Price")

    private var lastPrice: Double?
    private var timer: Timer?
    private var isFetching = false

    private var day = AppDelegate.loadDay()
    private var blinkPolicy = BlinkPolicy()
    private var zone = PriceZone.neutral
    private var blinkTimer: Timer?
    private var blinkEnds = Date.distantPast
    private var blinkDimmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [blinkAlertsKey: true])
        statusItem.button?.attributedTitle = NSAttributedString(
            string: "RM …", attributes: [.font: Self.titleFont])
        buildMenu()

        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Timers pause during sleep, so fetch straight away on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.didWakeNotification, object: nil)

        refresh()
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Luno BTC/MYR", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for item in [lastItem, bidItem, askItem, volumeItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for item in [dayHeader, openItem, highItem, lowItem, rangeItem, statusLine] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(actionItem("Refresh Now", #selector(refresh), key: "r"))
        menu.addItem(actionItem("Open Luno", #selector(openLuno), key: "o"))
        blinkItem.target = self
        blinkItem.state = blinkAlertsEnabled ? .on : .off
        menu.addItem(blinkItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit", #selector(quit), key: "q"))

        statusItem.menu = menu
        updateLoginState()
    }

    private func actionItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func refresh() {
        guard !isFetching else { return }
        isFetching = true
        Task {
            defer { isFetching = false }
            do {
                try await syncTrades()
                let data = try await fetch(tickerURL)
                show(try JSONDecoder().decode(Ticker.self, from: data))
            } catch {
                showFailure(error)
            }
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Pages through today's trades since the last one seen, starting a new range at midnight.
    private func syncTrades() async throws {
        let start = DayRange.dayStart(for: Date())
        if day.dayStart != start {
            day = DayRange(dayStart: start)
        }
        let before = day
        // Keep pages already fetched even if a later page fails.
        defer { if day != before { saveDay() } }
        for _ in 0..<maxTradePages {
            var components = URLComponents(url: tradesURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "pair", value: "XBTMYR"),
                URLQueryItem(name: "since", value: String(day.since)),
            ]
            let data = try await fetch(components.url!)
            let page = try JSONDecoder().decode(TradesPage.self, from: data)
            guard day.apply(page.trades ?? []) else { break }
        }
    }

    private func show(_ ticker: Ticker) {
        guard let price = Double(ticker.lastTrade) else {
            showFailure(URLError(.cannotParseResponse))
            return
        }
        lastPrice = price
        updateZone(price: price, at: ticker.timestamp)
        renderPrice()
        lastItem.title = "Last: \(Self.ringgit(price, decimals: 2))"
        bidItem.title = "Bid: \(Self.ringgit(Double(ticker.bid), decimals: 2))"
        askItem.title = "Ask: \(Self.ringgit(Double(ticker.ask), decimals: 2))"
        volumeItem.title = "24h volume: \(ticker.volume) BTC"
        statusLine.title = "Updated \(Self.time.string(from: Date()))"
    }

    // Keeps the last good price on screen, flagged as stale, rather than blanking it.
    private func showFailure(_ error: Error) {
        stopBlinking()
        let text = lastPrice.map { "⚠︎ RM\(Self.compact($0))" } ?? "⚠︎ BTC"
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text, attributes: [.font: Self.titleFont, .foregroundColor: NSColor.labelColor])
        statusLine.title = "Failed \(Self.time.string(from: Date())): \(error.localizedDescription)"
    }

    private func updateZone(price: Double, at timestamp: Int64) {
        let now = Date()
        let wasReady = day.isReady(for: price)
        let isNewHigh = wasReady && price > (day.high ?? .infinity)
        let isNewLow = wasReady && price < (day.low ?? -.infinity)

        let before = day
        day.record(price: price, at: timestamp)
        if day != before {
            saveDay()
        }

        let newZone = day.zone(for: price)
        if newZone != zone {
            logger.notice("zone \(newZone.rawValue, privacy: .public) at \(price, privacy: .public)")
        }
        zone = newZone

        let shouldBlink = blinkPolicy.update(zone: newZone, isNewHigh: isNewHigh, isNewLow: isNewLow, now: now)
        if newZone != .extremeHigh && newZone != .extremeLow {
            stopBlinking()
        } else if shouldBlink && canBlink {
            startBlinking(until: now.addingTimeInterval(blinkDuration))
        }
        updateDayItems(price: price)
    }

    private func updateDayItems(price: Double) {
        let fromOpen = day.percentFromOpen(price).map { " (\(Self.signed($0)))" } ?? ""
        openItem.title = "Open: \(Self.ringgit(day.open, decimals: 2))\(fromOpen)"
        highItem.title = "High: \(Self.ringgit(day.high, decimals: 2)) at \(Self.clock(day.highAt))"
            + (day.percentBelowHigh(price).map { "  ↓\(Self.percent($0, digits: 2))" } ?? "")
        lowItem.title = "Low: \(Self.ringgit(day.low, decimals: 2)) at \(Self.clock(day.lowAt))"
            + (day.percentAboveLow(price).map { "  ↑\(Self.percent($0, digits: 2))" } ?? "")
        if let high = day.high, let low = day.low, let position = day.position(of: price) {
            rangeItem.title = "Range: \(Self.ringgit(high - low, decimals: 0)), price at \(Int((position * 100).rounded()))%"
        } else {
            rangeItem.title = "Range: —"
        }
    }

    // systemRed leans orange, and pure red is harsh on a dark menu bar,
    // so this is a soft crimson, darker on a light menu bar.
    private static let softRed = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.95, green: 0.30, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.10, blue: 0.16, alpha: 1)
    }

    private static let titleFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    /// Menu bar title: `RM293,281 ↓3.9 ↑0.2`, with the distance from today's high in red
    /// and from today's low in green. The price dims while blinking.
    private func renderPrice() {
        guard let price = lastPrice else { return }
        let priceColor = blinkDimmed ? NSColor.labelColor.withAlphaComponent(0.25) : .labelColor
        let title = NSMutableAttributedString(
            string: "RM\(Self.compact(price))",
            attributes: [.font: Self.titleFont, .foregroundColor: priceColor])
        if let below = day.percentBelowHigh(price) {
            title.append(NSAttributedString(
                string: " ↓\(Self.percent(below, digits: 1, sign: false))",
                attributes: [.font: Self.titleFont, .foregroundColor: Self.softRed]))
        }
        if let above = day.percentAboveLow(price) {
            title.append(NSAttributedString(
                string: " ↑\(Self.percent(above, digits: 1, sign: false))",
                attributes: [.font: Self.titleFont, .foregroundColor: NSColor.systemGreen]))
        }
        statusItem.button?.attributedTitle = title
    }

    private var blinkAlertsEnabled: Bool {
        UserDefaults.standard.bool(forKey: blinkAlertsKey)
    }

    private var canBlink: Bool {
        blinkAlertsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func startBlinking(until end: Date) {
        blinkEnds = end
        guard blinkTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.blinkTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func blinkTick() {
        guard Date() < blinkEnds, canBlink else {
            stopBlinking()
            return
        }
        blinkDimmed.toggle()
        renderPrice()
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        if blinkDimmed {
            blinkDimmed = false
            renderPrice()
        }
    }

    @objc private func toggleBlink() {
        let enabled = !blinkAlertsEnabled
        UserDefaults.standard.set(enabled, forKey: blinkAlertsKey)
        blinkItem.state = enabled ? .on : .off
    }

    private static var dayURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LunoBTCBar/day.json")
    }

    private static func loadDay() -> DayRange {
        let today = DayRange.dayStart(for: Date())
        guard let data = try? Data(contentsOf: dayURL),
              let day = try? JSONDecoder().decode(DayRange.self, from: data),
              day.dayStart == today else {
            return DayRange(dayStart: today)
        }
        return day
    }

    private func saveDay() {
        let url = Self.dayURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(day).write(to: url, options: .atomic)
        } catch {
            logger.error("day range not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updateLoginState() {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        updateLoginState()
    }

    @objc private func openLuno() {
        NSWorkspace.shared.open(tradeURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = DayRange.timeZone
        return formatter
    }()

    private static func clock(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "—" }
        return hourMinute.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    private static func number(_ value: Double, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_MY")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func compact(_ value: Double) -> String {
        number(value, decimals: 0)
    }

    private static func ringgit(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "—" }
        return "RM \(number(value, decimals: decimals))"
    }

    private static func percent(_ value: Double, digits: Int, sign: Bool = true) -> String {
        String(format: "%.\(digits)f", value) + (sign ? "%" : "")
    }

    private static func signed(_ value: Double) -> String {
        String(format: "%+.2f%%", value)
    }
}

// NSApplication.delegate is weak, so this global keeps the delegate alive.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
