// Pure helpers for the Syncthing widget. No QML imports, so the same file is
// loaded by the panel (`import "Model.js" as Model`) and by `node test/`.

// Nerd Font (Material Design) icons, by code point so the source stays ASCII.
var GLYPHS = {
  sync: String.fromCodePoint(0xF04E6),          // md-sync
  syncAlert: String.fromCodePoint(0xF04E7),     // md-sync_alert
  syncOff: String.fromCodePoint(0xF04E8),       // md-sync_off
  folder: String.fromCodePoint(0xF024B),        // md-folder
  folderPaused: String.fromCodePoint(0xF0256),  // md-folder_outline
  folderAlert: String.fromCodePoint(0xF0DCC),   // md-folder_alert
  folderSync: String.fromCodePoint(0xF0D0B),    // md-folder_sync
  laptop: String.fromCodePoint(0xF0322),        // md-laptop
  laptopOff: String.fromCodePoint(0xF06E7),     // md-laptop_off
  rescan: String.fromCodePoint(0xF0450),        // md-refresh
  restart: String.fromCodePoint(0xF0709),       // md-restart
  web: String.fromCodePoint(0xF059F),           // md-web
  terminal: String.fromCodePoint(0xF018D),      // md-console
  start: String.fromCodePoint(0xF040A),         // md-play
  stop: String.fromCodePoint(0xF04DB)           // md-stop
}
var GLYPH_SYNC = GLYPHS.sync
var GLYPH_ALERT = GLYPHS.syncAlert
var GLYPH_OFF = GLYPHS.syncOff

var BUSY_STATES = {
  "syncing": true, "sync-preparing": true, "sync-waiting": true,
  "scanning": true, "scan-waiting": true, "cleaning": true, "clean-waiting": true
}

function defaultStatus() {
  return {
    ok: true,
    unit: "syncthing.service",
    unitState: "unknown",
    reachable: false,
    guiUrl: "",
    myId: "",
    version: "",
    uptime: 0,
    folders: [],
    devices: [],
    systemErrors: [],
    lastError: ""
  }
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return defaultStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return defaultStatus()
    var base = defaultStatus()
    for (var key in parsed) base[key] = parsed[key]
    base.folders = Array.isArray(base.folders) ? base.folders : []
    base.devices = Array.isArray(base.devices) ? base.devices : []
    base.systemErrors = Array.isArray(base.systemErrors) ? base.systemErrors : []
    return base
  } catch (e) {
    var failed = defaultStatus()
    failed.ok = false
    failed.lastError = "Failed to parse Syncthing status"
    return failed
  }
}

// systemd says the unit is up (or on its way up). When the unit is unknown —
// Syncthing started some other way — fall back to whether the API answers.
function serviceRunning(status) {
  var state = String(status && status.unitState || "unknown")
  if (state === "active" || state === "activating" || state === "reloading") return true
  if (state === "unknown") return !!(status && status.reachable)
  return false
}

// A systemd service unit name, and never something systemctl or a shell
// could read as an option or syntax.
var UNIT_RE = /^[A-Za-z0-9_@][A-Za-z0-9_.@:-]*\.service$/

function validUnit(unit) {
  return UNIT_RE.test(String(unit === undefined || unit === null ? "" : unit).trim())
}

function folderProgress(folder) {
  if (!folder) return 100
  var total = Number(folder.globalBytes || 0)
  var need = Number(folder.needBytes || 0)
  if (!isFinite(total) || total <= 0) return need > 0 ? 0 : 100
  return Math.max(0, Math.min(100, (total - need) / total * 100))
}

function folderHasProblem(folder) {
  if (!folder || folder.paused) return false
  return folder.state === "error" || String(folder.error || "") !== "" || Number(folder.pullErrors || 0) > 0
}

function folderIsBusy(folder) {
  return !!folder && !folder.paused && BUSY_STATES[folder.state] === true
}

function plural(n, one, many) {
  return n + " " + (n === 1 ? one : (many || one + "s"))
}

function folderStateText(folder) {
  if (!folder) return "Unknown"
  if (folder.paused) return "Paused"
  var state = String(folder.state || "unknown")
  var pullErrors = Number(folder.pullErrors || 0)
  if (state === "error") return "Error"
  if (state === "syncing") return "Syncing " + formatPercent(folderProgress(folder))
  if (state === "sync-preparing") return "Preparing to sync"
  if (state === "sync-waiting") return "Waiting to sync"
  if (state === "scanning") return "Scanning"
  if (state === "scan-waiting") return "Waiting to scan"
  if (state === "cleaning" || state === "clean-waiting") return "Cleaning up"
  if (state === "idle") {
    if (pullErrors > 0) return plural(pullErrors, "failed item")
    if (Number(folder.needFiles || 0) > 0) return "Out of sync · " + plural(Number(folder.needFiles), "item")
    return "Up to date"
  }
  return "Unknown"
}

function folderGlyph(folder) {
  if (!folder) return GLYPHS.folder
  if (folder.paused) return GLYPHS.folderPaused
  if (folderHasProblem(folder)) return GLYPHS.folderAlert
  if (folderIsBusy(folder)) return GLYPHS.folderSync
  return GLYPHS.folder
}

function folderMeta(folder) {
  if (!folder) return ""
  var parts = [folderStateText(folder)]
  if (Number(folder.globalBytes || 0) > 0) parts.push(formatBytes(folder.globalBytes))
  var shared = Number(folder.sharedWith || 0)
  parts.push(shared > 0 ? "shared with " + plural(shared, "device") : "not shared")
  return parts.join(" · ")
}

function deviceMeta(device, nowMs) {
  if (!device) return ""
  if (device.paused) return "Paused"
  if (device.connected) {
    var parts = ["Connected"]
    var host = hostOf(device.address)
    if (host !== "") parts.push(host)
    var completion = device.completion
    if (completion !== null && completion !== undefined && Number(completion) < 100) {
      parts.push(formatPercent(completion) + " synced")
    }
    return parts.join(" · ")
  }
  var seen = relativeTime(device.lastSeen, nowMs)
  return seen === "" ? "Never seen" : "Last seen " + seen.toLowerCase()
}

function deviceGlyph(device) {
  return device && device.connected ? GLYPHS.laptop : GLYPHS.laptopOff
}

// Strip the port and any transport prefix from a connection address like
// "192.168.10.178:22000", "[fe80::1]:22000" or "relay://host:22067".
function hostOf(address) {
  var value = String(address || "").replace(/^[a-z]+:\/\//, "")
  if (value === "") return ""
  if (value.charAt(0) === "[") {
    var end = value.indexOf("]")
    return end > 0 ? value.substring(1, end) : value
  }
  var colon = value.lastIndexOf(":")
  return colon > 0 && value.indexOf(":") === colon ? value.substring(0, colon) : value
}

// One state for the bar icon and the panel headline. `key` is one of:
// stopped, unreachable, error, syncing, scanning, offline, idle.
function overall(status) {
  var s = status || defaultStatus()
  var running = serviceRunning(s)
  if (!running && !s.reachable) {
    return { key: "stopped", glyph: GLYPH_OFF, text: "Stopped" }
  }
  if (!s.reachable) {
    var state = String(s.unitState || "")
    if (state === "activating") return { key: "unreachable", glyph: GLYPH_SYNC, text: "Starting…" }
    return { key: "unreachable", glyph: GLYPH_ALERT, text: "Not responding" }
  }

  var folders = s.folders || []
  var devices = s.devices || []
  var problems = 0
  var syncing = false
  var scanning = false
  var totalBytes = 0
  var needBytes = 0
  for (var i = 0; i < folders.length; i++) {
    var f = folders[i]
    if (folderHasProblem(f)) problems++
    if (f.paused) continue
    if (f.state === "syncing" || f.state === "sync-preparing" || f.state === "sync-waiting") {
      syncing = true
      totalBytes += Number(f.globalBytes || 0)
      needBytes += Number(f.needBytes || 0)
    }
    if (f.state === "scanning" || f.state === "scan-waiting") scanning = true
  }

  if (problems > 0) {
    return { key: "error", glyph: GLYPH_ALERT, text: plural(problems, "folder") + " need" + (problems === 1 ? "s" : "") + " attention" }
  }
  if ((s.systemErrors || []).length > 0) {
    return { key: "error", glyph: GLYPH_ALERT, text: plural(s.systemErrors.length, "warning") }
  }
  if (syncing) {
    var pct = totalBytes > 0 ? (totalBytes - needBytes) / totalBytes * 100 : 0
    return { key: "syncing", glyph: GLYPH_SYNC, text: "Syncing " + formatPercent(pct) }
  }
  if (scanning) return { key: "scanning", glyph: GLYPH_SYNC, text: "Scanning" }

  var connected = 0
  var active = 0
  var updating = []
  for (var j = 0; j < devices.length; j++) {
    var d = devices[j]
    if (d.paused) continue
    active++
    if (!d.connected) continue
    connected++
    if (d.completion !== null && d.completion !== undefined && Number(d.completion) < 100) updating.push(d.name)
  }
  if (updating.length > 0) {
    return { key: "syncing", glyph: GLYPH_SYNC, text: "Updating " + updating.join(", ") }
  }
  if (active > 0 && connected === 0) {
    return { key: "offline", glyph: GLYPH_SYNC, text: "No devices connected" }
  }
  if (folders.length === 0) return { key: "idle", glyph: GLYPH_SYNC, text: "No folders" }
  return { key: "idle", glyph: GLYPH_SYNC, text: "Up to date" }
}

function deviceSummary(devices) {
  var list = devices || []
  var connected = 0
  for (var i = 0; i < list.length; i++) if (list[i].connected) connected++
  if (list.length === 0) return "No remote devices"
  return connected + " of " + list.length + " devices connected"
}

function tooltip(status) {
  var s = status || defaultStatus()
  var o = overall(s)
  var lines = ["Syncthing: " + o.text]
  if (s.reachable) lines.push(deviceSummary(s.devices))
  return lines.join("\n")
}

function formatBytes(bytes) {
  var value = Number(bytes || 0)
  if (!isFinite(value) || value <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1000 && index < units.length - 1) {
    value = value / 1000
    index++
  }
  var decimals = value >= 100 || index === 0 ? 0 : (value >= 10 ? 1 : 2)
  return value.toFixed(decimals).replace(/\.0+$/, "").replace(/(\.\d)0$/, "$1") + " " + units[index]
}

function formatPercent(value) {
  var number = Number(value || 0)
  if (!isFinite(number) || number <= 0) return "0%"
  if (number >= 100) return "100%"
  // Never round an unfinished sync up to 100%.
  if (number >= 99) return Math.floor(number) + "%"
  return Math.round(number) + "%"
}

function relativeTime(iso, nowMs) {
  var ts = Date.parse(String(iso || ""))
  // Syncthing reports "never" as the Unix epoch.
  if (!isFinite(ts) || ts <= 946684800000) return ""
  var now = nowMs === undefined ? Date.now() : Number(nowMs)
  var diff = Math.max(0, Math.floor((now - ts) / 1000))
  if (diff < 60) return "Just now"
  var minutes = Math.floor(diff / 60)
  if (minutes < 60) return minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h ago"
  var days = Math.floor(hours / 24)
  if (days < 30) return days + "d ago"
  var months = Math.floor(days / 30)
  if (months < 12) return months + "mo ago"
  return Math.floor(days / 365) + "y ago"
}

function shortPath(path, home) {
  var value = String(path || "")
  var h = String(home || "")
  if (h !== "" && (value === h || value.indexOf(h + "/") === 0)) return "~" + value.substring(h.length)
  return value
}

// Window pattern for omarchy-launch-or-focus-webapp. Chromium-family
// browsers name a --app window's class after the URL host, e.g.
// "brave-127.0.0.1__-Default". Matching that (and not a title word like
// "Syncthing") keeps unrelated windows, such as a browser tab showing a
// Syncthing web page, from being focused instead of the web UI.
function webAppWindowPattern(url) {
  var host = String(url || "").replace(/^[a-z]+:\/\//i, "").split("/")[0]
  if (host.charAt(0) === "[") host = host.substring(1, host.indexOf("]"))
  else host = host.split(":")[0]
  if (host === "") host = "127.0.0.1"
  return host.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "__"
}

// Quote one argument for the `eval` inside omarchy-launch-or-focus.
function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

if (typeof module !== "undefined") {
  module.exports = {
    GLYPHS: GLYPHS,
    defaultStatus: defaultStatus,
    parseStatus: parseStatus,
    serviceRunning: serviceRunning,
    validUnit: validUnit,
    folderProgress: folderProgress,
    folderHasProblem: folderHasProblem,
    folderIsBusy: folderIsBusy,
    folderStateText: folderStateText,
    folderGlyph: folderGlyph,
    folderMeta: folderMeta,
    deviceMeta: deviceMeta,
    deviceGlyph: deviceGlyph,
    hostOf: hostOf,
    overall: overall,
    deviceSummary: deviceSummary,
    tooltip: tooltip,
    formatBytes: formatBytes,
    formatPercent: formatPercent,
    relativeTime: relativeTime,
    shortPath: shortPath,
    shellQuote: shellQuote,
    webAppWindowPattern: webAppWindowPattern
  }
}
