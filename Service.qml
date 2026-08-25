import QtQuick
import Quickshell
import Quickshell.Io

// n8n data service. Polls configured instances and exposes aggregated
// workflow + execution state as stable QML properties.
Item {
  id: root

  property var settings: ({})
  property bool loading: false
  property string state: "loading"
  property string message: "Loading…"
  property string toggleError: ""

  // Aggregated across all instances
  property int totalActive: 0
  property int totalRunning: 0
  property int totalFailed: 0
  property var instances: []
  property string fetchedAt: ""

  // Active instance index (for panel navigation)
  property int activeInstance: 0

  // Bar alarm: red when any failure, amber when something running
  readonly property bool hasFailure: totalFailed > 0
  readonly property bool hasRunning: totalRunning > 0
  readonly property bool alarming: hasFailure

  property string _stdout: ""
  property string _stderr: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (value === true || value === false) return value
    var text = String(value).toLowerCase()
    return text === "true" || text === "yes" || text === "on" || text === "1"
  }

  function helperPath(name) {
    return Qt.resolvedUrl(name).toString().replace(/^file:\/\//, "")
  }

  function refresh() {
    if (fetchProcess.running) return
    loading = true
    _stdout = ""
    _stderr = ""
    fetchProcess.command = [
      helperPath("omarchy-n8n-fetch"),
      "--max-executions", String(intSetting("maxExecutions", 20, 5, 50)),
      "--notify-failure", boolSetting("notifyOnFailure", true) ? "true" : "false"
    ]
    fetchProcess.running = true
  }

  function toggleWorkflow(instanceId, workflowId, makeActive) {
    var toggleCmd = [
      helperPath("omarchy-n8n-toggle"),
      instanceId,
      workflowId,
      makeActive ? "true" : "false"
    ]
    toggleProcess.command = toggleCmd
    toggleProcess.running = true
  }

  function apply(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
      state = String(data.state || "error")
      message = String(data.message || "")
      totalActive = Number(data.totalActive || 0)
      totalRunning = Number(data.totalRunning || 0)
      totalFailed = Number(data.totalFailed || 0)
      instances = Array.isArray(data.instances) ? data.instances : []
      fetchedAt = String(data.fetchedAt || "")
    } catch (e) {
      state = "error"
      message = "Failed to parse response."
    }
  }

  visible: false

  Timer {
    interval: root.intSetting("refreshIntervalSec", 30, 10, 300) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Refresh after a toggle so the UI reflects the new state quickly
  Timer {
    id: postToggleRefresh
    interval: 800
    repeat: false
    running: false
    onTriggered: root.refresh()
  }

  Timer {
    id: toggleErrorClear
    interval: 6000
    repeat: false
    running: false
    onTriggered: root.toggleError = ""
  }

  Process {
    id: fetchProcess
    running: false
    command: []
    onExited: function(exitCode) {
      root.loading = false
      var stdout = String(output.text || root._stdout || "")
      var stderr = String(errors.text || root._stderr || "").trim()
      if (stdout.trim() !== "") {
        root.apply(stdout)
      } else {
        root.state = "error"
        root.message = stderr !== "" ? stderr : "n8n fetch failed."
      }
    }
    stdout: StdioCollector { id: output; waitForEnd: true }
    stderr: StdioCollector { id: errors; waitForEnd: true }
  }

  Process {
    id: toggleProcess
    running: false
    command: []
    onExited: function(exitCode) {
      var stdout = String(toggleOutput.text || "")
      if (exitCode === 0) {
        root.toggleError = ""
      } else {
        var msg = "Toggle failed."
        try {
          var data = JSON.parse(stdout)
          if (data && data.message) msg = "Toggle failed: " + data.message
        } catch (e) {}
        root.toggleError = msg
        toggleErrorClear.restart()
      }
      postToggleRefresh.start()
    }
    stdout: StdioCollector { id: toggleOutput; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }
}
