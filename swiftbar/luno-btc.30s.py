#!/usr/bin/python3
# <xbar.title>Luno BTC/MYR</xbar.title>
# <xbar.desc>Luno BTC price + % from today's high/low (MYT midnight)</xbar.desc>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
import json, os, time, urllib.request
from datetime import datetime, timezone, timedelta

PAIR = "XBTMYR"
API = "https://api.luno.com/api/1"
CACHE = os.path.expanduser("~/.cache/luno-btc-day.json")
MYT = timezone(timedelta(hours=8))


def get(path):
    req = urllib.request.Request(API + path, headers={"User-Agent": "swiftbar-luno"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def day_start_ms():
    now = datetime.now(MYT)
    mid = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return int(mid.timestamp() * 1000)


def load_state(day):
    try:
        with open(CACHE) as f:
            s = json.load(f)
        if s.get("day") == day:
            return s
    except Exception:
        pass
    return {"day": day, "since": day, "high": None, "low": None, "open": None,
            "high_ts": None, "low_ts": None}


def save_state(s):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f)
    os.replace(tmp, CACHE)


def update(s, price, ts):
    if s["high"] is None or price > s["high"]:
        s["high"], s["high_ts"] = price, ts
    if s["low"] is None or price < s["low"]:
        s["low"], s["low_ts"] = price, ts


def sync_trades(s):
    # /trades returns up to 100 trades after `since`; page forward until caught up
    for _ in range(60):
        trades = get(f"/trades?pair={PAIR}&since={s['since']}").get("trades", [])
        if not trades:
            break
        trades.sort(key=lambda t: t["timestamp"])
        if s["open"] is None:
            s["open"] = float(trades[0]["price"])
        for t in trades:
            update(s, float(t["price"]), t["timestamp"])
        s["since"] = trades[-1]["timestamp"] + 1
        if len(trades) < 100:
            break


def fmt(n):
    return f"{n:,.0f}"


def hhmm(ms):
    return datetime.fromtimestamp(ms / 1000, MYT).strftime("%H:%M") if ms else "-"


def main():
    day = day_start_ms()
    s = load_state(day)
    try:
        sync_trades(s)
        tk = get(f"/ticker?pair={PAIR}")
    except Exception as e:
        print("₿ ⚠️")
        print("---")
        print(f"Error: {e} | color=red")
        print("Refresh | refresh=true")
        return
    last = float(tk["last_trade"])
    update(s, last, tk["timestamp"])
    if s["open"] is None:
        s["open"] = last
    save_state(s)

    hi, lo, op = s["high"], s["low"], s["open"]
    from_hi = (last - hi) / hi * 100      # <= 0
    from_lo = (last - lo) / lo * 100      # >= 0
    chg = (last - op) / op * 100
    color = "#2ecc71" if chg >= 0 else "#e74c3c"

    red, green, reset = "\033[31m", "\033[32m", "\033[0m"
    print(f"RM{fmt(last)} {red}↓{abs(from_hi):.1f}{reset} {green}↑{from_lo:.1f}{reset} | ansi=true font=Menlo size=12")
    print("---")
    print(f"Luno BTC/MYR  ·  {datetime.now(MYT):%d %b %H:%M:%S} MYT")
    print(f"Last:   RM {fmt(last)} | font=Menlo")
    print(f"Bid/Ask: {fmt(float(tk['bid']))} / {fmt(float(tk['ask']))} | font=Menlo")
    print("---")
    print(f"Hari ini (sejak 00:00 MYT) | size=11")
    print(f"Open:   RM {fmt(op)}  ({chg:+.2f}%) | font=Menlo color={color}")
    print(f"High:   RM {fmt(hi)} @ {hhmm(s['high_ts'])}  → {from_hi:+.2f}% | font=Menlo")
    print(f"Low:    RM {fmt(lo)} @ {hhmm(s['low_ts'])}  → {from_lo:+.2f}% | font=Menlo")
    rng = hi - lo
    pos = (last - lo) / rng * 100 if rng else 50
    print(f"Range:  RM {fmt(rng)}  (harga di {pos:.0f}% range) | font=Menlo")
    print(f"Vol 24j: {float(tk['rolling_24_hour_volume']):.3f} BTC | font=Menlo")
    print("---")
    print("Buka Luno | href=https://www.luno.com/trade/markets/XBTMYR")
    print("Refresh | refresh=true")


main()
