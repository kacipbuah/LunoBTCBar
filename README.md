# LunoBTCBar

Native macOS menu bar app that shows the Luno BTC/MYR price next to the clock.

```
RM293,281 ↓3.9 ↑0.2
```

- `↓` (red) is how far the price sits below today's high, in percent
- `↑` (green) is how far it sits above today's low, in percent
- The price itself turns green in the top 10% of today's range and red in the bottom 10%, once the range is at least 1% wide
- "Today" starts at 00:00 Malaysia time

Luno's public ticker has no high or low, so the app pages through the public [trades endpoint](https://api.luno.com/api/1/trades?pair=XBTMYR) from midnight and keeps the day's open, high and low in `~/Library/Application Support/LunoBTCBar/day.json`. The range is exact from the first launch, including moves while the Mac was asleep or the app wasn't running. A busy day takes about 25 requests on first launch, then one or two per refresh.

- Refreshes every 15 seconds, and immediately after the Mac wakes
- Menu shows last price, bid, ask, 24h volume, and today's open, high and low with their times and the price's position in the range
- Keeps the last price with a `⚠︎` marker if a fetch fails
- Blinks the price for 30 seconds on entering the top or bottom 5% of today's range, once the range is at least 1% wide (Blink Alerts in the menu turns this off, and it follows Reduce Motion)
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

`swiftbar/luno-btc.30s.py` shows the same thing under [SwiftBar](https://github.com/swiftbar/SwiftBar), for anyone who would rather not build the app.

```
RM293,281 ↓3.9 ↑0.2
```

- `↓` (red) is how far the price sits below today's high, in percent
- `↑` (green) is how far it sits above today's low, in percent
- "Today" starts at 00:00 MYT, with the high and low from the same trades endpoint as the app
- The dropdown shows bid/ask, open, high and low with times, position in the day's range and 24h volume
- Refreshes every 30 seconds and caches the day's state in `~/.cache/luno-btc-day.json`

Install:

```sh
brew install --cask swiftbar
mkdir -p ~/SwiftBar && cp swiftbar/luno-btc.30s.py ~/SwiftBar/
```

Then point SwiftBar's plugin folder at `~/SwiftBar`. Uses `/usr/bin/python3` with no extra packages.
