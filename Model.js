// Pure helpers for the Access Point panel: nmcli parsing, the labels file
// and display text. No QML state lives here.

// Nerd Font (Material Design) glyphs.
var AP_GLYPH = String.fromCodePoint(0xF0469) // router-wireless
var EDIT_GLYPH = String.fromCodePoint(0xF03EB) // pencil
var CONNECT_GLYPH = String.fromCodePoint(0xF0318) // lan-connect
var FORGET_GLYPH = String.fromCodePoint(0xF0A7A) // trash-can-outline
var RESCAN_GLYPH = String.fromCodePoint(0xF0450) // refresh
var OUT_OF_RANGE_GLYPH = String.fromCodePoint(0xF092E) // wifi-strength-off-outline
var SIGNAL_GLYPHS = [0xF092F, 0xF091F, 0xF0922, 0xF0925, 0xF0928].map(function(c) { return String.fromCodePoint(c) })

// Fields asked of `nmcli -t device wifi list`, in this order.
var SCAN_FIELDS = "ACTIVE,SSID,BSSID,CHAN,FREQ,SIGNAL"

function signalGlyph(strength) {
  if (strength < 0) return OUT_OF_RANGE_GLYPH
  return SIGNAL_GLYPHS[Math.max(0, Math.min(4, Math.ceil(strength / 20) - 1))]
}

// nmcli's terse mode separates fields with ':' and backslash-escapes any ':'
// or '\' inside a value, which every BSSID has.
function splitTerse(line) {
  var fields = []
  var current = ""
  for (var i = 0; i < line.length; i++) {
    var c = line[i]
    if (c === "\\" && i + 1 < line.length) current += line[++i]
    else if (c === ":") { fields.push(current); current = "" }
    else current += c
  }
  fields.push(current)
  return fields
}

function normalizeBssid(bssid) {
  return String(bssid || "").trim().toLowerCase()
}

// -> [{ bssid, ssid, active, channel, freq, signal }], one per BSSID. The same
// BSSID can be listed twice (once per radio that heard it); keep the active or
// strongest sighting.
function parseScan(raw) {
  var byBssid = {}
  var order = []
  String(raw || "").split("\n").forEach(function(line) {
    if (line.trim() === "") return
    var f = splitTerse(line)
    if (f.length < 6) return
    var ap = {
      active: f[0] === "yes",
      ssid: f[1],
      bssid: normalizeBssid(f[2]),
      channel: parseInt(f[3], 10) || 0,
      freq: parseInt(f[4], 10) || 0,
      signal: parseInt(f[5], 10) || 0
    }
    if (ap.bssid === "") return
    var seen = byBssid[ap.bssid]
    if (!seen) order.push(ap.bssid)
    if (!seen || (ap.active && !seen.active) || (ap.active === seen.active && ap.signal > seen.signal))
      byBssid[ap.bssid] = ap
  })
  return order.map(function(b) { return byBssid[b] })
}

// Whether `ssid` is served by more than one physical access point: the only
// kind of network this widget has anything to say about. One access point
// has at most one radio per band, so two BSSIDs in the same band mean two
// boxes, and a dual-band router alone doesn't count. MAC numbering can't be
// trusted for this: units of a mesh kit can differ in the last byte only.
// Counts access points in the scan and remembered ones alike.
function isMultiAp(scan, ssid, seen) {
  if (!ssid) return false
  var freqs = {}
  for (var b in seen || {}) if (seen[b].ssid === ssid) freqs[b] = seen[b].freq
  var list = scan || []
  list.forEach(function(ap) { if (ap.ssid === ssid) freqs[ap.bssid] = ap.freq })
  var perBand = {}
  for (var bssid in freqs) {
    var key = band(freqs[bssid])
    perBand[key] = (perBand[key] || 0) + 1
    if (perBand[key] > 1) return true
  }
  return false
}

// The access point this machine is associated with, or null.
function current(scan) {
  for (var i = 0; i < (scan || []).length; i++) if (scan[i].active) return scan[i]
  return null
}

function band(freq) {
  if (!freq) return ""
  if (freq < 3000) return "2.4 GHz"
  if (freq < 5925) return "5 GHz"
  return "6 GHz"
}

// Last three octets: enough to tell a household's access points apart.
function shortBssid(bssid) {
  return String(bssid || "").split(":").slice(-3).join(":")
}

// "ch 11 · 2.4 GHz · 74%"
function radioDetail(ap) {
  if (!ap || ap.signal < 0) return ""
  var parts = []
  if (ap.channel) parts.push("ch " + ap.channel)
  if (ap.freq) parts.push(band(ap.freq))
  parts.push(ap.signal + "%")
  return parts.join(" · ")
}

// labels.json is { "labels": { "<bssid>": "<name>" } }. Anything unreadable
// counts as no labels rather than an error, so a hand-edit typo can't break
// the bar.
function parseLabels(text) {
  var data = null
  try { data = JSON.parse(String(text || "")) } catch (e) {}
  var out = {}
  var src = data && typeof data.labels === "object" && data.labels ? data.labels : {}
  for (var key in src) {
    var name = String(src[key] || "").trim()
    if (name !== "") out[normalizeBssid(key)] = name
  }
  return out
}

function serializeLabels(labels) {
  var sorted = {}
  Object.keys(labels || {}).sort().forEach(function(k) { sorted[k] = labels[k] })
  return JSON.stringify({ labels: sorted }, null, 2) + "\n"
}

// A copy of `labels` with `bssid` renamed; an empty name removes the label.
function withLabel(labels, bssid, name) {
  var out = {}
  for (var k in labels || {}) out[k] = labels[k]
  var key = normalizeBssid(bssid)
  var trimmed = String(name || "").trim()
  if (trimmed === "") delete out[key]
  else out[key] = trimmed
  return out
}

// seen.json remembers every access point ever detected on a tracked SSID:
// { "aps": { "<bssid>": { "ssid", "channel", "freq", "lastSeen" (epoch ms) } } }
// Like labels, anything unreadable counts as empty.
function parseSeen(text) {
  var data = null
  try { data = JSON.parse(String(text || "")) } catch (e) {}
  var out = {}
  var src = data && typeof data.aps === "object" && data.aps ? data.aps : {}
  for (var key in src) {
    var e = src[key] || {}
    var bssid = normalizeBssid(key)
    if (bssid === "") continue
    out[bssid] = {
      ssid: String(e.ssid || ""),
      channel: Number(e.channel) || 0,
      freq: Number(e.freq) || 0,
      lastSeen: Number(e.lastSeen) || 0
    }
  }
  return out
}

function serializeSeen(seen) {
  var sorted = {}
  Object.keys(seen || {}).sort().forEach(function(k) { sorted[k] = seen[k] })
  return JSON.stringify({ aps: sorted }, null, 2) + "\n"
}

// Folds a scan into `seen`. `dirty` says whether the result is worth writing:
// a new access point, a channel change, or a stored lastSeen older than
// `staleMs`. Refreshing lastSeen on every poll would rewrite the file every
// few seconds for nothing.
function recordScan(seen, scan, ssid, now, staleMs) {
  var out = {}
  for (var k in seen || {}) out[k] = seen[k]
  var dirty = false
  var list = scan || []
  list.forEach(function(ap) {
    if (ap.ssid !== ssid) return
    var old = out[ap.bssid]
    if (!old || old.ssid !== ap.ssid || old.channel !== ap.channel || old.freq !== ap.freq
        || now - old.lastSeen >= staleMs)
      dirty = true
    out[ap.bssid] = { ssid: ap.ssid, channel: ap.channel, freq: ap.freq, lastSeen: now }
  })
  return { seen: out, dirty: dirty }
}

// A copy of `map` (labels or seen) without `bssid`.
function without(map, bssid) {
  var out = {}
  var key = normalizeBssid(bssid)
  for (var k in map || {}) if (k !== key) out[k] = map[k]
  return out
}

// Panel rows: every access point broadcasting `ssid` (the connected one
// first, then strongest first), then the remembered ones that are out of
// range right now: named ones by name, then the rest most recently seen first.
function rows(scan, ssid, labels, seen) {
  labels = labels || {}
  seen = seen || {}
  var here = {}
  var inRange = (scan || []).filter(function(ap) { return ap.ssid === ssid }).map(function(ap) {
    here[ap.bssid] = true
    return {
      bssid: ap.bssid, label: labels[ap.bssid] || "", active: ap.active,
      channel: ap.channel, freq: ap.freq, signal: ap.signal, inRange: true, lastSeen: 0
    }
  })
  inRange.sort(function(a, b) {
    if (a.active !== b.active) return a.active ? -1 : 1
    return b.signal - a.signal
  })
  // Remembered access points of this network. A name with no record of which
  // network it belongs to (set over IPC for an access point never scanned)
  // shows everywhere so it can still be found and forgotten.
  var remembered = Object.keys(labels).filter(function(b) { return !seen[b] || seen[b].ssid === ssid })
  Object.keys(seen).forEach(function(b) {
    if (seen[b].ssid === ssid && !labels[b]) remembered.push(b)
  })
  var away = remembered.filter(function(b) { return !here[b] }).map(function(b) {
    var s = seen[b] || {}
    return {
      bssid: b, label: labels[b] || "", active: false,
      channel: s.channel || 0, freq: s.freq || 0, signal: -1, inRange: false, lastSeen: s.lastSeen || 0
    }
  })
  away.sort(function(a, b) {
    if ((a.label === "") !== (b.label === "")) return a.label === "" ? 1 : -1
    if (a.label !== b.label) return a.label.localeCompare(b.label)
    return b.lastSeen - a.lastSeen
  })
  return inRange.concat(away)
}

// "just now", "5 min ago", "3 h ago", "2 days ago"
function ago(then, now) {
  var mins = Math.floor((now - then) / 60000)
  if (mins < 1) return "just now"
  if (mins < 60) return mins + " min ago"
  var hours = Math.floor(mins / 60)
  if (hours < 24) return hours + " h ago"
  var days = Math.floor(hours / 24)
  return days + (days === 1 ? " day ago" : " days ago")
}

// Only an access point that's in range and not already the one in use.
function canConnect(row) {
  return !!row && row.inRange && !row.active
}

// Only a remembered access point that's out of range: one in range would be
// back on the next scan.
function canForget(row) {
  return !!row && !row.inRange
}

// Radio details before the BSSID, so a narrow panel elides the BSSID first.
function rowSubtitle(row, now) {
  var parts = []
  if (row.active) parts.push("Connected")
  if (row.inRange) parts.push(radioDetail(row))
  else {
    parts.push(row.lastSeen ? "Seen " + ago(row.lastSeen, now) : "Out of range")
    if (row.channel) parts.push("ch " + row.channel)
    if (row.freq) parts.push(band(row.freq))
  }
  if (row.label !== "") parts.push(row.bssid)
  return parts.join(" · ")
}

// Name shown for the connected access point: its label, or a short BSSID.
function apName(ap, labels) {
  if (!ap) return ""
  return (labels || {})[ap.bssid] || shortBssid(ap.bssid)
}

function heroTitle(ap, ssid, labels) {
  if (!ap || ap.ssid !== ssid) return "Not on " + ssid
  return (labels || {})[ap.bssid] || "Unlabelled access point"
}

function heroMeta(ap, ssid) {
  if (!ap) return "Wi-Fi not connected"
  if (ap.ssid !== ssid) return "Connected to " + (ap.ssid || "a hidden network")
  return ssid + " · " + radioDetail(ap)
}

function tooltip(ap, ssid, labels) {
  if (!ap || ap.ssid !== ssid) return heroTitle(ap, ssid, labels) + " · " + heroMeta(ap, ssid)
  var name = (labels || {})[ap.bssid]
  return ssid + ": " + (name || ap.bssid + " (unlabelled, click to name it)") + " · " + radioDetail(ap)
}
