import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// State and actions behind the Syncthing widget. Status comes from
// syncthing.py (one process per poll, talking to the local REST API);
// start/stop/restart go straight to systemd.
Item {
  id: root

  property var settings: ({})
  // Set by the panel while it is open, to poll faster.
  property bool watching: false

  property var status: Model.defaultStatus()
  property bool refreshing: false
  property string actionStatus: ""
  property string lastError: ""

  // Optimistic service state so the switch throws the instant you click it.
  // -1 follows reality; 0/1 while a stop/start is still settling.
  property int _desired: -1

  readonly property bool reachable: status.reachable === true
  readonly property bool running: _desired === -1 ? Model.serviceRunning(status) : (_desired === 1)
  readonly property var overall: Model.overall(status)
  readonly property var folders: status.folders || []
  readonly property var devices: status.devices || []
  readonly property bool busy: controlProcess.running || scanProcess.running
  readonly property bool active: overall.key === "syncing" || overall.key === "scanning"
  readonly property string guiUrl: String(status.guiUrl || "")

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 3600)
  readonly property string serviceUnit: Model.validUnit(setting("serviceUnit", "")) ? String(setting("serviceUnit", "")).trim() : "syncthing.service"
  readonly property string tuiCommand: String(setting("tuiCommand", "")).trim()
  readonly property string configPath: String(setting("configPath", "")).trim()
  readonly property bool webUiAsApp: String(setting("webUiMode", "Web app")) !== "Browser tab"
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("syncthing.py")).replace(/^file:\/\//, ""))
  readonly property string home: Quickshell.env("HOME") || ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // Options go before the command: the helper treats everything after the
  // command as positional, so a folder ID can never pose as an option.
  function helperCommand(args) {
    // -I: ignore PYTHON* environment variables and the user site directory.
    var cmd = ["python3", "-I", helperPath]
    if (configPath !== "") cmd = cmd.concat(["--config", configPath])
    return cmd.concat(args)
  }

  function elide(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 160 ? value.substring(0, 157) + "…" : value
  }

  function flash(text) {
    actionStatus = text
    actionStatusTimer.restart()
  }

  function refresh() {
    if (statusProcess.running) return
    refreshing = true
    statusProcess.command = helperCommand(["--unit", serviceUnit, "status"])
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = parsed.lastError
      return
    }
    status = parsed
    if (_desired !== -1 && Model.serviceRunning(parsed) === (_desired === 1)) _desired = -1
    // Only surface API errors while the service is meant to be up.
    lastError = Model.serviceRunning(parsed) ? elide(parsed.lastError) : ""
  }

  // --- service control -------------------------------------------------

  function control(verb) {
    if (controlProcess.running) return
    _desired = verb === "stop" ? 0 : 1
    lastError = ""
    controlProcess.verb = verb
    controlProcess.command = ["systemctl", "--user", verb, "--", serviceUnit]
    controlProcess.running = true
  }

  function start() { control("start") }
  function stop() { control("stop") }
  function restart() { control("restart") }
  function toggleRunning() { running ? stop() : start() }

  // --- folders ---------------------------------------------------------

  function rescan(folderId) {
    if (scanProcess.running || !reachable) return
    var args = ["scan"]
    if (folderId) args.push(String(folderId))
    scanProcess.label = folderId ? "Rescanning " + folderLabel(folderId) : "Rescanning all folders"
    scanProcess.command = helperCommand(args)
    scanProcess.running = true
  }

  function rescanAll() { rescan("") }

  function folderLabel(folderId) {
    for (var i = 0; i < folders.length; i++) if (folders[i].id === folderId) return folders[i].label
    return folderId
  }

  function openFolder(folder) {
    // Peers can influence folder paths (auto-accept). Only open an absolute
    // path without control characters (xdg-open sniffs URLs line by line),
    // and only if it is a directory, so a file is never handed to its
    // default application.
    var path = folder ? String(folder.path || "") : ""
    if (path.charAt(0) !== "/" || /[\x00-\x1f\x7f]/.test(path)) return
    Quickshell.execDetached(["uwsm-app", "--", "sh", "-c", '[ -d "$1" ] && exec xdg-open "$1"', "syncthing-open-folder", path])
  }

  // --- launchers -------------------------------------------------------

  function openWebUi() {
    var url = guiUrl !== "" ? guiUrl : "http://127.0.0.1:8384"
    if (webUiAsApp) Quickshell.execDetached(["omarchy-launch-or-focus-webapp", Model.webAppWindowPattern(url), Model.shellQuote(url)])
    else Quickshell.execDetached(["omarchy-launch-browser", url])
  }

  readonly property string tuiLabel: tuiCommand !== "" ? "Open " + tuiCommand.split(/\s+/)[0] : "Follow service log"

  function openTui() {
    var command = tuiCommand !== ""
      ? tuiCommand
      : "journalctl --user --follow --lines=200 --output=short --unit " + Model.shellQuote(serviceUnit)
    var appId = "org.omarchy.syncthing-tui"
    // omarchy-launch-or-focus focuses an existing window with this app id,
    // otherwise evals the launch string — hence the quoting.
    var launch = "omarchy-launch-tui --app-id=" + appId + " bash -c " + Model.shellQuote(command)
    Quickshell.execDetached(["omarchy-launch-or-focus", appId, launch])
  }

  // --- timers & processes ---------------------------------------------

  Timer {
    id: refreshTimer
    interval: (root.watching || root.active || root._desired !== -1 ? 2 : root.refreshIntervalSec) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2400
    onTriggered: root.actionStatus = ""
  }

  Timer {
    // Give up on the optimistic state if the service never gets there.
    id: settleTimeout
    interval: 20000
    onTriggered: root._desired = -1
  }

  Process {
    id: statusProcess
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) root.applyStatus(statusStdout.text)
      else root.lastError = root.elide(statusStderr.text || "Could not read Syncthing status")
    }
  }

  Process {
    id: controlProcess
    property string verb: ""
    stdout: StdioCollector { id: controlStdout; waitForEnd: true }
    stderr: StdioCollector { id: controlStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root._desired = -1
        root.lastError = root.elide(controlStderr.text || controlStdout.text || ("systemctl " + controlProcess.verb + " failed"))
      } else {
        if (controlProcess.verb === "restart") root.flash("Restarting Syncthing…")
        settleTimeout.restart()
      }
      root.refresh()
    }
  }

  Process {
    id: scanProcess
    property string label: ""
    stdout: StdioCollector { id: scanStdout; waitForEnd: true }
    stderr: StdioCollector { id: scanStderr; waitForEnd: true }
    onStarted: root.flash(scanProcess.label + "…")
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = root.elide(scanStderr.text || "Rescan failed")
      root.refresh()
    }
  }
}
