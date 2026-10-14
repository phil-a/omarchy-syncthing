import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry and popup for Syncthing.
//
// Bar icon: left click opens the panel, middle click rescans every folder,
// right click opens the web UI.
//
// Panel keys: arrows move, Enter activates, s rescans all, w opens the web
// UI, t opens the TUI, Esc closes.
Panel {
  id: root
  moduleName: "syncthing-status.widget"
  ipcTarget: "syncthing-status.widget"
  manageIpc: false

  property string focusSection: "header"
  property int actionIndex: 0
  property int folderIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string stateKey: sync.overall.key
  readonly property bool dimmed: stateKey === "stopped" || stateKey === "offline"
  readonly property color barIconColor: stateKey === "error" ? urgent : (dimmed ? Qt.darker(barForeground, 1.55) : barForeground)
  readonly property color heroIconColor: stateKey === "error" ? urgent : (dimmed ? dim : foreground)

  readonly property var actions: [
    { key: "rescan", glyph: Model.GLYPHS.rescan, tip: "Rescan all folders (s)", enabled: sync.reachable && sync.folders.length > 0 },
    { key: "restart", glyph: Model.GLYPHS.restart, tip: "Restart Syncthing", enabled: sync.running && !sync.busy },
    { key: "web", glyph: Model.GLYPHS.web, tip: "Open web UI (w)", enabled: sync.reachable },
    { key: "tui", glyph: Model.GLYPHS.terminal, tip: sync.tuiLabel + " (t)", enabled: true }
  ]

  function runAction(key) {
    if (key === "rescan") sync.rescanAll()
    else if (key === "restart") sync.restart()
    else if (key === "web") { sync.openWebUi(); root.close() }
    else if (key === "tui") { sync.openTui(); root.close() }
  }

  function sections() {
    var list = ["header", "actions"]
    if (sync.folders.length > 0) list.push("folders")
    return list
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    var list = sections()
    if (list.indexOf(focusSection) < 0) focusSection = "header"
    if (focusSection === "actions" && dx !== 0) {
      actionIndex = Math.max(0, Math.min(actions.length - 1, actionIndex + dx))
      return
    }
    if (dy === 0) return
    if (focusSection === "folders") {
      var next = folderIndex + dy
      if (next < 0) { focusSection = "actions"; return }
      folderIndex = Math.min(sync.folders.length - 1, next)
      scrollCursorIntoView()
      return
    }
    var at = list.indexOf(focusSection) + dy
    if (at < 0 || at >= list.length) return
    focusSection = list[at]
    if (focusSection === "folders") folderIndex = 0
    if (focusSection === "header" && panelFlick) panelFlick.contentY = 0
    scrollCursorIntoView()
  }

  function activateCursor() {
    if (focusSection === "header") sync.toggleRunning()
    else if (focusSection === "actions") {
      var action = actions[actionIndex]
      if (action && action.enabled) runAction(action.key)
    } else if (focusSection === "folders") {
      var folder = sync.folders[folderIndex]
      if (folder) { sync.openFolder(folder); root.close() }
    }
  }

  function scrollCursorIntoView() {
    if (!panelFlick || focusSection !== "folders" || !folderColumn) return
    var item = folderColumn.children[folderIndex]
    if (!item) return
    Qt.callLater(function() {
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    focusSection = "header"
    if (panelFlick) panelFlick.contentY = 0
    sync.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: sync
    settings: root.settings
    watching: root.opened
  }

  Connections {
    target: sync
    function onFoldersChanged() {
      if (root.folderIndex >= sync.folders.length) root.folderIndex = Math.max(0, sync.folders.length - 1)
      if (sync.folders.length === 0 && root.focusSection === "folders") root.focusSection = "actions"
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { sync.refresh(); return "ok" }
    function start(): string { sync.start(); return "ok" }
    function stop(): string { sync.stop(); return "ok" }
    function restart(): string { sync.restart(); return "ok" }
    function rescan(): string { sync.rescanAll(); return "ok" }
    function webui(): string { sync.openWebUi(); return "ok" }
    function tui(): string { sync.openTui(); return "ok" }
    function status(): string { return sync.overall.text }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: sync.overall.glyph
    foreground: root.barIconColor
    tooltipText: root.opened ? "" : Model.tooltip(sync.status)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) sync.openWebUi()
      else if (buttonCode === Qt.MiddleButton) sync.rescanAll()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") sync.rescanAll()
        else if (t === "w" || t === "W") root.runAction("web")
        else if (t === "t" || t === "T") root.runAction("tui")
        else if (t === "r") sync.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.cursorActive && root.focusSection === "header"
            function focusHero() { root.cursorActive = true; root.focusSection = "header" }

            PanelHero {
              id: hero
              width: parent.width
              title: "Syncthing"
              meta: sync.overall.text
              detail: sync.reachable ? String(sync.status.version || "") : ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: sync.overall.glyph
                  color: root.heroIconColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: sync.running
                  busy: sync.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: sync.toggleRunning()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: sync.running ? "Stop Syncthing" : "Start Syncthing"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: sync.actionStatus !== "" ? sync.actionStatus : sync.lastError
            color: sync.actionStatus === "" && sync.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Row {
            id: actionRow
            spacing: Style.space(6)

            Repeater {
              model: root.actions
              PanelActionButton {
                required property var modelData
                required property int index
                iconText: modelData.glyph
                tooltipText: modelData.tip
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: modelData.enabled
                hasCursor: root.cursorActive && root.focusSection === "actions" && root.actionIndex === index
                onHovered: function(on) {
                  if (!on) return
                  root.cursorActive = true
                  root.focusSection = "actions"
                  root.actionIndex = index
                }
                onClicked: root.runAction(modelData.key)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !sync.reachable
            width: parent.width
            text: sync.running
              ? "Waiting for Syncthing to answer on " + (sync.guiUrl || "its GUI address") + "…"
              : "Syncthing is stopped. Use the switch above to start it."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            visible: sync.reachable
            foreground: root.foreground
          }

          Column {
            visible: sync.reachable
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "FOLDERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: sync.folders.length === 0
              width: parent.width
              text: "No folders shared yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Column {
              id: folderColumn
              visible: sync.folders.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: sync.folders
                FolderRow {
                  required property var modelData
                  required property int index
                  width: folderColumn.width
                  folder: modelData
                  rowIndex: index
                }
              }
            }
          }

          PanelSeparator {
            visible: sync.reachable && sync.devices.length > 0
            foreground: root.foreground
          }

          Column {
            visible: sync.reachable && sync.devices.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "DEVICES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: sync.devices
                DeviceRow {
                  required property var modelData
                  width: parent.width
                  device: modelData
                }
              }
            }
          }
        }
      }
    }
  }

  component FolderRow: CursorSurface {
    id: folderRow
    property var folder: null
    property int rowIndex: 0
    readonly property bool problem: Model.folderHasProblem(folder)

    hasCursor: root.cursorActive && root.focusSection === "folders" && root.folderIndex === rowIndex
    foreground: root.foreground
    implicitHeight: Math.max(folderContent.implicitHeight, rescanButton.implicitHeight) + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: {
        root.cursorActive = true
        root.focusSection = "folders"
        root.folderIndex = folderRow.rowIndex
      }
      onClicked: { sync.openFolder(folderRow.folder); root.close() }
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.folderGlyph(folderRow.folder)
        color: folderRow.problem ? root.urgent : (folderRow.folder && folderRow.folder.paused ? root.dim : root.foreground)
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: folderContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: folderRow.folder ? folderRow.folder.label : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.folderMeta(folderRow.folder)
          color: folderRow.problem ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: folderRow.problem && text !== ""
          text: folderRow.folder ? String(folderRow.folder.error || "") : ""
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: folderRow.folder ? Model.shortPath(folderRow.folder.path, sync.home) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      PanelActionButton {
        id: rescanButton
        iconText: Model.GLYPHS.rescan
        tooltipText: "Rescan " + (folderRow.folder ? folderRow.folder.label : "")
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !!folderRow.folder && !folderRow.folder.paused && !sync.busy
        Layout.alignment: Qt.AlignVCenter
        onClicked: sync.rescan(folderRow.folder.id)
      }
    }
  }

  component DeviceRow: Item {
    id: deviceRow
    property var device: null

    implicitHeight: deviceContent.implicitHeight + Style.spacing.rowPaddingX

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: Model.deviceGlyph(deviceRow.device)
        color: deviceRow.device && deviceRow.device.connected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: deviceContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: deviceRow.device ? deviceRow.device.name : ""
          color: deviceRow.device && deviceRow.device.connected ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: Model.deviceMeta(deviceRow.device)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
