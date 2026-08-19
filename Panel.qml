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
      if (root.viewMode === "entry") { if (keyCatcher) keyCatcher.forceActiveFocus() }
      else if (searchField) searchField.forceActiveFocus()
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
        file: m[2].trim(),
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

  onOpenedChanged: if (opened) {
    if (panelFlick) panelFlick.contentY = 0
    openProjects()
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
      // Deleted project dirs no longer show up on disk -- reload the list.
      // Deleted index entries are picked up for free: delete-memory.py
      // rewrites MEMORY.md, and indexFile's watchChanges reloads it.
      if (root.viewMode === "projects") root.refreshProjects()
      focusForView()
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
        if (dx < 0) { root.goBack(); return }
        if (dy !== 0 && panelFlick)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                            Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onCloseRequested: root.goBack()
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
              visible: root.viewMode !== "projects"
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
              visible: root.viewMode !== "entry"
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
            visible: root.viewMode !== "entry"
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
            visible: root.viewMode === "index"
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
