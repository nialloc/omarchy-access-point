// Run with: node tests/model.test.js
var fs = require("fs")
var path = require("path")
var vm = require("vm")

var Model = {}
vm.runInNewContext(fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8"), Model)

var failures = 0
function eq(actual, expected, what) {
  var a = JSON.stringify(actual), e = JSON.stringify(expected)
  if (a !== e) { failures++; console.log("FAIL " + what + "\n  got      " + a + "\n  expected " + e) }
}

var raw = [
  "yes:HomeNet:02\\:00\\:00\\:00\\:00\\:01:11:2462 MHz:74",
  "no:HomeNet:02\\:00\\:00\\:00\\:00\\:02:6:2437 MHz:49",
  "no:HomeNet-Guest:06\\:00\\:00\\:00\\:00\\:01:11:2462 MHz:80",
  "no:my\\:net:AA\\:BB\\:CC\\:DD\\:EE\\:FF:36:5180 MHz:20",
  "no:HomeNet:02\\:00\\:00\\:00\\:00\\:02:6:2437 MHz:55",
  "no::02\\:00\\:00\\:00\\:00\\:09:100:5500 MHz:20",
  ""
].join("\n")

var scan = Model.parseScan(raw)
eq(scan.length, 5, "dedupes by BSSID")
eq(scan[0], { active: true, ssid: "HomeNet", bssid: "02:00:00:00:00:01", channel: 11, freq: 2462, signal: 74 }, "parses a row")
eq(scan[1].signal, 55, "keeps the strongest duplicate")
eq(scan[3].ssid, "my:net", "unescapes colons in SSIDs")
eq(scan[4].ssid, "", "hidden SSID")
eq(Model.current(scan).bssid, "02:00:00:00:00:01", "finds the active AP")
eq(Model.current([]), null, "no active AP")

eq(Model.band(2462), "2.4 GHz", "2.4 band")
eq(Model.band(5500), "5 GHz", "5 band")
eq(Model.band(5955), "6 GHz", "6 band")
eq(Model.shortBssid("02:00:00:00:00:01"), "00:00:01", "short bssid")

var labels = Model.parseLabels('{"labels":{"02:00:00:00:00:01":" Office ","02:00:00:00:00:02":"","11:22:33:44:55:66":"Garage"}}')
eq(labels, { "02:00:00:00:00:01": "Office", "11:22:33:44:55:66": "Garage" }, "normalises labels")
eq(Model.parseLabels("not json"), {}, "bad file is no labels")
eq(Model.parseLabels(""), {}, "empty file is no labels")

var rows = Model.rows(scan, "HomeNet", labels)
eq(rows.map(function(r) { return r.bssid }), ["02:00:00:00:00:01", "02:00:00:00:00:02", "11:22:33:44:55:66"], "row order")
eq(rows[0].label, "Office", "label attached")
eq(rows[2].inRange, false, "labelled AP out of range")
eq(Model.rowSubtitle(rows[0]), "Connected · ch 11 · 2.4 GHz · 74% · 02:00:00:00:00:01", "active subtitle")
eq(Model.rowSubtitle(rows[1]), "ch 6 · 2.4 GHz · 55%", "unlabelled subtitle")
eq(Model.rowSubtitle(rows[2]), "Out of range · 11:22:33:44:55:66", "out of range subtitle")

eq(Model.canConnect(rows[0]), false, "can't connect to the AP in use")
eq(Model.canConnect(rows[1]), true, "can connect to another in-range AP")
eq(Model.canConnect(rows[2]), false, "can't connect to an out-of-range AP")
eq(Model.canConnect(null), false, "no row")

// Which networks the widget is for
var dualBand = Model.parseScan("yes:Cafe:0A\\:00\\:00\\:00\\:00\\:1C:44:5220 MHz:70\nno:Cafe:0A\\:00\\:00\\:00\\:00\\:1D:9:2452 MHz:60")
eq(dualBand.length, 2, "dual-band router scan has two BSSIDs")
eq(Model.isMultiAp(dualBand, "Cafe", {}), false, "a dual-band router alone isn't multi-AP")
eq(Model.isMultiAp(scan, "HomeNet", {}), true, "two devices in range are multi-AP")
eq(Model.isMultiAp([scan[0]], "HomeNet", { "aa:00:00:00:00:01": { ssid: "HomeNet", freq: 2437 } }), true, "a remembered AP counts")
eq(Model.isMultiAp([scan[0]], "HomeNet", { "aa:00:00:00:00:01": { ssid: "HomeNet", freq: 5180 } }), false, "one on another band may be the same box")
eq(Model.isMultiAp([scan[0]], "HomeNet", { "aa:00:00:00:00:01": { ssid: "Work", freq: 2437 } }), false, "another network's AP doesn't count")
eq(Model.isMultiAp([scan[0]], "HomeNet", { "02:00:00:00:00:01": { ssid: "HomeNet", freq: 2462 } }), false, "the same BSSID remembered isn't a second AP")
eq(Model.isMultiAp(scan, "", {}), false, "no network, not multi-AP")

var workSeen = { "11:22:33:44:55:66": { ssid: "Work", channel: 1, freq: 2412, lastSeen: 1 } }
eq(Model.rows(scan, "HomeNet", labels, workSeen).map(function(r) { return r.bssid }),
   ["02:00:00:00:00:01", "02:00:00:00:00:02"], "a named AP of another network stays off this list")
eq(Model.rows(scan, "Work", labels, workSeen).map(function(r) { return r.bssid }),
   ["11:22:33:44:55:66", "02:00:00:00:00:01"], "and shows on its own network, orphan names too")

var renamed = Model.withLabel(labels, "02:00:00:00:00:02", "  Kitchen ")
eq(renamed["02:00:00:00:00:02"], "Kitchen", "adds a label")
eq(labels["02:00:00:00:00:02"], undefined, "withLabel doesn't mutate")
eq(Model.withLabel(renamed, "02:00:00:00:00:02", " ")["02:00:00:00:00:02"], undefined, "blank name removes label")
eq(Model.parseLabels(Model.serializeLabels(renamed)), { "02:00:00:00:00:01": "Office", "02:00:00:00:00:02": "Kitchen", "11:22:33:44:55:66": "Garage" }, "labels round-trip, sorted")

// Remembering access points
var T = 1790500000000
var seen = Model.parseSeen('{"aps":{"02:00:00:00:00:05":{"ssid":"HomeNet","channel":11,"freq":2462,"lastSeen":' + (T - 3 * 3600000) + '},'
  + '"aa:aa:aa:aa:aa:aa":{"ssid":"OTHER","channel":1,"freq":2412,"lastSeen":' + T + '}}}')
eq(Object.keys(seen), ["02:00:00:00:00:05", "aa:aa:aa:aa:aa:aa"], "parses seen, normalising keys")
eq(Model.parseSeen("{"), {}, "bad seen file is empty")

var rec = Model.recordScan(seen, scan, "HomeNet", T, 600000)
eq(rec.dirty, true, "new access points make the record dirty")
eq(rec.seen["02:00:00:00:00:01"], { ssid: "HomeNet", channel: 11, freq: 2462, lastSeen: T }, "records a HomeNet AP")
eq(rec.seen["06:00:00:00:00:01"], undefined, "ignores other SSIDs")
eq(seen["02:00:00:00:00:01"], undefined, "recordScan doesn't mutate")
var again = Model.recordScan(rec.seen, scan, "HomeNet", T + 5000, 600000)
eq(again.dirty, false, "a rescan a few seconds later isn't worth writing")
eq(again.seen["02:00:00:00:00:01"].lastSeen, T + 5000, "but lastSeen moves on in memory")
eq(Model.recordScan(rec.seen, scan, "HomeNet", T + 600000, 600000).dirty, true, "stale lastSeen gets written")
var sortedSeen = {}
Object.keys(rec.seen).sort().forEach(function(k) { sortedSeen[k] = rec.seen[k] })
eq(Model.parseSeen(Model.serializeSeen(rec.seen)), sortedSeen, "seen round-trips, sorted")

var withSeen = Model.rows(scan, "HomeNet", labels, rec.seen)
eq(withSeen.map(function(r) { return r.bssid }),
   ["02:00:00:00:00:01", "02:00:00:00:00:02", "11:22:33:44:55:66", "02:00:00:00:00:05"],
   "remembered APs follow the in-range ones, named first")
var linksys = withSeen[3]
eq(linksys.inRange, false, "remembered AP is out of range")
eq(Model.rowSubtitle(linksys, T), "Seen 3 h ago · ch 11 · 2.4 GHz", "remembered subtitle")
eq(Model.canForget(linksys), true, "can forget a remembered AP")
eq(Model.canForget(withSeen[0]), false, "can't forget one in range")
eq(Object.keys(Model.without(rec.seen, "02:00:00:00:00:05")).indexOf("02:00:00:00:00:05"), -1, "without drops it")

eq(Model.ago(T - 20000, T), "just now", "ago: just now")
eq(Model.ago(T - 5 * 60000, T), "5 min ago", "ago: minutes")
eq(Model.ago(T - 26 * 3600000, T), "1 day ago", "ago: a day")
eq(Model.ago(T - 50 * 3600000, T), "2 days ago", "ago: days")

eq(Model.apName(scan[0], labels), "Office", "bar shows label")
eq(Model.apName(scan[0], {}), "00:00:01", "bar falls back to short bssid")
eq(Model.heroTitle(scan[3], "HomeNet", labels), "Not on HomeNet", "away title")
eq(Model.heroMeta(scan[3], "HomeNet"), "Connected to my:net", "away meta")
eq(Model.heroMeta(null, "HomeNet"), "Wi-Fi not connected", "disconnected meta")
eq(Model.heroMeta(scan[0], "HomeNet"), "HomeNet · ch 11 · 2.4 GHz · 74%", "home meta")
eq(Model.signalGlyph(-1), Model.OUT_OF_RANGE_GLYPH, "out-of-range glyph")
eq(Model.signalGlyph(100), Model.SIGNAL_GLYPHS[4], "full signal glyph")
eq(Model.signalGlyph(0), Model.SIGNAL_GLYPHS[0], "no signal glyph")

if (failures) { console.log(failures + " failed"); process.exit(1) }
console.log("all passed")
