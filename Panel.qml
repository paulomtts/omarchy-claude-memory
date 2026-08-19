import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Browses Claude Code's persistent memory (~/.claude/projects/<slug>/memory/),
// not the conversation context: pick a project, read its MEMORY.md index,
// then drill into any linked note. Three flat views (projects -> index ->
// entry). Projects and index are searchable and fully keyboard-navigable;
// entry is just a scrollable read.
Panel {
  id: root
  moduleName: "paulomtts.claude-memory"
  ipcTarget: "paulomtts.claude-memory"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // "" when unset -> fall back to $HOME/.claude/projects at query time.
  readonly property string projectsRoot: root.setting("projectsRoot", "")
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

  property string viewMode: "projects" // "projects" | "index" | "entry"
  property var projects: []            // [{ dir, label }]
  property var indexEntries: []        // [{ title, file, hook }]
  property string selectedDir: ""
  property string selectedProjectLabel: ""
  property string selectedFilePath: ""
  property string entryTitle: ""
  property string entryType: ""
  property string entryDescription: ""
  property string entryBody: ""
  property string loadError: ""

  // Search + keyboard cursor. The highlighted row is always whatever Enter
  // would activate -- no separate "has the user interacted yet" gate, so
  // the highlight never lies about what a bare Enter press would do.
  property string searchQuery: ""
  property int cursorIndex: 0

  // Manage mode: select projects (by dir) or memory entries (by file) for
  // deletion. Gated behind typing the literal word "delete" so a stray
  // Enter/click can't destroy anything by itself.
  property bool manageMode: false
  property var selectedKeys: ({})
  property bool confirmOpen: false
  property string confirmText: ""
  property string deleteError: ""
  property bool deleting: false

  // Consolidate: ask Claude to review this project's memory and propose a
  // merged/pruned set. "confirming" is the pre-flight cost/time heads-up;
  // "review" is reached only after the plan's file-accounting invariant is
  // re-validated against the current index -- never trust the model's
  // bookkeeping blindly. Only reachable from the memory-index view, and
  // "locks" that view (search/manage/back hidden) until Cancel/Apply/
  // Dismiss returns to "idle" -- see consolidateActive below.
  property string consolidateState: "idle" // "idle"|"confirming"|"running"|"review"|"applying"|"error"
  property string consolidateProgress: ""
  property double consolidateStartMs: 0
  property double consolidateNowMs: 0
  property var consolidatePlan: null
  property string consolidateError: ""
  property string consolidateApplyText: ""
  // filename -> raw old content, fetched once the plan is validated, so the
  // review screen can show a real before/after instead of just a filename
  // list. Missing key (not "") means "not fetched yet or unreadable".
  property var consolidateOldContent: ({})

  readonly property bool consolidateActive: root.viewMode === "index" && root.consolidateState !== "idle"

  readonly property string consolidateElapsedText: {
    if (root.consolidateState !== "running" || root.consolidateStartMs === 0) return ""
    var secs = Math.max(0, Math.round((root.consolidateNowMs - root.consolidateStartMs) / 1000))
    return secs + "s elapsed"
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  function matchesQuery(text) {
    var q = root.searchQuery.trim().toLowerCase()
    return q === "" || String(text || "").toLowerCase().indexOf(q) >= 0
  }

  readonly property var filteredProjects: root.projects.filter(function(p) { return root.matchesQuery(p.label) })
  readonly property var filteredIndexEntries: root.indexEntries.filter(function(e) {
    return root.matchesQuery(e.title) || root.matchesQuery(e.hook)
  })

  function currentList() {
    if (root.viewMode === "projects") return root.filteredProjects
    if (root.viewMode === "index") return root.filteredIndexEntries
    return []
  }

  // Focus follows the view: projects/index put the caret in the search box
  // (so arrow keys/typing work immediately), entry hands focus to the plain
  // key catcher so up/down scroll the body text instead.
  function focusForView() {
    Qt.callLater(function() {
      if (!root.opened) return
      if (root.viewMode === "index" && root.consolidateState === "review") {
        if (consolidateApplyField) consolidateApplyField.forceActiveFocus()
      } else if (root.consolidateActive) {
        if (keyCatcher) keyCatcher.forceActiveFocus()
      } else if (root.viewMode === "entry") {
        if (keyCatcher) keyCatcher.forceActiveFocus()
      } else if (searchField) {
        searchField.forceActiveFocus()
      }
    })
  }

  function resetSearch() {
    searchQuery = ""
    cursorIndex = 0
    // Selection keys only make sense within the view they were made in
    // (a dir for projects, a filename for index entries).
    manageMode = false
    selectedKeys = {}
    confirmOpen = false
    confirmText = ""
    deleteError = ""
  }

  function moveCursor(delta) {
    var list = root.currentList()
    if (list.length === 0) return
    root.cursorIndex = root.clamp(root.cursorIndex + delta, 0, list.length - 1)
    root.scrollCursorIntoView()
  }

  function hoverCursor(index) {
    root.cursorIndex = index
  }

  function activateCursor() {
    var list = root.currentList()
    if (root.cursorIndex < 0 || root.cursorIndex >= list.length) return
    var item = list[root.cursorIndex]
    if (root.manageMode) {
      root.toggleSelected(root.viewMode === "projects" ? item.dir : item.file)
      return
    }
    if (root.viewMode === "projects") root.selectProject(item.dir, item.label)
    else if (root.viewMode === "index") root.selectEntry(item)
  }

  // The Delete key is a "delete this one" shortcut that works whether or
  // not manage mode is on: it selects only the row currently under the
  // cursor (mouse hover or keyboard), discarding any other selection, then
  // opens the same type-"delete"-to-confirm dialog manage mode uses.
  function deleteCurrentItem() {
    var list = root.currentList()
    if (root.cursorIndex < 0 || root.cursorIndex >= list.length) return
    var item = list[root.cursorIndex]
    var key = root.viewMode === "projects" ? item.dir : item.file
    var only = {}
    only[key] = true
    root.manageMode = true
    root.selectedKeys = only
    root.openConfirm()
  }

  function titleForFile(file) {
    for (var i = 0; i < root.indexEntries.length; i++)
      if (root.indexEntries[i].file === file) return root.indexEntries[i].title
    return file
  }

  // Old-content lookups for the review screen's before/after display.
  // consolidateOldContent holds raw file content keyed by filename, fetched
  // once per plan by fetchOldContent(); a missing key means "not fetched
  // yet or the file couldn't be read", not "empty file".
  function oldBodyFor(file) {
    var raw = root.consolidateOldContent[file]
    return raw === undefined ? "" : root.parseEntry(raw).body
  }

  function oldEntriesFor(sources) {
    return (sources || []).map(function(f) {
      var raw = root.consolidateOldContent[f]
      var available = raw !== undefined
      var parsed = available ? root.parseEntry(raw) : null
      return {
        file: f,
        title: parsed && parsed.name !== "" ? parsed.name : f,
        body: available ? parsed.body : "",
        available: available
      }
    })
  }

  // Fetches the real current content of every file the plan is about to
  // supersede or discard, so the review screen can show what's actually
  // there instead of trusting the model's own account of it.
  function fetchOldContent(plan) {
    var entries = plan.entries || []
    var discards = plan.discard || []
    var files = {}
    entries.forEach(function(entry) {
      (entry.sources || []).forEach(function(f) { files[f] = true })
    })
    discards.forEach(function(item) { files[item.file] = true })
    var names = Object.keys(files)
    root.consolidateOldContent = {}
    if (names.length === 0) return
    oldContentProc.command = ["python3", root.pluginDir + "read-entries.py", root.selectedDir].concat(names)
    oldContentProc.running = true
  }

  function startConsolidate() {
    if (root.viewMode !== "index") return
    root.manageMode = false
    root.selectedKeys = {}
    root.confirmOpen = false
    root.confirmText = ""
    root.consolidateState = "confirming"
    root.focusForView()
  }

  function cancelConsolidateConfirm() {
    root.consolidateState = "idle"
    root.focusForView()
  }

  function runConsolidate() {
    root.consolidateProgress = ""
    root.consolidateError = ""
    root.consolidatePlan = null
    root.consolidateOldContent = {}
    root.consolidateApplyText = ""
    root.consolidateStartMs = Date.now()
    root.consolidateNowMs = root.consolidateStartMs
    root.consolidateState = "running"
    var sourceDir = root.selectedProjectLabel.charAt(0) === "/" ? root.selectedProjectLabel : ""
    consolidateProc.workingDirectory = root.selectedDir
    consolidateProc.command = ["python3", root.pluginDir + "consolidate-run.py", root.selectedDir, sourceDir]
    consolidateProc.running = true
  }

  function toolProgressText(name, input) {
    var target = ""
    if (input && input.file_path) target = String(input.file_path)
    else if (input && input.pattern) target = String(input.pattern)
    else if (input && input.path) target = String(input.path)
    if (name === "Read") return "Reading " + target.split("/").pop() + "…"
    if (name === "Grep") return "Searching " + target + "…"
    if (name === "Glob") return "Listing " + target + "…"
    return ""
  }

  function handleConsolidateLine(line) {
    var text = String(line || "").trim()
    if (text === "") return
    var evt
    try { evt = JSON.parse(text) } catch (e) { return }
    if (!evt || typeof evt !== "object") return

    if (evt.type === "assistant" && evt.message && Array.isArray(evt.message.content)) {
      var blocks = evt.message.content
      for (var i = 0; i < blocks.length; i++) {
        var block = blocks[i]
        if (block && block.type === "tool_use")
          root.consolidateProgress = root.toolProgressText(block.name, block.input)
      }
      return
    }

    if (evt.type === "result") {
      if (evt.is_error) {
        root.consolidateError = String(evt.result || "Claude Code exited with an error.")
        root.consolidateState = "error"
        return
      }
      var plan
      try { plan = JSON.parse(String(evt.result || "")) } catch (e) {
        root.consolidateError = "Claude's response wasn't valid JSON."
        root.consolidateState = "error"
        return
      }
      var invalid = root.validateConsolidatePlan(plan)
      if (invalid !== "") {
        root.consolidateError = invalid
        root.consolidateState = "error"
        return
      }
      root.consolidatePlan = plan
      root.consolidateState = "review"
      root.fetchOldContent(plan)
      root.focusForView()
    }
  }

  // Re-checks the same invariants consolidate-apply.py enforces before
  // writing anything, in the same order: no two entries targeting the same
  // file, every currently-indexed file accounted for in exactly one of
  // unchanged / some entry's sources / discard, and no entry silently
  // overwriting an existing file it doesn't list among its own sources.
  // Item accessors are defensive (entry/item may not be an object -- e.g.
  // stray `null` in a malformed array) so a garbled plan produces a clean
  // error string here instead of an uncaught throw that would strand
  // consolidateState at "running" forever. Returns "" if the plan is safe
  // to show for review, or an error string.
  function safeName(n) {
    return n !== "" && n.indexOf("/") < 0 && n !== "." && n !== ".."
  }

  function validateConsolidatePlan(plan) {
    if (!plan || typeof plan !== "object") return "Claude's response wasn't a JSON object."
    var unchanged = Array.isArray(plan.unchanged) ? plan.unchanged : null
    var entries = Array.isArray(plan.entries) ? plan.entries : null
    var discard = Array.isArray(plan.discard) ? plan.discard : null
    if (!unchanged || !entries || !discard) return "Claude's response was missing unchanged/entries/discard."

    function entryFile(entry) { return (entry && typeof entry === "object" && entry.file) ? String(entry.file) : "" }
    function entrySources(entry) { return (entry && typeof entry === "object" && Array.isArray(entry.sources)) ? entry.sources : [] }
    function discardFile(item) { return (item && typeof item === "object" && item.file) ? String(item.file) : "" }

    for (var u = 0; u < unchanged.length; u++)
      if (!root.safeName(String(unchanged[u]))) return "Unsafe filename in unchanged: " + unchanged[u]
    for (var e = 0; e < entries.length; e++) {
      var ef = entryFile(entries[e])
      if (!root.safeName(ef)) return "Unsafe filename in entries: " + ef
      var esrcs = entrySources(entries[e])
      for (var s = 0; s < esrcs.length; s++)
        if (!root.safeName(String(esrcs[s]))) return "Unsafe source filename: " + esrcs[s]
    }
    for (var d = 0; d < discard.length; d++) {
      var df = discardFile(discard[d])
      if (!root.safeName(df)) return "Unsafe filename in discard: " + df
    }

    var seenTargets = {}
    var dupTarget = ""
    entries.map(entryFile).forEach(function(f) {
      if (dupTarget !== "" || f === "") return
      if (seenTargets[f]) { dupTarget = f; return }
      seenTargets[f] = true
    })
    if (dupTarget !== "") return "Two entries target the same file: " + dupTarget

    var accounted = {}
    var conflict = ""
    function account(name, bucket) {
      if (conflict !== "") return
      if (accounted[name]) { conflict = name + " is listed in both " + accounted[name] + " and " + bucket; return }
      accounted[name] = bucket
    }
    unchanged.forEach(function(name) { account(name, "unchanged") })
    entries.forEach(function(entry) {
      entrySources(entry).forEach(function(source) { account(source, "entries[].sources") })
    })
    discard.forEach(function(item) { account(discardFile(item), "discard") })
    if (conflict !== "") return conflict

    var current = root.indexEntries.map(function(e) { return e.file })
    var missing = current.filter(function(f) { return !accounted[f] })
    var extra = Object.keys(accounted).filter(function(f) { return current.indexOf(f) < 0 })
    if (missing.length > 0) return "Plan doesn't account for: " + missing.join(", ")
    if (extra.length > 0) return "Plan references files not in the current index: " + extra.join(", ")

    var selfOverwrite = ""
    entries.forEach(function(entry) {
      if (selfOverwrite !== "") return
      var target = entryFile(entry)
      if (current.indexOf(target) >= 0 && entrySources(entry).indexOf(target) < 0) selfOverwrite = target
    })
    if (selfOverwrite !== "") return "Entry targets existing file " + selfOverwrite + " without listing it as a source."

    return ""
  }

  function cancelConsolidate() {
    root.consolidateState = "idle"
    root.consolidatePlan = null
    root.consolidateOldContent = {}
    root.consolidateError = ""
    root.consolidateApplyText = ""
    root.focusForView()
  }

  function dismissConsolidateError() {
    root.consolidateState = "idle"
    root.consolidateError = ""
    root.consolidateApplyText = ""
    root.focusForView()
  }

  // Full teardown of any in-flight consolidate flow, including stopping the
  // background process. Called from every navigation path that leaves the
  // memory-index view (or re-enters it for a different project) so nothing
  // can orphan a running/applying process or bleed a stale plan into an
  // unrelated project -- see consolidateActive above.
  function resetConsolidate() {
    root.consolidateState = "idle"
    root.consolidatePlan = null
    root.consolidateOldContent = {}
    root.consolidateError = ""
    root.consolidateApplyText = ""
    root.consolidateProgress = ""
    consolidateProc.running = false
  }

  function performConsolidateApply() {
    if (root.consolidateApplyText.trim().toLowerCase() !== "apply") return
    if (!root.consolidatePlan) return
    root.consolidateError = ""
    root.consolidateState = "applying"
    consolidateApplyProc.stdinEnabled = true
    consolidateApplyProc.pendingPlanJson = JSON.stringify(root.consolidatePlan)
    consolidateApplyProc.command = ["python3", root.pluginDir + "consolidate-apply.py", root.selectedDir]
    consolidateApplyProc.running = true
  }

  function toggleManageMode() {
    manageMode = !manageMode
    selectedKeys = {}
    confirmOpen = false
    confirmText = ""
    deleteError = ""
  }

  function isSelected(key) { return !!selectedKeys[key] }

  function toggleSelected(key) {
    var next = Object.assign({}, selectedKeys)
    if (next[key]) delete next[key]
    else next[key] = true
    selectedKeys = next
  }

  function selectedCount() { return Object.keys(root.selectedKeys).length }

  function openConfirm() {
    if (root.selectedCount() === 0) return
    confirmOpen = true
    confirmText = ""
  }

  function cancelConfirm() {
    confirmOpen = false
    confirmText = ""
    focusForView()
  }

  function performDelete() {
    if (root.deleting) return
    if (root.confirmText.trim().toLowerCase() !== "delete") return
    var keys = Object.keys(root.selectedKeys)
    if (keys.length === 0) return
    root.deleteError = ""
    root.deleting = true
    if (root.viewMode === "projects")
      deleteProc.command = ["python3", root.pluginDir + "delete-memory.py", "project"].concat(keys)
    else
      deleteProc.command = ["python3", root.pluginDir + "delete-memory.py", "entries", root.selectedDir].concat(keys)
    deleteProc.running = true
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  // Repeater.itemAt() is the documented way to reach a generated delegate,
  // rather than indexing into the parent positioner's children (which also
  // holds the Repeater instance itself, not just its delegates).
  function scrollCursorIntoView() {
    if (root.viewMode === "projects" && projectsRepeater)
      root.scrollItemIntoView(projectsRepeater.itemAt(root.cursorIndex))
    else if (root.viewMode === "index" && indexRepeater)
      root.scrollItemIntoView(indexRepeater.itemAt(root.cursorIndex))
  }

  function refreshProjects() {
    loadError = ""
    listProc.running = false
    listProc.running = true
  }

  function openProjects() {
    viewMode = "projects"
    selectedDir = ""
    selectedFilePath = ""
    resetSearch()
    resetConsolidate()
    refreshProjects()
    focusForView()
  }

  function selectProject(dir, label) {
    selectedDir = dir
    selectedProjectLabel = label
    selectedFilePath = ""
    indexEntries = []
    loadError = ""
    viewMode = "index"
    resetSearch()
    resetConsolidate()
    if (panelFlick) panelFlick.contentY = 0
    focusForView()
  }

  function selectEntry(entry) {
    entryTitle = entry.title
    selectedFilePath = root.selectedDir + "/" + entry.file
    viewMode = "entry"
    if (panelFlick) panelFlick.contentY = 0
    focusForView()
  }

  function goBack() {
    if (viewMode === "entry") { viewMode = "index"; selectedFilePath = "" }
    else if (viewMode === "index") { openProjects(); return }
    resetSearch()
    if (panelFlick) panelFlick.contentY = 0
    focusForView()
  }

  function parseIndex(content) {
    var lines = String(content || "").split("\n")
    var out = []
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^-\s*\[([^\]]+)\]\(([^)]+)\)\s*(.*)$/)
      if (!m) continue
      out.push({
        title: m[1].trim(),
        // A "./" prefix is a no-op for actually opening the file (joined
        // onto selectedDir it still resolves), but it breaks every place
        // that compares filenames by exact string equality -- notably
        // Claude's own consolidation plans, which reference files by the
        // bare name Read/Glob report, never "./name". Normalize once here
        // so every consumer of indexEntries sees the same bare form
        // consolidate-apply.py's INDEX_LINE_RE-based parsing already
        // assumes.
        file: m[2].trim().replace(/^\.\//, ""),
        hook: String(m[3] || "").replace(/^[—-]\s*/, "").trim()
      })
    }
    return out
  }

  function parseEntry(content) {
    var text = String(content || "")
    var m = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/)
    var name = "", description = "", type = "", body = text
    if (m) {
      var front = m[1]
      body = m[2]
      var nameM = front.match(/^name:\s*(.*)$/m)
      var descM = front.match(/^description:\s*(.*)$/m)
      var typeM = front.match(/^\s*type:\s*(.*)$/m)
      if (nameM) name = nameM[1].trim()
      if (descM) description = descM[1].trim()
      if (typeM) type = typeM[1].trim()
    }
    return { name: name, description: description, type: type, body: body.trim() }
  }

  // A closed panel isn't destroyed -- its Process items (including
  // consolidateProc) keep running in the background, and selectedDir/
  // viewMode are frozen exactly where they were, since navigating away is
  // already blocked while consolidateActive is true. So a reopen only
  // resets to the projects list when there's nothing in flight to resume;
  // otherwise it just re-establishes focus for whatever state was left.
  onOpenedChanged: if (opened) {
    if (panelFlick) panelFlick.contentY = 0
    if (root.consolidateState === "idle") openProjects()
    else focusForView()
  }

  onConfirmOpenChanged: if (confirmOpen) Qt.callLater(function() {
    if (root.opened && confirmField) confirmField.forceActiveFocus()
  })

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.openProjects(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "🧠"
    onPressed: function(buttonCode) { root.toggle() }
  }

  Process {
    id: listProc
    // Slug decoding needs the filesystem to disambiguate a path separator
    // from a literal hyphen in a directory name (e.g. "refactor-nori" is one
    // component, not "refactor/nori"), so it's delegated to
    // resolve-projects.py rather than a naive dash-to-slash replace here.
    // Both paths are passed as argv (not interpolated into the script
    // string) so a path containing spaces or quotes can't break the command.
    command: ["bash", "-c", "exec python3 \"$1\" \"$2\"",
      "_", root.pluginDir + "resolve-projects.py", root.projectsRoot]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n").filter(function(l) { return l.trim() !== "" })
        root.projects = lines.map(function(line) {
          var tab = line.indexOf("\t")
          return tab >= 0 ? { dir: line.slice(0, tab), label: line.slice(tab + 1) } : { dir: line, label: line }
        }).sort(function(a, b) { return a.label.localeCompare(b.label) })
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.projects.length === 0)
        root.loadError = "Could not list ~/.claude/projects (is python3 installed?)."
    }
  }

  // command[] is set right before each run by performDelete() -- either
  // ["python3", script, "project", ...memoryDirs] or
  // ["python3", script, "entries", memoryDir, ...filenames]. No shell
  // involved, so nothing here needs quoting.
  Process {
    id: deleteProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n").filter(function(l) { return l.trim() !== "" })
        var errors = []
        lines.forEach(function(line) {
          var parts = line.split("\t")
          if (parts[0] === "error") errors.push(parts[1] + (parts[2] ? (": " + parts[2]) : ""))
        })
        if (errors.length > 0)
          root.deleteError = "Couldn't delete: " + errors.join("; ")
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.deleting = false
      root.confirmOpen = false
      root.confirmText = ""
      root.selectedKeys = {}
      root.cursorIndex = 0
      root.manageMode = false
      // Deleted project dirs no longer show up on disk -- reload the list.
      // Deleted index entries are picked up for free: delete-memory.py
      // rewrites MEMORY.md, and indexFile's watchChanges reloads it.
      if (root.viewMode === "projects") root.refreshProjects()
      focusForView()
    }
  }

  Process {
    id: consolidateProc
    property string stderrText: ""
    stdout: SplitParser {
      onRead: function(line) { root.handleConsolidateLine(line) }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: consolidateProc.stderrText = String(text || "").trim()
    }
    onExited: function(exitCode) {
      // Fires strictly after the child has exited, so stderr's
      // onStreamFinished above is already done -- this is the one place
      // both the stdout-driven result (if any) and stderr are both known,
      // so it's the one place that builds the final message rather than
      // risking a race by appending stderr from the stdout-result path.
      if (root.consolidateState !== "running" && root.consolidateState !== "error") return
      if (root.consolidateState === "running") {
        // A clean stream always ends with a "result" line that
        // handleConsolidateLine() already turned into "review" or "error" --
        // reaching here while still "running" means the process died
        // without ever emitting one (crash, killed, claude not on PATH).
        root.consolidateError = "Claude Code exited unexpectedly" + (exitCode !== 0 ? " (exit code " + exitCode + ")" : "") + "."
        root.consolidateState = "error"
      }
      if (consolidateProc.stderrText !== "" && root.consolidateError.indexOf(consolidateProc.stderrText) < 0)
        root.consolidateError = root.consolidateError + "\n\n" + consolidateProc.stderrText
    }
  }

  Timer {
    interval: 1000
    running: root.consolidateState === "running"
    repeat: true
    onTriggered: root.consolidateNowMs = Date.now()
  }

  // command[] is set by fetchOldContent() right before each run. Best-effort:
  // a read failure just leaves the affected file(s) out of the result, which
  // oldEntriesFor()/oldBodyFor() render as "not available" rather than
  // blocking the review screen.
  Process {
    id: oldContentProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.consolidateOldContent = JSON.parse(text || "{}") }
        catch (e) { root.consolidateOldContent = {} }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  // pendingPlanJson is set by performConsolidateApply() right before
  // running=true, then written and the write channel closed as soon as
  // the process actually starts -- stdinEnabled must be explicitly reset
  // to true before each run, since closing it (to signal EOF) is
  // permanent for that child and does not revert by itself.
  Process {
    id: consolidateApplyProc
    stdinEnabled: true
    property string pendingPlanJson: ""
    onStarted: {
      write(pendingPlanJson)
      pendingPlanJson = ""
      stdinEnabled = false
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n").filter(function(l) { return l.trim() !== "" })
        var errors = []
        lines.forEach(function(line) {
          var parts = line.split("\t")
          if (parts[0] === "error") errors.push(parts[1] + (parts[2] ? (": " + parts[2]) : ""))
        })
        if (errors.length > 0)
          root.consolidateError = "Some changes couldn't be applied: " + errors.join("; ")
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0 || root.consolidateError !== "") {
        if (root.consolidateError === "") root.consolidateError = "Applying the consolidation failed."
        root.consolidateState = "error"
        return
      }
      root.consolidatePlan = null
      root.consolidateApplyText = ""
      root.consolidateState = "idle"
      root.focusForView()
    }
  }

  FileView {
    id: indexFile
    path: root.viewMode !== "projects" && root.selectedDir !== "" ? root.selectedDir + "/MEMORY.md" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.indexEntries = root.parseIndex(text())
    onLoadFailed: {
      root.indexEntries = []
      root.loadError = "Could not read MEMORY.md for this project."
    }
  }

  FileView {
    id: entryFile
    path: root.viewMode === "entry" ? root.selectedFilePath : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var parsed = root.parseEntry(text())
      root.entryType = parsed.type
      root.entryDescription = parsed.description
      root.entryBody = parsed.body
      if (parsed.name !== "") root.entryTitle = parsed.name
    }
    onLoadFailed: {
      root.entryBody = ""
      root.loadError = "Could not read that memory note."
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // Only relevant for the very first focus grab on open; view-to-view
    // focus changes while already open are handled by focusForView().
    focusTarget: root.viewMode === "entry" ? keyCatcher : searchField
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      // Only reachable in the "entry" view (search field owns the keys
      // everywhere else) -- plain pixel scroll, Left-back, and close.
      // There's no "forward" target from the deepest view, so Right is a
      // no-op here rather than dead-ending on a wrong assumption.
      onMoveRequested: function(dx, dy) {
        if (dx < 0) {
          if (root.consolidateActive) return
          root.goBack()
          return
        }
        if (dy !== 0 && panelFlick)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                            Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onCloseRequested: {
        if (root.viewMode === "index" && root.consolidateState === "confirming") root.cancelConsolidateConfirm()
        else if (root.viewMode === "index" && root.consolidateState === "review") root.cancelConsolidate()
        else if (root.viewMode === "index" && root.consolidateState === "error") root.dismissConsolidateError()
        else if (root.consolidateActive) { /* running/applying: nothing to cancel onto yet */ }
        else root.goBack()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

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

          // ---------- Header ----------
          RowLayout {
            width: parent.width
            spacing: Style.spacing.md

            Text {
              visible: root.viewMode !== "projects" && !root.consolidateActive
              text: "‹ Back"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.goBack() }
            }

            Text {
              Layout.fillWidth: true
              text: root.viewMode === "projects" ? "Claude Memory"
                : root.viewMode === "index" ? root.selectedProjectLabel
                : root.entryTitle
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              elide: Text.ElideMiddle
            }

            Button {
              visible: root.viewMode === "index" && root.consolidateState === "idle"
              text: "✨ Consolidate"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.startConsolidate()
            }

            Button {
              visible: root.viewMode !== "entry" && !root.consolidateActive
              text: root.manageMode ? "Done" : "Manage"
              selected: root.manageMode
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.toggleManageMode()
            }
          }

          // ---------- Search ----------
          TextField {
            id: searchField
            visible: root.viewMode !== "entry" && !root.consolidateActive
            width: parent.width
            foreground: root.foreground
            placeholderText: root.viewMode === "projects" ? "Search projects…" : "Search memory…"
            text: root.searchQuery

            onTextChanged: {
              root.searchQuery = text
              root.cursorIndex = 0
            }

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                if (root.searchQuery !== "") { root.searchQuery = "" }
                else if (root.viewMode === "projects") root.close()
                else root.goBack()
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_Down) { root.moveCursor(1); event.accepted = true; return }
              if (event.key === Qt.Key_Up) { root.moveCursor(-1); event.accepted = true; return }
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.activateCursor(); event.accepted = true; return
              }
              // Left/Right double as back/forward navigation, but only once
              // the text caret is already at that edge of the query -- so
              // editing mid-string still moves the caret normally, and the
              // shortcut only fires once there's nowhere left for it to go.
              if (event.key === Qt.Key_Left && searchField.cursorPosition === 0) {
                root.goBack(); event.accepted = true; return
              }
              if (event.key === Qt.Key_Right && searchField.cursorPosition === searchField.text.length) {
                root.activateCursor(); event.accepted = true; return
              }
              if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_Delete) {
                root.deleteCurrentItem(); event.accepted = true; return
              }
              // Anything else (letters, backspace, left/right...) falls
              // through to the field's normal text-editing behavior.
            }
          }

          // ---------- Manage toolbar ----------
          RowLayout {
            visible: root.manageMode && !root.confirmOpen
            width: parent.width
            spacing: Style.spacing.md

            Text {
              Layout.fillWidth: true
              text: root.selectedCount() === 0 ? "Select items to delete."
                : root.selectedCount() + " selected"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              text: "Delete selected"
              enabled: root.selectedCount() > 0
              opacity: enabled ? 1 : 0.5
              bordered: true
              foreground: root.urgent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.openConfirm()
            }
          }

          // ---------- Delete confirmation ----------
          Column {
            visible: root.confirmOpen
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: "Type delete to permanently remove "
                + (root.viewMode === "projects"
                  ? "memory for " + root.selectedCount() + " project" + (root.selectedCount() === 1 ? "" : "s")
                  : root.selectedCount() + " memory note" + (root.selectedCount() === 1 ? "" : "s"))
                + ". This can't be undone."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            TextField {
              id: confirmField
              width: parent.width
              foreground: root.foreground
              placeholderText: "delete"
              text: root.confirmText

              onTextChanged: root.confirmText = text

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { root.cancelConfirm(); event.accepted = true; return }
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.performDelete(); event.accepted = true; return
                }
              }
            }

            Row {
              spacing: Style.spacing.md

              Button {
                text: "Cancel"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.cancelConfirm()
              }

              Button {
                text: root.deleting ? "Deleting…" : "Confirm delete"
                enabled: !root.deleting && root.confirmText.trim().toLowerCase() === "delete"
                opacity: enabled ? 1 : 0.5
                bordered: true
                foreground: root.urgent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.performDelete()
              }
            }
          }

          Text {
            visible: root.loadError !== ""
            width: parent.width
            text: root.loadError
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.deleteError !== ""
            width: parent.width
            text: root.deleteError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---------- Projects ----------
          Column {
            visible: root.viewMode === "projects"
            width: parent.width
            spacing: Style.space(6)

            Text {
              visible: root.projects.length === 0 && root.loadError === ""
              width: parent.width
              text: "No project memory found under ~/.claude/projects."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.projects.length > 0 && root.filteredProjects.length === 0
              width: parent.width
              text: "No projects match “" + root.searchQuery + "”."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              id: projectsRepeater
              model: root.filteredProjects

              ProjectRow {
                required property var modelData
                required property int index
                width: parent.width
                rowIndex: index
                label: modelData.label
                manageMode: root.manageMode
                selected: root.isSelected(modelData.dir)
                onActivated: root.manageMode ? root.toggleSelected(modelData.dir)
                  : root.selectProject(modelData.dir, modelData.label)
              }
            }
          }

          // ---------- Memory index ----------
          Column {
            visible: root.viewMode === "index" && !root.consolidateActive
            width: parent.width
            spacing: Style.space(6)

            Text {
              visible: root.indexEntries.length === 0 && root.loadError === ""
              width: parent.width
              text: "This project's MEMORY.md has no indexed entries yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Text {
              visible: root.indexEntries.length > 0 && root.filteredIndexEntries.length === 0
              width: parent.width
              text: "No memory entries match “" + root.searchQuery + "”."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              id: indexRepeater
              model: root.filteredIndexEntries

              IndexRow {
                required property var modelData
                required property int index
                width: parent.width
                rowIndex: index
                title: modelData.title
                hook: modelData.hook
                manageMode: root.manageMode
                selected: root.isSelected(modelData.file)
                onActivated: root.manageMode ? root.toggleSelected(modelData.file)
                  : root.selectEntry(modelData)
              }
            }
          }

          // ---------- Consolidate: confirm ----------
          Column {
            visible: root.viewMode === "index" && root.consolidateState === "confirming"
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: "Ask Claude to review this project's memory and propose a consolidated set? This uses your Claude subscription and may take a minute or two."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.spacing.md

              Button {
                text: "Cancel"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.cancelConsolidateConfirm()
              }

              Button {
                text: "Continue"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.runConsolidate()
              }
            }
          }

          // ---------- Consolidate: running ----------
          Column {
            visible: root.viewMode === "index" && root.consolidateState === "running"
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: root.consolidateProgress !== "" ? root.consolidateProgress : "Starting…"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              text: root.consolidateElapsedText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              text: "Cancel"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.resetConsolidate()
            }
          }

          // ---------- Consolidate: review ----------
          Column {
            visible: root.viewMode === "index" && root.consolidateState === "review"
            width: parent.width
            spacing: Style.space(12)

            Text {
              width: parent.width
              text: root.consolidatePlan ? root.consolidatePlan.summary : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "PROPOSED (" + (root.consolidatePlan ? root.consolidatePlan.entries.length : 0) + ")"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.consolidatePlan ? root.consolidatePlan.entries : []

              Column {
                required property var modelData
                width: parent.width
                spacing: Style.space(6)

                Text {
                  width: parent.width
                  text: modelData.title
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  wrapMode: Text.WordWrap
                }

                // ---- Before: the real current content of every file this
                // entry supersedes, fetched by fetchOldContent() -- not
                // Claude's account of it. ----
                Column {
                  width: parent.width
                  spacing: Style.space(6)
                  visible: beforeRepeater.count > 0

                  Text {
                    text: "BEFORE"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Repeater {
                    id: beforeRepeater
                    model: root.oldEntriesFor(modelData.sources)

                    Column {
                      required property var modelData
                      width: parent.width
                      spacing: Style.space(2)
                      opacity: 0.75

                      Text {
                        width: parent.width
                        text: modelData.title
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        wrapMode: Text.WordWrap
                      }
                      Text {
                        visible: modelData.available
                        width: parent.width
                        text: modelData.body
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        wrapMode: Text.WordWrap
                        textFormat: Text.MarkdownText
                      }
                      Text {
                        visible: !modelData.available
                        width: parent.width
                        text: "(original content unavailable)"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.italic: true
                      }
                    }
                  }
                }

                // ---- After: what's proposed. ----
                Text {
                  text: "AFTER"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  width: parent.width
                  text: modelData.description
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.italic: true
                  wrapMode: Text.WordWrap
                }
                Text {
                  width: parent.width
                  text: modelData.body
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  textFormat: Text.MarkdownText
                }
                PanelSeparator { width: parent.width; foreground: root.foreground }
              }
            }

            PanelSectionHeader {
              visible: root.consolidatePlan && root.consolidatePlan.discard.length > 0
              text: "DISCARDED (" + (root.consolidatePlan ? root.consolidatePlan.discard.length : 0) + ")"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.consolidatePlan ? root.consolidatePlan.discard : []

              Column {
                required property var modelData
                width: parent.width
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: root.titleForFile(modelData.file)
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }
                Text {
                  width: parent.width
                  text: modelData.reason
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Text {
                  visible: root.oldBodyFor(modelData.file) !== ""
                  width: parent.width
                  text: root.oldBodyFor(modelData.file)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  textFormat: Text.MarkdownText
                  opacity: 0.7
                  maximumLineCount: 4
                  elide: Text.ElideRight
                }
              }
            }

            Text {
              visible: root.consolidatePlan && root.consolidatePlan.unchanged.length > 0
              width: parent.width
              text: root.consolidatePlan
                ? (root.consolidatePlan.unchanged.length + " unchanged: "
                  + root.consolidatePlan.unchanged.map(root.titleForFile).join(", "))
                : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.foreground }

            Text {
              width: parent.width
              text: "Type apply to write these changes. This can't be undone (a backup of the current memory is kept)."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            TextField {
              id: consolidateApplyField
              width: parent.width
              foreground: root.foreground
              placeholderText: "apply"
              text: root.consolidateApplyText

              onTextChanged: root.consolidateApplyText = text

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { root.cancelConsolidate(); event.accepted = true; return }
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.performConsolidateApply(); event.accepted = true; return
                }
              }
            }

            Row {
              spacing: Style.spacing.md

              Button {
                text: "Cancel"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.cancelConsolidate()
              }

              Button {
                text: "Apply"
                enabled: root.consolidateApplyText.trim().toLowerCase() === "apply"
                opacity: enabled ? 1 : 0.5
                bordered: true
                foreground: root.urgent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.performConsolidateApply()
              }
            }
          }

          // ---------- Consolidate: applying ----------
          Column {
            visible: root.viewMode === "index" && root.consolidateState === "applying"
            width: parent.width
            spacing: Style.space(10)

            Text {
              text: "Applying…"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          // ---------- Consolidate: error ----------
          Column {
            visible: root.viewMode === "index" && root.consolidateState === "error"
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              text: root.consolidateError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Button {
              text: "Dismiss"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.dismissConsolidateError()
            }
          }

          // ---------- Single entry ----------
          Column {
            visible: root.viewMode === "entry"
            width: parent.width
            spacing: Style.space(10)

            Text {
              visible: root.entryType !== ""
              text: root.entryType.toUpperCase()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              visible: root.entryDescription !== ""
              width: parent.width
              text: root.entryDescription
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
              wrapMode: Text.WordWrap
            }

            PanelSeparator {
              visible: root.entryDescription !== "" || root.entryType !== ""
              foreground: root.foreground
            }

            Text {
              width: parent.width
              text: root.entryBody !== "" ? root.entryBody : "Loading…"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              textFormat: Text.MarkdownText
            }
          }
        }
      }
    }
  }

  // One selectable project row: label only. Highlighted on mouse hover or
  // keyboard cursor alike -- both routes through hoverCursor()/cursorIndex,
  // so there's exactly one highlight rule for both input methods. In manage
  // mode, `selected` persists via CursorSurface's own `current` styling so
  // it stays visible even after the hover/keyboard cursor moves elsewhere.
  component ProjectRow: CursorSurface {
    id: projectRow
    property int rowIndex: 0
    property string label: ""
    property bool manageMode: false
    property bool selected: false
    signal activated()

    hasCursor: root.cursorIndex === rowIndex
    current: manageMode && selected
    foreground: root.foreground
    implicitHeight: projectRowLayout.implicitHeight + Style.spacing.rowPaddingX

    RowLayout {
      id: projectRowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        visible: projectRow.manageMode
        text: projectRow.selected ? "☑" : "☐"
        color: projectRow.selected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        Layout.fillWidth: true
        text: projectRow.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideMiddle
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.hoverCursor(projectRow.rowIndex)
      onClicked: projectRow.activated()
    }
  }

  // One selectable memory-index row: title + hook line. Same highlight rule
  // as ProjectRow.
  component IndexRow: CursorSurface {
    id: indexRow
    property int rowIndex: 0
    property string title: ""
    property string hook: ""
    property bool manageMode: false
    property bool selected: false
    signal activated()

    hasCursor: root.cursorIndex === rowIndex
    current: manageMode && selected
    foreground: root.foreground
    implicitHeight: indexRowLayout.implicitHeight + Style.spacing.rowPaddingX

    RowLayout {
      id: indexRowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        visible: indexRow.manageMode
        Layout.alignment: Qt.AlignTop
        text: indexRow.selected ? "☑" : "☐"
        color: indexRow.selected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Column {
        id: entryCol
        Layout.fillWidth: true
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: indexRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          visible: text !== ""
          width: parent.width
          text: indexRow.hook
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.hoverCursor(indexRow.rowIndex)
      onClicked: indexRow.activated()
    }
  }
}
