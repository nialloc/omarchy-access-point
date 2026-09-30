import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Access Point bar widget: the name of the access point you're connected to,
// and a panel listing every access point broadcasting that network so each
// one can be given a name. It follows whichever network is connected (or one
// pinned in settings) and stays hidden on networks served by a single access
// point, where there's nothing to tell apart. Everything comes from
// NetworkManager via nmcli; names live in ~/.config/omarchy/wotconn/labels.json
// and every access point ever detected is remembered in seen.json beside it.
Panel {
  id: root
  moduleName: "niall.wotconn"
  ipcTarget: "niall.wotconn"
  manageIpc: false

  // Empty follows the connected network; a name pins the widget to that one.
  readonly property string pinnedSsid: String(setting("ssid", "")).trim()
  readonly property bool showLabel: setting("showLabel", true) !== false
  readonly property int closedRefreshMs: Math.max(2, Number(setting("refreshIntervalSec", 5))) * 1000
  readonly property int openRefreshMs: 2000
  readonly property string labelsDir: Quickshell.env("HOME") + "/.config/omarchy/wotconn"
  readonly property string labelsPath: labelsDir + "/labels.json"
  readonly property string seenPath: labelsDir + "/seen.json"
  // How stale a remembered lastSeen may get before a scan rewrites seen.json.
  readonly property int seenWriteMs: 10 * 60 * 1000
  readonly property string connectScript: Qt.resolvedUrl("bin/wotconn-connect").toString().replace(/^file:\/\//, "")

  property var scan: []
  // The last network connected to, so the list stays put while Wi-Fi is down.
  property string lastSsid: ""
  property var labels: ({})
  property var seen: ({})
  // Until seen.json has been read, a scan mustn't write it: it would replace
  // the remembered access points with just the ones in range.
  property bool seenReady: false
  property bool loaded: false
  property string error: ""
  property bool scanning: false
  property string editingBssid: ""
  // Scan results that arrived mid-edit. Applying them would rebuild the rows
  // and throw away what's being typed, so they wait for the edit to end.
  property var pendingScan: null
  property int cursorIndex: 0
  property bool cursorActive: false
  property string connectingBssid: ""
  property string notice: ""

  readonly property var current: Model.current(scan)
  readonly property string ssid: pinnedSsid !== "" ? pinnedSsid
    : current && current.ssid ? current.ssid : lastSsid
  readonly property bool home: current !== null && ssid !== "" && current.ssid === ssid
  readonly property bool relevant: pinnedSsid !== "" || Model.isMultiAp(scan, ssid, seen)
  readonly property var rows: Model.rows(scan, ssid, labels, seen)
  readonly property int inRangeCount: rows.filter(function(r) { return r.inRange }).length
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property string barLabel: showLabel && home && !vertical ? Model.apName(current, labels) : ""
  readonly property string metaText: notice !== "" ? notice
    : connectingBssid !== "" ? "Switching to " + Model.apName({ bssid: connectingBssid }, labels) + "…"
    : error !== "" ? error
    : !loaded ? "Loading…"
    : Model.heroMeta(current, ssid) + (scanning ? " · scanning…" : "")

  function refresh() {
    if (listProc.running) { listProc.again = true; return }
    run(listProc, "no")
  }

  function rescan() {
    if (scanProc.running) return
    root.scanning = true
    run(scanProc, "yes")
  }

  function run(proc, rescanMode) {
    proc.output = ""
    proc.waiting = 2
    proc.command = ["nmcli", "-t", "-f", Model.SCAN_FIELDS, "device", "wifi", "list", "--rescan", rescanMode]
    proc.running = true
  }

  function listed(raw, exitCode) {
    if (exitCode !== 0) {
      root.error = "Can't read Wi-Fi from NetworkManager"
      return
    }
    var parsed = Model.parseScan(raw)
    root.error = ""
    if (root.editingBssid !== "") { root.pendingScan = parsed; return }
    applyScan(parsed)
  }

  function applyScan(parsed) {
    var connected = Model.current(parsed)
    if (connected && connected.ssid) root.lastSsid = connected.ssid
    var tracked = root.pinnedSsid !== "" ? root.pinnedSsid : root.lastSsid
    // Only networks the widget is for get remembered: a pinned one, or one
    // with more than one access point. A café's router never lands in seen.json.
    if (root.seenReady && tracked !== ""
        && (root.pinnedSsid !== "" || Model.isMultiAp(parsed, tracked, root.seen))) {
      var recorded = Model.recordScan(root.seen, parsed, tracked, Date.now(), root.seenWriteMs)
      root.seen = recorded.seen
      if (recorded.dirty) seenFile.setText(Model.serializeSeen(root.seen))
    }
    root.scan = parsed
    root.loaded = true
    if (root.cursorIndex >= root.rows.length) root.cursorIndex = Math.max(0, root.rows.length - 1)
  }

  function setLabel(bssid, name) {
    root.labels = Model.withLabel(root.labels, bssid, name)
    labelsFile.setText(Model.serializeLabels(root.labels))
  }

  // Drops an out-of-range access point from the list, name and all. One
  // that's in range would be back on the next scan, so that's refused.
  function forget(bssid) {
    var key = Model.normalizeBssid(bssid)
    if (!Model.canForget(rows.filter(function(r) { return r.bssid === key })[0])) return false
    if (root.labels[key] !== undefined) {
      root.labels = Model.without(root.labels, key)
      labelsFile.setText(Model.serializeLabels(root.labels))
    }
    if (root.seen[key] !== undefined) {
      root.seen = Model.without(root.seen, key)
      seenFile.setText(Model.serializeSeen(root.seen))
    }
    return true
  }

  function startEdit(bssid) {
    if (bssid === "") return
    root.editingBssid = bssid
  }

  function finishEdit(name) {
    var bssid = root.editingBssid
    if (bssid === "") return
    cancelEdit()
    setLabel(bssid, name)
  }

  function cancelEdit() {
    root.editingBssid = ""
    if (root.pendingScan) { applyScan(root.pendingScan); root.pendingScan = null }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Moving to another access point drops the connection for a few seconds.
  function connectTo(bssid) {
    var row = null
    for (var i = 0; i < rows.length; i++) if (rows[i].bssid === bssid) row = rows[i]
    if (!Model.canConnect(row) || connectProc.running) return
    root.connectingBssid = bssid
    connectProc.command = ["bash", root.connectScript, root.ssid, bssid]
    connectProc.running = true
  }

  function connected(exitCode, stderr) {
    var bssid = root.connectingBssid
    root.connectingBssid = ""
    if (exitCode !== 0) showNotice(String(stderr || "").trim() || "Couldn't switch access point")
    else showNotice("Now on " + Model.apName({ bssid: bssid }, root.labels))
    refresh()
  }

  function showNotice(text) {
    root.notice = text
    noticeTimer.restart()
  }

  function rowAt(index) {
    return index >= 0 && index < rows.length ? rows[index] : null
  }

  function moveCursor(dy) {
    if (rows.length === 0) return
    cursorIndex = Math.max(0, Math.min(rows.length - 1, cursorIndex + dy))
    scrollCursorIntoView()
  }

  function scrollCursorIntoView() {
    var item = rowColumn.children[cursorIndex]
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function handlePress(buttonCode) {
    if (buttonCode === Qt.RightButton) root.rescan()
    else root.toggle()
  }

  visible: relevant
  implicitWidth: buttons.implicitWidth
  implicitHeight: buttons.implicitHeight

  onRelevantChanged: if (!relevant && opened) close()

  Component.onCompleted: {
    labelsDirProc.running = true
    refresh()
  }
  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      if (panelFlick) panelFlick.contentY = 0
      refresh()
      rescan()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else if (editingBssid !== "") {
      cancelEdit()
    }
  }

  // FileView won't create a missing parent directory; do it once at startup,
  // well before the first label can be saved.
  Process {
    id: labelsDirProc
    command: ["mkdir", "-p", root.labelsDir]
  }

  FileView {
    id: labelsFile
    path: root.labelsPath
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onLoaded: root.labels = Model.parseLabels(text())
    onLoadFailed: root.labels = ({})
    onFileChanged: reload()
  }

  FileView {
    id: seenFile
    path: root.seenPath
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onLoaded: { root.seen = Model.parseSeen(text()); root.seenReady = true }
    onLoadFailed: { root.seen = ({}); root.seenReady = true }
    onFileChanged: reload()
  }

  // Each run finishes when both its output and its exit have arrived: the
  // two signals come in no guaranteed order.
  component ListProcess: Process {
    id: proc
    property string output: ""
    property int waiting: 0
    property int exitCode: 0
    signal done(string output, int exitCode)
    function finish() {
      if (--waiting === 0) done(output, exitCode)
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { proc.output = text; proc.finish() }
    }
    onExited: function(code) { proc.exitCode = code; proc.finish() }
  }

  // Cached results: cheap, used for polling.
  ListProcess {
    id: listProc
    property bool again: false
    onDone: function(output, exitCode) {
      root.listed(output, exitCode)
      if (again) { again = false; Qt.callLater(root.refresh) }
    }
  }

  // A fresh scan: takes a few seconds, run when the panel opens or on request.
  ListProcess {
    id: scanProc
    onDone: function(output, exitCode) {
      root.scanning = false
      root.listed(output, exitCode)
    }
  }

  Process {
    id: connectProc
    stderr: StdioCollector { id: connectStderr; waitForEnd: true }
    onExited: function(code) { root.connected(code, connectStderr.text) }
  }

  Timer { id: noticeTimer; interval: 4000; onTriggered: root.notice = "" }

  Timer {
    interval: root.opened ? root.openRefreshMs : root.closedRefreshMs
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function rescan(): string { root.rescan(); return "ok" }
    // e.g. omarchy-shell niall.wotconn current  ->  Office<TAB>02:00:00:00:00:01
    function current(): string {
      if (!root.home) return ""
      return (root.labels[root.current.bssid] || "") + "\t" + root.current.bssid
    }
    // One access point per line: bssid, label, signal (-1 when out of range), connected.
    // Out-of-range lines are the remembered ones.
    function list(): string {
      return root.rows.map(function(r) {
        return [r.bssid, r.label, r.signal, r.active ? "connected" : ""].join("\t")
      }).join("\n")
    }
    // e.g. omarchy-shell niall.wotconn connect 02:00:00:00:00:01
    function connect(bssid: string): string {
      var b = Model.normalizeBssid(bssid)
      var row = root.rows.filter(function(r) { return r.bssid === b })[0]
      if (!Model.canConnect(row)) return "error: " + (row && row.active ? "already connected" : "not in range")
      if (root.connectingBssid !== "") return "error: already switching"
      root.connectTo(b)
      return "ok"
    }
    // e.g. omarchy-shell niall.wotconn forget 02:00:00:00:00:05  (only when out of range)
    function forget(bssid: string): string {
      return root.forget(bssid) ? "ok" : "error: unknown or still in range"
    }
    // e.g. omarchy-shell niall.wotconn label 02:00:00:00:00:01 Office  (empty name removes it)
    function label(bssid: string, name: string): string {
      if (Model.normalizeBssid(bssid) === "") return "error: no bssid"
      root.setLabel(bssid, name)
      return "ok"
    }
  }

  RowLayout {
    id: buttons
    anchors.fill: parent
    spacing: 0

    BarIconButton {
      id: button
      bar: root.bar
      text: Model.AP_GLYPH
      dimmed: !root.home || root.error !== ""
      tooltipText: root.opened ? "" : Model.tooltip(root.current, root.ssid, root.labels)
      Layout.fillHeight: !root.vertical
      Layout.fillWidth: root.vertical
      onPressed: function(buttonCode) { root.handlePress(buttonCode) }
    }

    WidgetButton {
      id: labelButton
      bar: root.bar
      text: root.barLabel
      horizontalMargin: 2
      tooltipText: button.tooltipText
      Layout.fillHeight: true
      Layout.rightMargin: Style.space(6)
      onPressed: function(buttonCode) { root.handlePress(buttonCode) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: buttons
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The label editor owns the keyboard until Enter or Esc.
      blocked: root.editingBssid !== ""
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dy)
      }
      onActivateRequested: {
        var row = root.rowAt(root.cursorIndex)
        if (root.cursorActive && row) root.startEdit(row.bssid)
      }
      // x forgets an out-of-range access point, or clears an in-range one's name.
      onDeleteRequested: {
        var row = root.rowAt(root.cursorIndex)
        if (!root.cursorActive || !row) return
        if (Model.canForget(row)) root.forget(row.bssid)
        else if (row.label !== "") root.setLabel(row.bssid, "")
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.rescan()
        else if ((t === "e" || t === "E") && root.cursorActive) {
          var row = root.rowAt(root.cursorIndex)
          if (row) root.startEdit(row.bssid)
        } else if ((t === "c" || t === "C") && root.cursorActive) {
          var target = root.rowAt(root.cursorIndex)
          if (target) root.connectTo(target.bssid)
        }
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

          PanelHero {
            id: hero
            // Inside the icon/trailing components `root` resolves to PanelHero,
            // so they read panel state through these and `hero`.
            readonly property color glyphColor: root.home && root.error === "" ? Color.accent : root.dim
            readonly property bool busy: root.scanning
            signal rescanRequested()

            width: parent.width
            title: Model.heroTitle(root.current, root.ssid, root.labels)
            meta: root.metaText
            foreground: root.foreground
            fontFamily: root.fontFamily
            onRescanRequested: root.rescan()
            iconComponent: Component {
              Text {
                text: Model.AP_GLYPH
                color: hero.glyphColor
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: Model.RESCAN_GLYPH
                tooltipText: hero.busy ? "Scanning…" : "Scan again (r)"
                enabled: !hero.busy
                foreground: hero.foreground
                fontFamily: hero.fontFamily
                onClicked: hero.rescanRequested()
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          PanelSectionHeader {
            width: parent.width
            text: root.ssid + " access points" + (root.loaded ? " (" + root.inRangeCount + " in range)" : "")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.loaded && root.rows.length === 0
            width: parent.width
            text: "No " + root.ssid + " access points in range."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Column {
            id: rowColumn
            visible: root.rows.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.rows
              ApRow {
                required property var modelData
                required property int index
                width: rowColumn.width
                ap: modelData
                rowIndex: index
              }
            }
          }

          Text {
            visible: root.rows.length > 0
            width: parent.width
            text: "Click a row to name it · c connects · x forgets"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component ApRow: CursorSurface {
    id: row
    property var ap: null
    property int rowIndex: 0
    readonly property string bssid: ap ? ap.bssid : ""
    readonly property bool editing: root.editingBssid !== "" && root.editingBssid === bssid
    readonly property bool labelled: ap ? ap.label !== "" : false
    readonly property bool connecting: root.connectingBssid !== "" && root.connectingBssid === bssid

    hasCursor: !editing && root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    implicitHeight: rowLayout.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: { root.cursorActive = true; root.cursorIndex = row.rowIndex }
      onClicked: if (!row.editing) root.startEdit(row.bssid)
    }

    RowLayout {
      id: rowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: Model.signalGlyph(row.ap ? row.ap.signal : -1)
        color: row.ap && row.ap.active ? Color.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.preferredWidth: Style.font.icon * 1.4
        horizontalAlignment: Text.AlignHCenter
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        visible: !row.editing
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.labelled ? row.ap.label : row.bssid
          color: row.ap && row.ap.active ? Color.accent
            : row.labelled && row.ap.inRange ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.connecting ? "Switching…" : row.ap ? Model.rowSubtitle(row.ap, Date.now()) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      TextField {
        id: editor
        visible: row.editing
        Layout.fillWidth: true
        placeholderText: "Name for " + row.bssid
        foreground: root.foreground
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.controlPaddingY
        function begin() {
          text = row.ap ? row.ap.label : ""
          selectAll()
          Qt.callLater(forceActiveFocus)
        }
        onAccepted: root.finishEdit(text)
        Keys.onEscapePressed: root.cancelEdit()
        onVisibleChanged: if (visible) begin()
        Component.onCompleted: if (visible) begin()
        // Clicking elsewhere in the panel abandons the edit.
        onActiveFocusChanged: if (!activeFocus && row.editing) root.cancelEdit()
      }

      PanelActionButton {
        visible: !row.editing && Model.canConnect(row.ap)
        enabled: root.connectingBssid === ""
        iconText: Model.CONNECT_GLYPH
        tooltipText: "Connect to this access point (c)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.connectTo(row.bssid)
      }

      PanelActionButton {
        visible: !row.editing && Model.canForget(row.ap)
        iconText: Model.FORGET_GLYPH
        tooltipText: "Forget this access point (x)"
        foreground: root.foreground
        hoverColor: root.bar ? root.bar.urgent : Color.urgent
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.forget(row.bssid)
      }

      PanelActionButton {
        visible: !row.editing
        iconText: Model.EDIT_GLYPH
        tooltipText: row.labelled ? "Rename" : "Name this access point"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: root.startEdit(row.bssid)
      }
    }
  }
}
