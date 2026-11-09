import AppKit
import ServiceManagement
import os

private let tickerURL = URL(string: "https://api.luno.com/api/1/ticker?pair=XBTMYR")!
private let tradeURL = URL(string: "https://www.luno.com/trade/markets/XBTMYR")!
private let refreshInterval: TimeInterval = 15
private let blinkDuration: TimeInterval = 30
private let blinkAlertsKey = "blinkAlerts"

struct Ticker: Decodable {
    let bid: String
    let ask: String
    let lastTrade: String
    let volume: String

    enum CodingKeys: String, CodingKey {
        case bid, ask
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
    private let highItem = NSMenuItem(title: "24h High: —", action: nil, keyEquivalent: "")
    private let lowItem = NSMenuItem(title: "24h Low: —", action: nil, keyEquivalent: "")
    private let rangeNote = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let blinkItem = NSMenuItem(title: "Blink Alerts", action: #selector(toggleBlink), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let logger = Logger(subsystem: "com.izwan.LunoBTCBar", category: "Price")

    private var lastPriceText: String?
    private var timer: Timer?
    private var isFetching = false

    private var history = AppDelegate.loadHistory()
    private var blinkPolicy = BlinkPolicy()
    private var zone = PriceZone.neutral
    private var blinkTimer: Timer?
    private var blinkEnds = Date.distantPast
    private var blinkDimmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [blinkAlertsKey: true])
        setTitle(symbol: "₿", symbolColor: .systemOrange, text: "…")
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

        for item in [lastItem, bidItem, askItem, highItem, lowItem, rangeNote, volumeItem, statusLine] {
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
                let (data, response) = try await session.data(from: tickerURL)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                show(try JSONDecoder().decode(Ticker.self, from: data))
            } catch {
                showFailure(error)
            }
        }
    }

    private func show(_ ticker: Ticker) {
        let price = Self.ringgit(ticker.lastTrade, decimals: 0)
        lastPriceText = price
        if let value = Double(ticker.lastTrade) {
            updateZone(price: value)
        }
        renderPrice()
        lastItem.title = "Last: \(Self.ringgit(ticker.lastTrade, decimals: 2))"
        bidItem.title = "Bid: \(Self.ringgit(ticker.bid, decimals: 2))"
        askItem.title = "Ask: \(Self.ringgit(ticker.ask, decimals: 2))"
        volumeItem.title = "24h volume: \(ticker.volume) BTC"
        statusLine.title = "Updated \(Self.time.string(from: Date()))"
    }

    // Keeps the last good price on screen, flagged as stale, rather than blanking it.
    private func showFailure(_ error: Error) {
        stopBlinking()
        setTitle(symbol: "⚠︎", symbolColor: .labelColor, text: lastPriceText ?? "BTC")
        statusLine.title = "Failed \(Self.time.string(from: Date())): \(error.localizedDescription)"
    }

    private func updateZone(price: Double) {
        let now = Date()
        let wasReady = history.isReady(for: price)
        let isNewHigh = wasReady && price > (history.high ?? .infinity)
        let isNewLow = wasReady && price < (history.low ?? -.infinity)
        let bucketsBefore = history.bucketCount

        history.record(price: price, at: now)
        if history.bucketCount != bucketsBefore || isNewHigh || isNewLow {
            saveHistory()
        }

        let newZone = history.zone(for: price)
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
        updateRangeItems(price: price)
    }

    private func updateRangeItems(price: Double) {
        highItem.title = "24h High: \(history.high.map { Self.ringgit(String($0), decimals: 2) } ?? "—")"
        lowItem.title = "24h Low: \(history.low.map { Self.ringgit(String($0), decimals: 2) } ?? "—")"

        let isReady = history.isReady(for: price)
        rangeNote.isHidden = isReady
        if history.bucketCount < PriceHistory.minimumMinutes {
            let minutes = history.bucketCount
            rangeNote.title = "No colours yet: \(minutes / 60)h \(minutes % 60)m of 6h recorded"
        } else if !isReady {
            rangeNote.title = "No colours: 24h range is under 1%"
        }
    }

    private var priceColor: NSColor {
        switch zone {
        case .extremeHigh, .high: return .systemGreen
        case .extremeLow, .low: return Self.softRed
        case .neutral: return .labelColor
        }
    }

    // systemRed leans orange beside the orange symbol, and pure red is harsh on a dark menu bar,
    // so this is a soft crimson, darker on a light menu bar.
    private static let softRed = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.95, green: 0.30, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.10, blue: 0.16, alpha: 1)
    }

    private func renderPrice() {
        guard let lastPriceText else { return }
        setTitle(
            symbol: "₿",
            symbolColor: .systemOrange,
            text: lastPriceText,
            textColor: blinkDimmed ? .labelColor : priceColor)
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

    private static var historyURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LunoBTCBar/history.json")
    }

    private static func loadHistory() -> PriceHistory {
        guard let data = try? Data(contentsOf: historyURL),
              let history = try? JSONDecoder().decode(PriceHistory.self, from: data) else {
            return PriceHistory()
        }
        return history
    }

    private func saveHistory() {
        let url = Self.historyURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: url, options: .atomic)
        } catch {
            logger.error("history not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setTitle(symbol: String, symbolColor: NSColor, text: String, textColor: NSColor = .labelColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString(
            string: symbol,
            attributes: [.font: font, .foregroundColor: symbolColor])
        title.append(NSAttributedString(
            string: " \(text)",
            attributes: [.font: font, .foregroundColor: textColor]))
        statusItem.button?.attributedTitle = title
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

    private static func ringgit(_ value: String, decimals: Int) -> String {
        guard let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            return "RM \(value)"
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_MY")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return "RM \(formatter.string(from: number as NSDecimalNumber) ?? value)"
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
