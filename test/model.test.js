// Run with: node test/model.test.js
const assert = require("node:assert/strict")
const { test } = require("node:test")
const Model = require("../Model.js")

const NOW = Date.parse("2026-10-13T20:00:00-04:00")

function folder(over) {
  return Object.assign({
    id: "notes", label: "Notes", path: "/home/u/Notes", paused: false,
    sharedWith: 1, state: "idle", error: "", globalBytes: 1000, needBytes: 0,
    needFiles: 0, pullErrors: 0
  }, over)
}

function device(over) {
  return Object.assign({
    id: "AAA", name: "laptop", paused: false, connected: true,
    address: "192.168.1.5:22000", lastSeen: "", completion: 100
  }, over)
}

function status(over) {
  return Object.assign(Model.defaultStatus(), {
    unitState: "active", reachable: true, folders: [folder()], devices: [device()]
  }, over)
}

test("parseStatus tolerates empty and broken input", () => {
  assert.equal(Model.parseStatus("").reachable, false)
  const broken = Model.parseStatus("{nope")
  assert.equal(broken.ok, false)
  assert.match(broken.lastError, /parse/)
  const partial = Model.parseStatus('{"reachable": true, "folders": null}')
  assert.equal(partial.reachable, true)
  assert.deepEqual(partial.folders, [])
})

test("serviceRunning follows systemd, falling back to the API", () => {
  assert.equal(Model.serviceRunning({ unitState: "active" }), true)
  assert.equal(Model.serviceRunning({ unitState: "inactive", reachable: true }), false)
  assert.equal(Model.serviceRunning({ unitState: "unknown", reachable: true }), true)
  assert.equal(Model.serviceRunning({ unitState: "failed" }), false)
})

test("overall: stopped, starting, not responding", () => {
  assert.equal(Model.overall(status({ unitState: "inactive", reachable: false })).key, "stopped")
  const starting = Model.overall(status({ unitState: "activating", reachable: false }))
  assert.equal(starting.key, "unreachable")
  assert.equal(starting.text, "Starting…")
  assert.equal(Model.overall(status({ reachable: false })).text, "Not responding")
})

test("overall: idle, offline, and empty", () => {
  assert.deepEqual(Model.overall(status()).key, "idle")
  assert.equal(Model.overall(status()).text, "Up to date")
  assert.equal(Model.overall(status({ devices: [device({ connected: false })] })).key, "offline")
  // A paused device does not make us "offline".
  assert.equal(Model.overall(status({ devices: [device({ connected: false, paused: true })] })).key, "idle")
  assert.equal(Model.overall(status({ folders: [] })).text, "No folders")
})

test("overall: errors win over syncing", () => {
  const s = status({ folders: [folder({ state: "syncing", needBytes: 500 }), folder({ id: "b", pullErrors: 2 })] })
  const o = Model.overall(s)
  assert.equal(o.key, "error")
  assert.equal(o.text, "1 folder needs attention")
  assert.equal(Model.overall(status({ systemErrors: [{ message: "x" }, { message: "y" }] })).text, "2 warnings")
})

test("overall: aggregate sync progress and remote catch-up", () => {
  const s = status({ folders: [
    folder({ state: "syncing", globalBytes: 1000, needBytes: 500 }),
    folder({ id: "b", state: "syncing", globalBytes: 1000, needBytes: 0 })
  ] })
  assert.equal(Model.overall(s).text, "Syncing 75%")
  assert.equal(Model.overall(status({ folders: [folder({ state: "scanning" })] })).key, "scanning")
  const remote = Model.overall(status({ devices: [device({ completion: 40 })] }))
  assert.equal(remote.key, "syncing")
  assert.equal(remote.text, "Updating laptop")
})

test("paused folders never count as problems or busy", () => {
  const f = folder({ paused: true, state: "error", pullErrors: 3 })
  assert.equal(Model.folderHasProblem(f), false)
  assert.equal(Model.folderIsBusy(f), false)
  assert.equal(Model.folderStateText(f), "Paused")
})

test("folderStateText covers Syncthing's states", () => {
  assert.equal(Model.folderStateText(folder()), "Up to date")
  assert.equal(Model.folderStateText(folder({ state: "syncing", needBytes: 250 })), "Syncing 75%")
  assert.equal(Model.folderStateText(folder({ state: "sync-preparing" })), "Preparing to sync")
  assert.equal(Model.folderStateText(folder({ state: "scan-waiting" })), "Waiting to scan")
  assert.equal(Model.folderStateText(folder({ needFiles: 3 })), "Out of sync · 3 items")
  assert.equal(Model.folderStateText(folder({ pullErrors: 1 })), "1 failed item")
  assert.equal(Model.folderStateText(folder({ state: "error" })), "Error")
})

test("folderMeta joins state, size, and sharing", () => {
  assert.equal(Model.folderMeta(folder({ globalBytes: 1043488430 })), "Up to date · 1.04 GB · shared with 1 device")
  assert.equal(Model.folderMeta(folder({ globalBytes: 0, sharedWith: 0 })), "Up to date · not shared")
})

test("deviceMeta", () => {
  assert.equal(Model.deviceMeta(device(), NOW), "Connected · 192.168.1.5")
  assert.equal(Model.deviceMeta(device({ completion: 42.4 }), NOW), "Connected · 192.168.1.5 · 42% synced")
  assert.equal(Model.deviceMeta(device({ connected: false, lastSeen: "2026-10-13T18:00:00-04:00" }), NOW), "Last seen 2h ago")
  assert.equal(Model.deviceMeta(device({ connected: false, lastSeen: "1969-12-31T19:00:00-05:00" }), NOW), "Never seen")
  assert.equal(Model.deviceMeta(device({ paused: true }), NOW), "Paused")
})

test("hostOf strips ports and transports", () => {
  assert.equal(Model.hostOf("192.168.10.178:22000"), "192.168.10.178")
  assert.equal(Model.hostOf("[fe80::1%eth0]:22000"), "fe80::1%eth0")
  assert.equal(Model.hostOf("relay://relay.example.org:22067"), "relay.example.org")
  assert.equal(Model.hostOf(""), "")
})

test("formatPercent never rounds an unfinished sync to 100%", () => {
  assert.equal(Model.formatPercent(99.7), "99%")
  assert.equal(Model.formatPercent(100), "100%")
  assert.equal(Model.formatPercent(42.5), "43%")
  assert.equal(Model.formatPercent(0), "0%")
})

test("shortPath and shellQuote", () => {
  assert.equal(Model.shortPath("/home/u/Notes", "/home/u"), "~/Notes")
  assert.equal(Model.shortPath("/home/uu/Notes", "/home/u"), "/home/uu/Notes")
  assert.equal(Model.shellQuote("it's"), "'it'\\''s'")
})

test("glyphs are single Nerd Font code points", () => {
  for (const [name, glyph] of Object.entries(Model.GLYPHS)) {
    assert.equal([...glyph].length, 1, name)
    assert.ok(glyph.codePointAt(0) >= 0xF0000, name)
  }
})

test("validUnit only accepts plain service unit names", () => {
  assert.equal(Model.validUnit("syncthing.service"), true)
  assert.equal(Model.validUnit("syncthing@user.service"), true)
  assert.equal(Model.validUnit("--host=evil.service"), false)
  assert.equal(Model.validUnit("-syncthing.service"), false)
  assert.equal(Model.validUnit("syncthing.service; rm -rf ~"), false)
  assert.equal(Model.validUnit("syncthing"), false)
  assert.equal(Model.validUnit(""), false)
  assert.equal(Model.validUnit(null), false)
})

test("webAppWindowPattern matches the app window class, not page titles", () => {
  assert.equal(Model.webAppWindowPattern("http://127.0.0.1:8384"), "127\\.0\\.0\\.1__")
  assert.equal(Model.webAppWindowPattern("https://localhost:8384/"), "localhost__")
  const re = new RegExp("\\b" + Model.webAppWindowPattern("http://127.0.0.1:8384") + "\\b", "i")
  assert.ok(re.test("brave-127.0.0.1__-Default"))
  assert.ok(re.test("chrome-127.0.0.1__-Default"))
  assert.ok(!re.test("someone/syncthing-notes: Syncthing tips - Brave"))
  assert.ok(!re.test("brave-127.0.0.10__-Default"))
})
