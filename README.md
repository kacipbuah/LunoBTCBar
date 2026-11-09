# LunoBTCBar

Native macOS menu bar app that shows the Luno BTC/MYR price next to the clock.

```
₿ RM 305,137
```

- Refreshes every 15 seconds from Luno's public [ticker API](https://api.luno.com/api/1/ticker?pair=XBTMYR), and immediately after the Mac wakes
- Menu shows last price, bid, ask, 24h volume and last update time
- Keeps the last price with a `⚠︎` marker if a fetch fails
- Optional Start at Login toggle
- No API key, no dependencies, no Dock icon

Not affiliated with Luno.

## Build and install

Requires macOS 13 or later and the Xcode command line tools.

```sh
./build.sh
```

This compiles the app, installs it to `~/Applications/LunoBTCBar.app` and launches it.
