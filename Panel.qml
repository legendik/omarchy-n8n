import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "legendik.n8n"
  ipcTarget: "legendik.n8n"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent:     bar ? bar.urgent     : Color.urgent
  readonly property color dim:        Qt.darker(foreground, 1.55)
  readonly property color success:    Qt.rgba(0.3, 0.8, 0.4, 1.0)
  readonly property color warning:    Qt.rgba(0.9, 0.7, 0.2, 1.0)
  readonly property color running:    Qt.rgba(0.3, 0.6, 1.0, 1.0)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // 0 = Executions, 1 = Workflows
  property int activeTab: 0

  // Vim-style selection cursor
  property int selectedIndex: 0
  // True while waiting for a second "g" to complete the "gg" (go to top) motion
  property bool _gPending: false

  onActiveTabChanged: { selectedIndex = 0 }

  Service { id: n8n; settings: root.settings }

  implicitWidth:  button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      selectedIndex = 0
      n8n.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  function relativeTime(value) {
    var then = new Date(String(value || "")).getTime()
    if (!isFinite(then)) return ""
    var seconds = Math.max(0, Math.floor((Date.now() - then) / 1000))
    if (seconds < 60)      return "just now"
    if (seconds < 3600)    return Math.floor(seconds / 60) + "m ago"
    if (seconds < 86400)   return Math.floor(seconds / 3600) + "h ago"
    if (seconds < 2592000) return Math.floor(seconds / 86400) + "d ago"
    return Math.floor(seconds / 2592000) + "mo ago"
  }

  function statusGlyph(status) {
    if (status === "success")  return "󰄬"
    if (status === "error" || status === "crashed") return "󰅖"
    if (status === "running")  return "󰑮"
    if (status === "waiting")  return "󱑬"
    return "󰝦"
  }

  function statusColor(status) {
    if (status === "success")  return root.success
    if (status === "error" || status === "crashed") return root.urgent
    if (status === "running")  return root.running
    if (status === "waiting")  return root.warning
    return root.dim
  }

  function barLabel() {
    if (n8n.state === "loading") return ""
    if (n8n.state === "error")   return "!"
    var parts = []
    if (n8n.totalRunning > 0) parts.push("⟳" + n8n.totalRunning)
    if (n8n.totalFailed  > 0) parts.push("✗" + n8n.totalFailed)
    if (parts.length > 0) return parts.join(" ")
    return String(n8n.totalActive)
  }

  function barColor() {
    if (n8n.hasFailure) return root.urgent
    if (n8n.hasRunning) return root.running
    return root.foreground
  }

  function currentInstance() {
    if (n8n.instances.length === 0) return null
    var idx = Math.min(n8n.activeInstance, n8n.instances.length - 1)
    return n8n.instances[idx]
  }

  function listItems() {
    var inst = currentInstance()
    if (!inst) return []
    return activeTab === 0 ? (inst.executions || []) : (inst.workflows || [])
  }

  function moveSelection(delta) {
    var items = listItems()
    if (items.length === 0) return
    selectedIndex = Math.max(0, Math.min(items.length - 1, selectedIndex + delta))
    Qt.callLater(scrollToSelected)
  }

  function scrollToSelected() {
    var items = listItems()
    if (items.length === 0 || !tabLoader.item) return
    var totalH = tabLoader.item.implicitHeight
    var itemH = totalH / items.length
    var itemY = selectedIndex * itemH
    var viewH = tabFlickable.height
    if (itemY < tabFlickable.contentY)
      tabFlickable.contentY = itemY
    else if (itemY + itemH > tabFlickable.contentY + viewH)
      tabFlickable.contentY = Math.max(0, itemY + itemH - viewH)
  }

  function openSelected() {
    var inst = currentInstance()
    if (!inst) return
    var items = listItems()
    if (selectedIndex < 0 || selectedIndex >= items.length) return
    var item = items[selectedIndex]
    var url
    if (activeTab === 0)
      url = inst.url + "/workflow/" + item.workflowId + "/executions/" + item.id
    else
      url = inst.url + "/workflow/" + item.id
    root.openUrl(url)
  }

  // Open a URL in the user's default browser via the omarchy CLI.
  function openUrl(url) {
    Quickshell.execDetached(["omarchy", "launch", "browser", url])
  }

  // ── Bar widget ─────────────────────────────────────────────────────────────

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: n8n.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) n8n.refresh()
      else root.toggle()
    }

    iconComponent: Component {
      Item {
        anchors.fill: parent

        Text {
          anchors.centerIn: parent
          text: "󱓛"
          color: n8n.hasFailure ? root.urgent : (n8n.hasRunning ? root.running : root.foreground)
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
        }

        Rectangle {
          visible: n8n.state === "ready" && (n8n.hasFailure || n8n.hasRunning)
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.rightMargin: -Style.space(1)
          anchors.topMargin: -Style.space(1)
          width: badgeText.implicitWidth + Style.space(4)
          height: Style.space(14)
          radius: Style.space(7)
          color: n8n.hasFailure ? root.urgent : root.running

          Text {
            id: badgeText
            anchors.centerIn: parent
            text: n8n.hasFailure ? String(n8n.totalFailed) : String(n8n.totalRunning)
            color: "#000000"
            font.family: root.fontFamily
            font.pixelSize: Style.space(9)
            font.bold: true
          }
        }
      }
    }
  }

  // ── IPC ───────────────────────────────────────────────────────────────────

  IpcHandler {
    target: root.ipcTarget
    function open(): void    { root.open() }
    function close(): void   { root.close() }
    function toggle(): void  { root.toggle() }
    function refresh(): string { n8n.refresh(); return "ok" }
    function status(): string  { return n8n.state }
  }

  // ── Panel ─────────────────────────────────────────────────────────────────

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(panelBody.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.openSelected()
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveSelection(dy)
        else if (dx !== 0) root.activeTab = Math.max(0, Math.min(1, root.activeTab + dx))
      }
      onTabRequested: function(direction) {
        root.activeTab = Math.max(0, Math.min(1, root.activeTab + direction))
      }
      onTextKey: function(text) {
        if (text === "r" || text === "R") n8n.refresh()
        if (text === "]") root.activeTab = Math.min(1, root.activeTab + 1)
        if (text === "[") root.activeTab = Math.max(0, root.activeTab - 1)
        if (text === "G") {
          root._gPending = false
          var items = root.listItems()
          root.selectedIndex = Math.max(0, items.length - 1)
          Qt.callLater(root.scrollToSelected)
          return
        }
        if (text === "g") {
          if (root._gPending) {
            root._gPending = false
            gPendingTimer.stop()
            root.selectedIndex = 0
            Qt.callLater(root.scrollToSelected)
          } else {
            root._gPending = true
            gPendingTimer.restart()
          }
          return
        }
        root._gPending = false
      }

      Timer {
        id: gPendingTimer
        interval: 600
        onTriggered: root._gPending = false
      }

      Column {
        id: panelBody
        width: parent.width
        spacing: 0

        // ── Hero ─────────────────────────────────────────────────────────
        PanelHero {
          width: parent.width
          title: "n8n"
          meta: {
            if (n8n.state === "loading") return "Loading…"
            if (n8n.state === "error")   return n8n.message
            var inst = root.currentInstance()
            if (!inst) return "No instances"
            var s = inst.name + " · " + inst.activeCount + " active"
            if (inst.runningCount > 0) s += " · " + inst.runningCount + " running"
            if (inst.failedCount  > 0) s += " · " + inst.failedCount + " failed"
            return s
          }
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: "󱓛"
              color: n8n.hasFailure ? root.urgent : (n8n.hasRunning ? root.running : root.foreground)
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              SequentialAnimation on opacity {
                running: n8n.hasRunning && !n8n.hasFailure
                NumberAnimation { to: 0.4; duration: 800 }
                NumberAnimation { to: 1.0; duration: 800 }
                loops: Animation.Infinite
              }
            }
          }
        }

        // ── Instance tabs (only when >1 instance) ─────────────────────
        Row {
          visible: n8n.instances.length > 1
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: n8n.instances
            delegate: Item {
              required property var modelData
              required property int index
              implicitWidth: instTab.implicitWidth + Style.space(20)
              implicitHeight: instTab.implicitHeight + Style.space(8)

              BorderSurface {
                anchors.fill: parent
                color: index === n8n.activeInstance
                  ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  : "transparent"
                borderSpec: Border.flat(Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, index === n8n.activeInstance ? 0.3 : 0.1), 1)
                radius: Style.cornerRadius
              }
              Text {
                id: instTab
                anchors.centerIn: parent
                text: modelData.name
                color: index === n8n.activeInstance ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { n8n.activeInstance = index }
              }
            }
          }
        }

        // ── Error / no-config state ───────────────────────────────────
        Item {
          visible: n8n.state === "error" || n8n.instances.length === 0
          width: parent.width
          implicitHeight: errText.implicitHeight + Style.space(32)
          Text {
            id: errText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(20)
            text: n8n.message !== "" ? n8n.message : "Run omarchy-n8n-setup to add an instance."
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }

        // ── Tab bar ────────────────────────────────────────────────────
        Row {
          visible: n8n.state === "ready" && n8n.instances.length > 0
          width: parent.width
          spacing: 0

          Repeater {
            model: ["Executions", "Workflows"]
            delegate: Item {
              required property string modelData
              required property int index
              width: parent.width / 2
              implicitHeight: tabLabel.implicitHeight + Style.space(12)

              Rectangle {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - Style.space(4)
                height: 2
                color: root.activeTab === index ? root.foreground : "transparent"
                radius: 1
              }
              Text {
                id: tabLabel
                anchors.centerIn: parent
                text: modelData
                color: root.activeTab === index ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: root.activeTab === index
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.activeTab = index }
              }
            }
          }
        }

        PanelSeparator { visible: n8n.state === "ready"; foreground: root.foreground; width: parent.width }

        // ── Tab content ────────────────────────────────────────────────
        Item {
          id: tabScroll
          visible: n8n.state === "ready" && n8n.instances.length > 0
          width: parent.width
          implicitHeight: Math.min(tabLoader.implicitHeight, Style.space(380))
          clip: true

          Flickable {
            id: tabFlickable
            anchors.fill: parent
            contentWidth: width
            contentHeight: tabLoader.implicitHeight
            boundsBehavior: Flickable.StopAtBounds

            Loader {
              id: tabLoader
              width: tabScroll.width
              sourceComponent: root.activeTab === 0 ? executionsTab : workflowsTab
            }

            ScrollBar.vertical: ScrollBar {
              policy: ScrollBar.AsNeeded
            }
          }
        }

        // ── Footer ─────────────────────────────────────────────────────
        Text {
          visible: n8n.fetchedAt !== ""
          width: parent.width
          text: n8n.loading ? "Refreshing…" : ("updated " + root.relativeTime(n8n.fetchedAt) + "  ·  j/k navigate  ·  h/l tabs  ·  gg/G top/bottom  ·  enter open  ·  r refresh")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ── Tab: Executions ────────────────────────────────────────────────────────

  Component {
    id: executionsTab
    Column {
      width: parent ? parent.width : 0
      spacing: 0

      property var executions: {
        var inst = root.currentInstance()
        return inst ? (inst.executions || []) : []
      }

      Text {
        visible: parent.executions.length === 0
        width: parent.width
        text: "No recent executions."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      Repeater {
        model: parent.executions
        delegate: Item {
          required property var modelData
          required property int index
          width: parent ? parent.width : 0
          implicitHeight: execRow.implicitHeight + Style.space(10)

          // Selection highlight
          Rectangle {
            anchors.fill: parent
            color: index === root.selectedIndex && root.activeTab === 0
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              : "transparent"
            radius: Style.cornerRadius
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              root.selectedIndex = index
              var inst = root.currentInstance()
              if (inst) root.openUrl(inst.url + "/workflow/" + modelData.workflowId + "/executions/" + modelData.id)
            }
          }

          RowLayout {
            id: execRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(12)
            spacing: Style.space(8)

            Text {
              text: root.statusGlyph(String(modelData.status || ""))
              color: root.statusColor(String(modelData.status || ""))
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
              Layout.alignment: Qt.AlignVCenter
              SequentialAnimation on opacity {
                running: String(modelData.status || "") === "running"
                NumberAnimation { to: 0.3; duration: 600 }
                NumberAnimation { to: 1.0; duration: 600 }
                loops: Animation.Infinite
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(1)
              Text {
                Layout.fillWidth: true
                text: String(modelData.workflowName || "Workflow " + modelData.workflowId)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
              Text {
                Layout.fillWidth: true
                text: {
                  var parts = [String(modelData.status || "")]
                  if (modelData.mode && modelData.mode !== "") parts.push(modelData.mode)
                  parts.push(root.relativeTime(modelData.startedAt))
                  if (modelData.id) parts.push("#" + modelData.id)
                  return parts.join(" · ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
            }

            Text { text: "󰅂"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.body }
          }
        }
      }
    }
  }

  // ── Tab: Workflows ─────────────────────────────────────────────────────────

  Component {
    id: workflowsTab
    Column {
      width: parent ? parent.width : 0
      spacing: 0

      property var workflows: {
        var inst = root.currentInstance()
        return inst ? (inst.workflows || []) : []
      }

      Text {
        visible: n8n.toggleError !== ""
        width: parent.width
        text: n8n.toggleError
        color: root.urgent
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        topPadding: Style.space(4)
        bottomPadding: Style.space(4)
      }

      Text {
        visible: parent.workflows.length === 0
        width: parent.width
        text: "No workflows found."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
      }

      Repeater {
        model: parent.workflows
        delegate: Item {
          required property var modelData
          required property int index
          width: parent ? parent.width : 0
          implicitHeight: wfRow.implicitHeight + Style.space(10)

          // Selection highlight
          Rectangle {
            anchors.fill: parent
            color: index === root.selectedIndex && root.activeTab === 1
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              : "transparent"
            radius: Style.cornerRadius
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.selectedIndex = index }
          }

          RowLayout {
            id: wfRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(8)

            Rectangle {
              width: Style.space(8); height: Style.space(8); radius: width / 2
              color: modelData.active ? root.success : root.dim
              Layout.alignment: Qt.AlignVCenter
            }

            Text {
              Layout.fillWidth: true
              text: String(modelData.name || "")
              color: modelData.active ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
              textFormat: Text.PlainText
            }

            BorderSurface {
              implicitWidth: toggleLabel.implicitWidth + Style.space(16)
              implicitHeight: toggleLabel.implicitHeight + Style.space(6)
              color: modelData.active
                ? Qt.rgba(root.success.r, root.success.g, root.success.b, 0.12)
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
              borderSpec: Border.flat(modelData.active
                ? Qt.rgba(root.success.r, root.success.g, root.success.b, 0.35)
                : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.2), 1)
              radius: Style.cornerRadius
              Text {
                id: toggleLabel
                anchors.centerIn: parent
                text: modelData.active ? "Active" : "Inactive"
                color: modelData.active ? root.success : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  var inst = root.currentInstance()
                  if (inst) n8n.toggleWorkflow(inst.id, String(modelData.id), !modelData.active)
                }
              }
            }
          }
        }
      }
    }
  }
}
