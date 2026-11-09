import AppKit
import ServiceManagement

private let tickerURL = URL(string: "https://api.luno.com/api/1/ticker?pair=XBTMYR")!
private let tradeURL = URL(string: "https://www.luno.com/trade/markets/XBTMYR")!
private let refreshInterval: TimeInterval = 15

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
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")

    private var lastPriceText: String?
    private var timer: Timer?
    private var isFetching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        for item in [lastItem, bidItem, askItem, volumeItem, statusLine] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(actionItem("Refresh Now", #selector(refresh), key: "r"))
        menu.addItem(actionItem("Open Luno", #selector(openLuno), key: "o"))
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
        setTitle(symbol: "₿", symbolColor: .systemOrange, text: price)
        lastItem.title = "Last: \(Self.ringgit(ticker.lastTrade, decimals: 2))"
        bidItem.title = "Bid: \(Self.ringgit(ticker.bid, decimals: 2))"
        askItem.title = "Ask: \(Self.ringgit(ticker.ask, decimals: 2))"
        volumeItem.title = "24h volume: \(ticker.volume) BTC"
        statusLine.title = "Updated \(Self.time.string(from: Date()))"
    }

    // Keeps the last good price on screen, flagged as stale, rather than blanking it.
    private func showFailure(_ error: Error) {
        setTitle(symbol: "⚠︎", symbolColor: .labelColor, text: lastPriceText ?? "BTC")
        statusLine.title = "Failed \(Self.time.string(from: Date())): \(error.localizedDescription)"
    }

    private func setTitle(symbol: String, symbolColor: NSColor, text: String) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString(
            string: symbol,
            attributes: [.font: font, .foregroundColor: symbolColor])
        title.append(NSAttributedString(
            string: " \(text)",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
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
