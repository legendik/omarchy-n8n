import QtQuick
import Quickshell
import Quickshell.Io

// n8n data service. Polls configured instances over the n8n REST API and
// exposes aggregated workflow + execution state as stable QML properties.
//
// Fetching/toggling happens in-process via QML's XMLHttpRequest, so there's
// no curl/argv exposure and no JSON-processing subprocess pipeline for the
// network side. Writes to instances.json/.last-state.json go through
// FileView's built-in atomic-write handling (temp file + rename).
//
// Reads of those same two files are NOT done via FileView.text()/.data():
// Quickshell's FileView reader opens files with a plain blocking QFile, so
// it follows symlinks and can hang forever reading from a FIFO. Since both
// paths are predictable and user-writable, a pre-planted symlink or special
// file at either path would defeat any read done that way. Instead FileView
// here is watcher-only (used solely for its onFileChanged/watchChanges
// signal) and actual content is read via `dd iflag=nofollow,nonblock`
// (spawned through runProcess()), mirroring the bounded/no-follow read the
// original bash implementation used.
//
// The other external processes this file spawns are `secret-tool`
// (Qt/QML has no libsecret bindings), `stat`/`dd` for the bounded reads
// above, and, on failure, `notify-send` / `omarchy launch browser` /
// `xdg-open` for desktop alerts.
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

  // Raw [{id,name,url}, ...] parsed from instances.json; kept around so
  // toggleWorkflow() can resolve an instance's URL without re-reading it.
  property var _rawInstances: []
  property bool _fetchInFlight: false

  readonly property string _configDir: {
    var xdg = Quickshell.env("XDG_CONFIG_HOME")
    var base = (xdg && String(xdg).length > 0) ? String(xdg) : (Quickshell.env("HOME") + "/.config")
    return base + "/omarchy-n8n"
  }
  readonly property string _instancesPath: _configDir + "/instances.json"
  readonly property string _statePath: _configDir + "/.last-state.json"

  readonly property int _maxResponseBytes: 10 * 1024 * 1024   // workflows/executions GETs
  readonly property int _maxToggleResponseBytes: 65536         // toggle POST body
  readonly property int _requestTimeoutMs: 8000
  readonly property int _maxNotificationsPerRun: 20
  readonly property int _maxItemsPerInstance: 200
  readonly property int _maxConfigBytes: 262144                // instances.json / .last-state.json read cap (256 KiB)
  readonly property int _maxInstances: 20                      // parallel secret-tool + HTTP jobs cap
  readonly property int _maxApiKeyBytes: 4096                  // secret-tool stdout cap

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

  // Instance/workflow ids are used as secret-tool account names and get
  // spliced into request URLs and notification links, so keep them
  // restricted to a strict, predictable shape.
  function validId(id) {
    return typeof id === "string" && /^[A-Za-z0-9_-]+$/.test(id)
  }

  // ── Subprocess helper ─────────────────────────────────────────────────────
  // Shared by the keyring lookup and the (non-sensitive) notification/browser
  // launches below. Resolves with { exitCode, output }; exitCode is null if
  // the process could not even be started (e.g. the binary is missing),
  // distinct from a normal non-zero exit.
  Component {
    id: _processComponent
    Process {
      property string outputText: collector.text
      stdout: StdioCollector { id: collector; waitForEnd: true }
    }
  }

  function runProcess(command) {
    return new Promise(function(resolve) {
      var settled = false
      var p = _processComponent.createObject(root, { command: command })
      function finish(exitCode) {
        if (settled) return
        settled = true
        var output = String(p.outputText || "")
        p.destroy()
        resolve({ exitCode: exitCode, output: output })
      }
      p.exited.connect(function(exitCode) { finish(exitCode) })
      p.runningChanged.connect(function() {
        // Covers the binary-missing case: QProcess::errorOccurred(FailedToStart)
        // flips running back to false without ever emitting exited().
        if (!p.running) finish(null)
      })
      p.running = true
    })
  }

  // Reads a regular file with a byte cap, no symlink-following, and no
  // blocking on a FIFO/special file — the same guarantee the original bash
  // helper provided, reimplemented here because FileView.text()/.data()
  // offer none of this (see the header comment above).
  //
  // `dd iflag=nofollow,nonblock` fails immediately (ELOOP) if the final path
  // component is a symlink, and fails/returns short (EAGAIN) rather than
  // block if it's a FIFO with no writer. `bs=<cap+1> count=1` also bounds
  // the read itself to one cap-sized-plus-one block, so an oversized
  // regular file can't be read in full before we notice it's too big.
  //
  // Resolves to null if the file is missing, unreadable, a symlink, a
  // special file, or larger than maxBytes; otherwise resolves to its text.
  function readBoundedFile(path, maxBytes) {
    var ddArgs = [
      "dd", "if=" + path, "iflag=nofollow,nonblock",
      "bs=" + (maxBytes + 1), "count=1", "status=none"
    ]
    return root.runProcess(ddArgs).then(function(r) {
      if (r.exitCode !== 0) return null
      if (_byteLength(r.output) > maxBytes) return null
      return r.output
    })
  }

  function lookupApiKey(id) {
    return root.runProcess(["secret-tool", "lookup", "service", "omarchy-n8n", "account", id])
      .then(function(r) {
        if (r.exitCode !== 0) return null
        var text = r.output.replace(/\n+$/, "")
        // Bound the key before retaining it: a tampered keyring or a compromised
        // secret-tool build should not be able to buffer an arbitrarily large value.
        if (_byteLength(text) > root._maxApiKeyBytes) return null
        return text.length > 0 ? text : null
      })
  }

  // ── HTTP ──────────────────────────────────────────────────────────────────

  Component { id: _timerComponent; Timer { repeat: false } }

  // Bounded, timed-out request. Caps the response at maxBytes (checked
  // against a declared Content-Length, incrementally as the body streams in,
  // and once more against the final body size, mirroring curl's
  // --max-filesize) and aborts after timeoutMs (curl's --max-time), since
  // QML's XMLHttpRequest has neither built in.
  function httpRequest(method, url, apiKey, maxBytes, timeoutMs) {
    return new Promise(function(resolve, reject) {
      var xhr = new XMLHttpRequest()
      var settled = false
      var sizeExceeded = false
      var timer = _timerComponent.createObject(root, { interval: timeoutMs })

      function finish(err, text) {
        if (settled) return
        settled = true
        timer.stop()
        timer.destroy()
        if (err) reject(err); else resolve(text)
      }

      timer.triggered.connect(function() {
        xhr.abort()
        finish(new Error("timeout"))
      })

      function checkPartialSize() {
        // Guards against chunked/unreported Content-Length responses: without
        // this, an oversized body would buffer in full until DONE before the
        // cap is ever enforced.
        var partial = xhr.responseText || ""
        if (_byteLength(partial) > maxBytes) {
          sizeExceeded = true
          xhr.abort()
          finish(new Error("response too large"))
          return true
        }
        return false
      }

      xhr.onreadystatechange = function() {
        if (xhr.readyState === XMLHttpRequest.HEADERS_RECEIVED) {
          var len = parseInt(xhr.getResponseHeader("Content-Length") || "0", 10)
          if (len > maxBytes) {
            sizeExceeded = true
            xhr.abort()
            // Don't wait for DONE: abort() isn't guaranteed to drive the
            // XHR through a readyState change, so settle right here or a
            // still-pending abort could otherwise stall until the timeout.
            finish(new Error("response too large"))
          }
        } else if (xhr.readyState === XMLHttpRequest.LOADING) {
          checkPartialSize()
        } else if (xhr.readyState === XMLHttpRequest.DONE) {
          if (sizeExceeded) { finish(new Error("response too large")); return }
          if (xhr.status >= 200 && xhr.status < 300) {
            var body = xhr.responseText || ""
            if (_byteLength(body) > maxBytes) { finish(new Error("response too large")); return }
            finish(null, body)
          } else {
            var httpErr = new Error("HTTP " + xhr.status)
            httpErr.body = (xhr.responseText || "").slice(0, maxBytes)
            httpErr.status = xhr.status
            finish(httpErr)
          }
        }
      }

      try {
        xhr.open(method, url)
        xhr.setRequestHeader("X-N8N-API-KEY", apiKey)
        xhr.send()
      } catch (e) {
        finish(e)
        return
      }
      if (!settled) timer.start()
    })
  }

  // responseText.length counts UTF-16 code units, not bytes; encodeURIComponent
  // gives an ASCII-safe proxy we can measure to approximate the true UTF-8
  // byte size for the cap check (close enough for a defense-in-depth limit).
  function _byteLength(text) {
    try {
      return encodeURIComponent(text).replace(/%[0-9A-F]{2}/g, "x").length
    } catch (e) {
      return text.length
    }
  }

  // GET/POST + JSON.parse, falling back to `fallback` on any network,
  // timeout, size, or parse error (matches the old bash behavior of
  // degrading a single instance's data instead of erroring the whole run).
  function httpJson(method, url, apiKey, maxBytes, timeoutMs, fallback) {
    return root.httpRequest(method, url, apiKey, maxBytes, timeoutMs).then(function(text) {
      try { return JSON.parse(text) } catch (e) { return fallback }
    }).catch(function() {
      return fallback
    })
  }

  // ── Instances config ──────────────────────────────────────────────────────

  // preload: false keeps this watcher-only — it never touches
  // instancesFile.text()/.data(), so the unsafe FileView read path is never
  // exercised for this predictable, user-writable path. It only exists to
  // detect changes via QFileSystemWatcher; actual content always comes from
  // readBoundedFile() below.
  FileView {
    id: instancesFile
    path: root._instancesPath
    preload: false
    watchChanges: true
    onFileChanged: root._loadInstances()
  }

  function _loadInstances() {
    root.readBoundedFile(root._instancesPath, root._maxConfigBytes).then(function(text) {
      if (text === null) {
        root._rawInstances = []
        root.instances = []
        root.totalActive = 0
        root.totalRunning = 0
        root.totalFailed = 0
        root.state = "error"
        root.message = "Could not read instances config (missing, unreadable, a symlink, "
          + "too large, or not a regular file). Run: omarchy-n8n-setup"
        root.fetchedAt = new Date().toISOString()
        return
      }
      var parsed
      try {
        parsed = JSON.parse(text && text.trim() !== "" ? text : "[]")
      } catch (e) {
        root._rawInstances = []
        root.instances = []
        root.state = "error"
        root.message = "Instances config is not valid JSON. Run: omarchy-n8n-setup"
        root.fetchedAt = new Date().toISOString()
        return
      }
      root._rawInstances = Array.isArray(parsed) ? parsed.slice(0, root._maxInstances) : []
      if (root._rawInstances.length === 0) {
        root.instances = []
        root.state = "error"
        root.message = "No instances in config. Run: omarchy-n8n-setup"
        root.fetchedAt = new Date().toISOString()
        return
      }
      root.refresh()
    })
  }

  // ── Previous-failure state (for notification dedup) ────────────────────────

  // Same watcher-only treatment as instancesFile above: writes still go
  // through FileView.setText() for its atomic-write guarantee (private temp
  // file + rename), but reads never go through FileView.
  FileView {
    id: stateFile
    path: root._statePath
  }

  // Tracks whether the initial previous-state read attempt has completed at
  // least once — success, "missing", or any other failure all count. Gates
  // notifications on refresh() so a cold-start race can't read "not loaded
  // yet" as "no prior failures" and over-notify.
  property bool _stateReady: false

  function _previousFailedIds() {
    return root.readBoundedFile(root._statePath, root._maxConfigBytes).then(function(text) {
      root._stateReady = true
      if (text === null) return []
      try {
        var data = JSON.parse(text)
        return Array.isArray(data.failedIds) ? data.failedIds : []
      } catch (e) {
        return []
      }
    })
  }

  // ── Fetch ─────────────────────────────────────────────────────────────────

  function refresh() {
    if (root._fetchInFlight) return
    if (root._rawInstances.length === 0) return
    root._fetchInFlight = true
    root.loading = true

    var maxExecutions = root.intSetting("maxExecutions", 20, 5, 50)
    var notifyOnFailure = root.boolSetting("notifyOnFailure", true)

    var jobs = root._rawInstances.map(function(inst) {
      return root._fetchInstance(inst, maxExecutions)
    })

    Promise.all(jobs).then(function(results) {
      var totalActive = 0, totalRunning = 0, totalFailed = 0
      var failedIds = []
      results.forEach(function(inst) {
        totalActive += inst.activeCount
        totalRunning += inst.runningCount
        totalFailed += inst.failedCount
        inst.executions.forEach(function(ex) {
          if (ex.status === "error" || ex.status === "crashed") {
            failedIds.push(inst.id + ":" + ex.id)
          }
        })
      })

      // Always read previous state (to advance _stateReady for next time),
      // but only actually fire notifications once we know this isn't the
      // very first read — otherwise a cold-start race could misread "no
      // prior state yet" as "everything is new" and over-notify.
      var wasStateReady = root._stateReady
      root._previousFailedIds().then(function(prevIds) {
        var notifyPromise = (notifyOnFailure && wasStateReady)
          ? root._notifyWithPrevIds(results, prevIds)
          : Promise.resolve()

        return notifyPromise
      }).then(function() {
        root.instances = results
        root.totalActive = totalActive
        root.totalRunning = totalRunning
        root.totalFailed = totalFailed
        root.state = "ready"
        root.message = ""
        root.fetchedAt = new Date().toISOString()
        root.loading = false
        root._fetchInFlight = false

        stateFile.setText(JSON.stringify({ failedIds: failedIds }))
      })
    }).catch(function() {
      root.state = "error"
      root.message = "n8n fetch failed."
      root.fetchedAt = new Date().toISOString()
      root.loading = false
      root._fetchInFlight = false
    })
  }

  function _fetchInstance(inst, maxExecutions) {
    var id = String(inst.id || "")
    var name = String(inst.name || "")
    var url = String(inst.url || "").replace(/\/$/, "")

    function emptyRecord(state, msg) {
      return {
        id: id, name: name, url: url, state: state, message: msg,
        workflows: [], executions: [],
        activeCount: 0, inactiveCount: 0, runningCount: 0, failedCount: 0
      }
    }

    if (!root.validId(id)) {
      return Promise.resolve(emptyRecord("invalid-id", "Instance id contains characters that are not filename-safe."))
    }

    return root.lookupApiKey(id).then(function(apiKey) {
      if (!apiKey) {
        return emptyRecord("no-credentials", "No API key configured. Run: omarchy-n8n-setup")
      }

      var base = url + "/api/v1"
      var wfUrl = base + "/workflows?limit=100"
      var exUrl = base + "/executions?limit=" + maxExecutions + "&includeData=false"

      return Promise.all([
        root.httpJson("GET", wfUrl, apiKey, root._maxResponseBytes, root._requestTimeoutMs, { data: [] }),
        root.httpJson("GET", exUrl, apiKey, root._maxResponseBytes, root._requestTimeoutMs, { data: [] })
      ]).then(function(pair) {
        var wfResp = pair[0], exResp = pair[1]

        // Hard-cap the number of items we accept regardless of what the
        // server returns (defense in depth: a compromised/malicious
        // endpoint could ignore our ?limit= query param).
        var cap = root._maxItemsPerInstance
        var rawWorkflows = Array.isArray(wfResp && wfResp.data) ? wfResp.data.slice(0, cap) : []
        var workflows = rawWorkflows.map(function(w) {
          return { id: String(w.id), name: w.name, active: !!w.active, updatedAt: w.updatedAt || "", url: "" }
        })

        var nameById = {}
        workflows.forEach(function(w) { nameById[w.id] = w.name })

        var rawExecutions = Array.isArray(exResp && exResp.data) ? exResp.data.slice(0, cap) : []
        var executions = rawExecutions.map(function(e) {
          var wfId = String(e.workflowId)
          return {
            id: String(e.id), workflowId: wfId, workflowName: nameById[wfId] || "",
            status: e.status, startedAt: e.startedAt || "", stoppedAt: e.stoppedAt || "", mode: e.mode || ""
          }
        })

        return {
          id: id, name: name, url: url, state: "ready", message: "",
          activeCount: workflows.filter(function(w) { return w.active }).length,
          inactiveCount: workflows.filter(function(w) { return !w.active }).length,
          runningCount: executions.filter(function(e) { return e.status === "running" }).length,
          failedCount: executions.filter(function(e) { return e.status === "error" || e.status === "crashed" }).length,
          workflows: workflows, executions: executions
        }
      })
    })
  }

  // ── Failure notifications ────────────────────────────────────────────────

  function _notifyWithPrevIds(results, prevIds) {
    var prevSet = {}
    prevIds.forEach(function(k) { prevSet[k] = true })

    var fired = 0
    for (var i = 0; i < results.length && fired < root._maxNotificationsPerRun; i++) {
      var inst = results[i]
      for (var j = 0; j < inst.executions.length && fired < root._maxNotificationsPerRun; j++) {
        var ex = inst.executions[j]
        if (ex.status !== "error" && ex.status !== "crashed") continue
        var key = inst.id + ":" + ex.id
        if (prevSet[key]) continue
        var execUrl = inst.url + "/workflow/" + ex.workflowId + "/executions/" + ex.id
        root._fireNotification(ex.workflowName, execUrl)
        fired++
      }
    }
  }

  function _fireNotification(workflowName, execUrl) {
    root.runProcess([
      "notify-send", "--app-name=n8n", "--icon=dialog-error", "--wait",
      "--action=open:Open execution", "󱓛 Workflow failed", workflowName
    ]).then(function(r) {
      if (r.exitCode === 0 && r.output.trim() === "open") {
        root._openInBrowser(execUrl)
      }
    })
  }

  function _openInBrowser(url) {
    root.runProcess(["omarchy", "launch", "browser", url]).then(function(r) {
      if (r.exitCode !== 0) Quickshell.execDetached(["xdg-open", url])
    })
  }

  // ── Toggle ────────────────────────────────────────────────────────────────

  function toggleWorkflow(instanceId, workflowId, makeActive) {
    if (!root.validId(instanceId)) {
      root.toggleError = "Invalid instance id: " + instanceId
      toggleErrorClear.restart()
      return
    }
    // workflowId flows in from the n8n API response relayed through the
    // UI, so it must be validated before being spliced into the request
    // URL below — otherwise a compromised endpoint could smuggle extra
    // path segments to redirect the authenticated request elsewhere.
    if (!root.validId(workflowId)) {
      root.toggleError = "Invalid workflow id: " + workflowId
      toggleErrorClear.restart()
      return
    }

    var inst = root._rawInstances.find(function(i) { return i.id === instanceId })
    if (!inst) {
      root.toggleError = "Instance not found: " + instanceId
      toggleErrorClear.restart()
      return
    }

    root.lookupApiKey(instanceId).then(function(apiKey) {
      if (!apiKey) {
        root.toggleError = "No API key for instance: " + instanceId
        toggleErrorClear.restart()
        return
      }
      var action = makeActive ? "activate" : "deactivate"
      var url = String(inst.url).replace(/\/$/, "") + "/api/v1/workflows/" + workflowId + "/" + action

      root.httpRequest("POST", url, apiKey, root._maxToggleResponseBytes, root._requestTimeoutMs).then(function() {
        root.toggleError = ""
        postToggleRefresh.start()
      }).catch(function(err) {
        var detail = "HTTP " + (err && err.status ? err.status : "error")
        if (err && err.body) {
          try {
            var parsed = JSON.parse(err.body)
            if (parsed && parsed.message) detail = String(parsed.message).slice(0, 500)
          } catch (e) { /* not JSON, fall back to HTTP status */ }
        }
        root.toggleError = "Toggle failed: " + detail
        toggleErrorClear.restart()
        postToggleRefresh.start()
      })
    })
  }

  visible: false

  Component.onCompleted: root._loadInstances()

  Timer {
    // Initial load is triggered by Component.onCompleted above; this timer
    // only handles the recurring poll.
    interval: root.intSetting("refreshIntervalSec", 30, 10, 300) * 1000
    repeat: true
    running: true
    triggeredOnStart: false
    onTriggered: root._loadInstances()
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
}
