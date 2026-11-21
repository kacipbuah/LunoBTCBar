// Luno BTC/MYR widget for Scriptable (https://scriptable.app) on iPhone and iPad.
//
// Shows the same thing as the menu bar app:
//   RM293,281  ↓3.9 ↑0.2
// ↓ (red) is how far the price sits below today's high, ↑ (green) how far above today's low,
// in percent. "Today" starts at 00:00 Malaysia time. The price turns green in the top 10% of
// today's range and red in the bottom 10%, once the range is at least 1% wide.
//
// Luno's ticker has no high or low, so the script pages through the public trades endpoint
// from midnight and keeps the day's open, high and low in Scriptable's documents folder.
// Works as a Home Screen widget (small or medium) and as a Lock Screen widget (inline or
// rectangular). iOS decides how often widgets refresh, usually every 5 to 15 minutes.

const PAIR = "XBTMYR"
const API = "https://api.luno.com/api/1"
const MYT_OFFSET = 8 * 3600 * 1000
const DAY = 24 * 3600 * 1000
const PAGE_SIZE = 100
// Per run: widgets get little time from iOS, so they read fewer pages; a busy day's backlog
// finishes over the next refreshes, or faster when the script is run in the app.
const MAX_PAGES = config.runsInWidget || config.runsInAccessoryWidget ? 15 : 40
const MIN_RANGE_FRACTION = 0.01
const TRADE_URL = "https://www.luno.com/trade/markets/XBTMYR"

const GREEN = new Color("#2ecc71")
const RED = new Color("#e74c3c")
const ORANGE = new Color("#f7931a")
const GREY = Color.gray()

// --- Day range -------------------------------------------------------------------------

function dayStart(nowMs) {
  return Math.floor((nowMs + MYT_OFFSET) / DAY) * DAY - MYT_OFFSET
}

function newState(day) {
  return { day, since: day, open: null, high: null, low: null, highAt: null, lowAt: null, last: null, lastAt: null }
}

function record(s, price, ts) {
  if (s.open == null) s.open = price
  if (s.high == null || price > s.high) { s.high = price; s.highAt = ts }
  if (s.low == null || price < s.low) { s.low = price; s.lowAt = ts }
}

// Applies one page of trades. Returns true when a full page came back, so more may follow.
function apply(s, trades) {
  const sorted = trades.slice().sort((a, b) => a.timestamp - b.timestamp)
  for (const t of sorted) {
    if (t.timestamp < s.day) continue
    const price = parseFloat(t.price)
    if (!isFinite(price)) continue
    record(s, price, t.timestamp)
  }
  const last = sorted[sorted.length - 1]
  if (last && last.timestamp >= s.since) s.since = last.timestamp + 1
  return trades.length >= PAGE_SIZE
}

function zone(s, price) {
  if (s.low == null || s.high == null || price <= 0) return "neutral"
  if ((s.high - s.low) / price < MIN_RANGE_FRACTION || s.high <= s.low) return "neutral"
  const pos = (price - s.low) / (s.high - s.low)
  if (pos >= 0.9) return "high"
  if (pos <= 0.1) return "low"
  return "neutral"
}

// --- Storage and network ----------------------------------------------------------------

const fm = FileManager.local()
const statePath = fm.joinPath(fm.documentsDirectory(), "luno-btc-day.json")

function loadState(day) {
  try {
    if (fm.fileExists(statePath)) {
      const s = JSON.parse(fm.readString(statePath))
      if (s.day === day) return s
    }
  } catch (e) {}
  return newState(day)
}

function saveState(s) {
  fm.writeString(statePath, JSON.stringify(s))
}

async function get(path) {
  const req = new Request(API + path)
  req.headers = { "User-Agent": "scriptable-luno" }
  req.timeoutInterval = 10
  return await req.loadJSON()
}

async function sync(s) {
  s.partial = true
  for (let i = 0; i < MAX_PAGES; i++) {
    const page = await get(`/trades?pair=${PAIR}&since=${s.since}`)
    const trades = page.trades || []
    if (!trades.length || !apply(s, trades)) { s.partial = false; break }
  }
  const tk = await get(`/ticker?pair=${PAIR}`)
  const last = parseFloat(tk.last_trade)
  record(s, last, tk.timestamp)
  s.last = last
  s.lastAt = Date.now()
}

// --- Formatting -------------------------------------------------------------------------

const fmt = n => Math.round(n).toLocaleString("en-US")
const pct = n => n.toFixed(1)

function hhmm(ms) {
  if (!ms) return "-"
  const d = new Date(ms + MYT_OFFSET)
  return String(d.getUTCHours()).padStart(2, "0") + ":" + String(d.getUTCMinutes()).padStart(2, "0")
}

function numbers(s) {
  const p = s.last
  return {
    price: p,
    below: Math.max(0, (s.high - p) / s.high * 100),
    above: Math.max(0, (p - s.low) / s.low * 100),
    change: (p - s.open) / s.open * 100,
    zone: zone(s, p),
  }
}

// --- Widget -----------------------------------------------------------------------------

function text(stack, str, font, color) {
  const t = stack.addText(str)
  t.font = font
  if (color) t.textColor = color
  t.lineLimit = 1
  t.minimumScaleFactor = 0.6
  return t
}

function arrows(stack, n, size) {
  const row = stack.addStack()
  row.centerAlignContent()
  text(row, `↓${pct(n.below)}`, Font.semiboldMonospacedSystemFont(size), RED)
  row.addSpacer(6)
  text(row, `↑${pct(n.above)}`, Font.semiboldMonospacedSystemFont(size), GREEN)
}

function priceColor(n) {
  return n.zone === "high" ? GREEN : n.zone === "low" ? RED : null
}

function build(s, stale, family) {
  const w = new ListWidget()
  w.url = TRADE_URL
  w.refreshAfterDate = new Date(Date.now() + 60 * 1000) // a request; iOS decides when
  // ⚠︎ = fetch failed, showing the last price; … = still catching up on today's trades
  const warn = stale ? " ⚠︎" : s.partial ? " …" : ""

  if (s.last == null) {
    text(w, "₿ Luno ⚠︎", Font.boldSystemFont(14), ORANGE)
    text(w, "No data yet", Font.systemFont(12), GREY)
    return w
  }
  const n = numbers(s)

  if (family === "accessoryInline") {
    w.addText(`₿${fmt(n.price)} ↓${pct(n.below)} ↑${pct(n.above)}${warn}`)
    return w
  }

  if (family === "accessoryRectangular") {
    text(w, `₿ RM${fmt(n.price)}${warn}`, Font.boldMonospacedSystemFont(15))
    text(w, `↓${pct(n.below)}  ↑${pct(n.above)}`, Font.semiboldMonospacedSystemFont(13))
    text(w, `H ${fmt(s.high)}  L ${fmt(s.low)}`, Font.regularMonospacedSystemFont(11))
    return w
  }

  const small = family !== "medium" && family !== "large"
  w.setPadding(12, 14, 12, 14)

  const head = w.addStack()
  head.centerAlignContent()
  text(head, "₿", Font.boldSystemFont(14), ORANGE)
  head.addSpacer(4)
  text(head, `BTC/MYR${warn}`, Font.mediumSystemFont(13), GREY)
  head.addSpacer()
  text(head, hhmm(s.lastAt), Font.regularMonospacedSystemFont(12), GREY)
  w.addSpacer()

  text(w, `RM${fmt(n.price)}`, Font.boldMonospacedSystemFont(small ? 26 : 32), priceColor(n))
  arrows(w, n, small ? 17 : 19)
  w.addSpacer()

  const bar = w.addImage(rangeBar(s, n, small ? 140 : 300))
  bar.imageSize = new Size(small ? 140 : 300, 10)
  w.addSpacer(6)

  const sign = n.change >= 0 ? "+" : ""
  const detail = Font.mediumMonospacedSystemFont(small ? 13 : 14)
  text(w, `O ${fmt(s.open)} ${sign}${n.change.toFixed(2)}%`, detail, n.change >= 0 ? GREEN : RED)
  text(w, `H ${fmt(s.high)} ${hhmm(s.highAt)}`, detail)
  text(w, `L ${fmt(s.low)} ${hhmm(s.lowAt)}`, detail)
  return w
}

// Today's range as a bar from low to high, filled up to the price, with a dot on the price.
function rangeBar(s, n, width) {
  const h = 10, track = 4
  const dc = new DrawContext()
  dc.size = new Size(width, h)
  dc.opaque = false
  dc.respectScreenScale = true
  const pos = s.high > s.low ? Math.min(1, Math.max(0, (n.price - s.low) / (s.high - s.low))) : 0.5
  const y = (h - track) / 2
  const pill = (x, w, color) => {
    const path = new Path()
    path.addRoundedRect(new Rect(x, y, w, track), track / 2, track / 2)
    dc.addPath(path)
    dc.setFillColor(color)
    dc.fillPath()
  }
  pill(0, width, new Color("#ffffff", 0.18))
  const fill = priceColor(n) || ORANGE
  const x = h / 2 + pos * (width - h)
  pill(0, x, fill)
  dc.setFillColor(Color.white())
  dc.fillEllipse(new Rect(x - h / 2, 0, h, h))
  return dc.getImage()
}

// --- Main -------------------------------------------------------------------------------

const now = Date.now()
const state = loadState(dayStart(now))
let stale = false
try {
  await sync(state)
} catch (e) {
  stale = true
  console.error(e)
}
saveState(state)

const widget = build(state, stale, config.widgetFamily)
if (config.runsInWidget || config.runsInAccessoryWidget) {
  Script.setWidget(widget)
} else {
  await widget.presentSmall()
}
Script.complete()
