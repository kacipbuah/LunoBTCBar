# LunoBTCBar

Native macOS menu bar app that shows the Luno BTC/MYR price next to the clock.

```
₿ RM 305,137
```

- Refreshes every 15 seconds from Luno's public [ticker API](https://api.luno.com/api/1/ticker?pair=XBTMYR), and immediately after the Mac wakes
- Menu shows last price, bid, ask, 24h volume and last update time
- Keeps the last price with a `⚠︎` marker if a fetch fails
- Colours the price by where it sits in the rolling 24h range: green in the top 10%, red in the bottom 10%
- Blinks for 30 seconds on entering the top or bottom 5% (Blink Alerts in the menu turns this off, and it follows Reduce Motion)

Luno's public API has no high or low, so the app records its own. Colours start after 6 hours of readings and need a range of at least 1%. Moves while the app isn't running or the Mac is asleep aren't seen.
- Optional Start at Login toggle
- No API key, no dependencies, no Dock icon

Not affiliated with Luno.

## Build and install

Requires macOS 13 or later and the Xcode command line tools.

```sh
./build.sh
```

This compiles the app, installs it to `~/Applications/LunoBTCBar.app` and launches it.

## SwiftBar plugin

`swiftbar/luno-btc.30s.py` is a lighter alternative that runs under [SwiftBar](https://github.com/swiftbar/SwiftBar) instead of as a native app.

```
RM293,281 ↓3.9 ↑0.2
```

- `↓` (red) is how far the price sits below today's high, in percent
- `↑` (green) is how far it sits above today's low, in percent
- "Today" starts at 00:00 MYT. Unlike the native app, the high and low come from Luno's public trades endpoint, so they are exact from the first run, including moves while the Mac was asleep
- The dropdown shows bid/ask, open, high and low with times, position in the day's range and 24h volume
- Refreshes every 30 seconds and caches the day's state in `~/.cache/luno-btc-day.json`

Install:

```sh
brew install --cask swiftbar
mkdir -p ~/SwiftBar && cp swiftbar/luno-btc.30s.py ~/SwiftBar/
```

Then point SwiftBar's plugin folder at `~/SwiftBar`. Uses `/usr/bin/python3` with no extra packages.
