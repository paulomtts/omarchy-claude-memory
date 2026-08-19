.pragma library

// The panel's decisions, with none of the panel in them: parsing what the
// scripts hand back, and judging a consolidation plan before any of it is
// shown as something the user can apply. Nothing here touches a property,
// a Process, or the filesystem, so all of it is exercised directly by
// tests/qml/tst_logic.qml on the same engine the panel runs on.
//
// The plan rules are deliberately a second implementation of
// consolidate_plan.py's, in the same order and with the same outcomes:
// the panel refuses to offer a bad plan for review, and the apply script
// refuses to act on one, independently. Change one, change the other.

var INDEX_FILE = "MEMORY.md"

var INDEX_LINE_RE = /^-\s*\[([^\]]+)\]\(([^)]+)\)\s*(.*)$/
var FRONTMATTER_RE = /^---\n([\s\S]*?)\n---\n?([\s\S]*)$/

// A "./" prefix is a no-op for actually opening the file, but it breaks
// every place that compares filenames by exact string equality -- notably
// Claude's own consolidation plans, which reference files by the bare name
// Read/Glob report, never "./name". Normalizing here means every consumer
// of parseIndex() sees the one form the Python side also assumes.
function normalizeHref(href) {
  return String(href || "").trim().replace(/^\.\//, "")
}

// MEMORY.md -> [{ title, file, hook }]. Lines that aren't note links are
// prose and are skipped.
function parseIndex(content) {
  var out = []
  String(content || "").split("\n").forEach(function(line) {
    var m = line.match(INDEX_LINE_RE)
    if (!m) return
    out.push({
      title: m[1].trim(),
      file: normalizeHref(m[2]),
      hook: String(m[3] || "").replace(/^[—-]\s*/, "").trim()
    })
  })
  return out
}

// A note file -> its frontmatter fields plus the body. A file without
// frontmatter is all body, which is how hand-written notes read.
function parseEntry(content) {
  var text = String(content || "")
  var m = text.match(FRONTMATTER_RE)
  if (!m) return { name: "", description: "", type: "", body: text.trim() }
  var front = m[1]
  function field(re) {
    var hit = front.match(re)
    return hit ? hit[1].trim() : ""
  }
  return {
    name: field(/^name:\s*(.*)$/m),
    description: field(/^description:\s*(.*)$/m),
    type: field(/^\s*type:\s*(.*)$/m),
    body: m[2].trim()
  }
}

function safeName(n) {
  return n !== "" && n.indexOf("/") < 0 && n !== "." && n !== ".."
}

// MEMORY.md is the index itself, not one of the notes it links to, but the
// model lists it in unchanged/sources/discard anyway often enough to
// matter. The mention is harmless noise -- strip it wherever it appears
// rather than let it either block an otherwise-complete plan (accounted
// for but absent from the index) or, far worse, sit in some entry's
// sources, where the apply step would delete the index as "superseded".
function sanitizeConsolidatePlan(plan) {
  if (!plan || typeof plan !== "object") return plan
  if (Array.isArray(plan.unchanged))
    plan.unchanged = plan.unchanged.filter(function(f) { return f !== INDEX_FILE })
  if (Array.isArray(plan.entries))
    plan.entries.forEach(function(entry) {
      if (entry && Array.isArray(entry.sources))
        entry.sources = entry.sources.filter(function(s) { return s !== INDEX_FILE })
    })
  if (Array.isArray(plan.discard))
    plan.discard = plan.discard.filter(function(item) { return !item || item.file !== INDEX_FILE })
  return plan
}

// Item accessors, not property access: a plan is model output, so any
// element of any array may not be an object at all. Reading a missing
// field as "" lets the checks report a clean error instead of throwing,
// which would strand consolidateState at "running" forever.
function entryFile(entry) {
  return (entry && typeof entry === "object" && entry.file) ? String(entry.file) : ""
}

function entrySources(entry) {
  return (entry && typeof entry === "object" && Array.isArray(entry.sources)) ? entry.sources : []
}

function discardFile(item) {
  return (item && typeof item === "object" && item.file) ? String(item.file) : ""
}

// Returns "" if the plan is safe to show for review, or the reason it
// isn't. `currentFiles` is the list of filenames MEMORY.md links to right
// now -- the plan's accounting is checked against that, never against the
// plan's own idea of what was there.
function validateConsolidatePlan(plan, currentFiles) {
  if (!plan || typeof plan !== "object") return "Claude's response wasn't a JSON object."
  var unchanged = Array.isArray(plan.unchanged) ? plan.unchanged : null
  var entries = Array.isArray(plan.entries) ? plan.entries : null
  var discard = Array.isArray(plan.discard) ? plan.discard : null
  if (!unchanged || !entries || !discard) return "Claude's response was missing unchanged/entries/discard."

  return checkFilenames(unchanged, entries, discard)
      || checkFields(entries, discard)
      || checkUniqueTargets(entries)
      || checkAccounting(unchanged, entries, discard, currentFiles || [])
}

// Every field the review screen renders and the apply step interpolates
// into frontmatter or an index line has to be a string, and the
// single-line ones can't carry a newline that would forge a second YAML
// key or a second index entry.
function checkFields(entries, discard) {
  for (var e = 0; e < entries.length; e++) {
    var fields = ["title", "description", "type"]
    for (var f = 0; f < fields.length; f++)
      if (!isSingleLineString(field(entries[e], fields[f])))
        return "Entry missing or invalid field: " + fields[f]
    if (typeof field(entries[e], "body") !== "string") return "Entry missing or invalid field: body"
    if (!Array.isArray(field(entries[e], "sources"))) return "Entry missing or invalid field: sources"
  }
  for (var d = 0; d < discard.length; d++)
    if (!isSingleLineString(field(discard[d], "reason")))
      return "Discard item missing or invalid field: reason"
  return ""
}

function field(obj, name) {
  return (obj && typeof obj === "object") ? obj[name] : undefined
}

function isSingleLineString(value) {
  return typeof value === "string" && value.indexOf("\n") < 0
}

function checkFilenames(unchanged, entries, discard) {
  for (var u = 0; u < unchanged.length; u++)
    if (!safeName(String(unchanged[u]))) return "Unsafe filename in unchanged: " + unchanged[u]
  for (var e = 0; e < entries.length; e++) {
    var ef = entryFile(entries[e])
    if (!safeName(ef)) return "Unsafe filename in entries: " + ef
    var sources = entrySources(entries[e])
    for (var s = 0; s < sources.length; s++)
      if (!safeName(String(sources[s]))) return "Unsafe source filename: " + sources[s]
  }
  for (var d = 0; d < discard.length; d++) {
    var df = discardFile(discard[d])
    if (!safeName(df)) return "Unsafe filename in discard: " + df
  }
  return ""
}

function checkUniqueTargets(entries) {
  var seen = {}
  for (var i = 0; i < entries.length; i++) {
    var target = entryFile(entries[i])
    if (target === "") continue
    if (seen[target]) return "Two entries target the same file: " + target
    seen[target] = true
  }
  return ""
}

// The invariant the whole feature rests on: every file the index links to
// today ends up in exactly one bucket, and the plan invents no files that
// aren't there. Anything else means a note was lost track of, and applying
// would silently drop or clobber it.
function checkAccounting(unchanged, entries, discard, currentFiles) {
  var accounted = {}
  var conflict = ""
  function account(name, bucket) {
    if (conflict !== "") return
    if (accounted[name]) conflict = name + " is listed in both " + accounted[name] + " and " + bucket
    else accounted[name] = bucket
  }
  unchanged.forEach(function(name) { account(name, "unchanged") })
  entries.forEach(function(entry) {
    entrySources(entry).forEach(function(source) { account(source, "entries[].sources") })
  })
  discard.forEach(function(item) { account(discardFile(item), "discard") })
  if (conflict !== "") return conflict

  var missing = currentFiles.filter(function(f) { return !accounted[f] })
  if (missing.length > 0) return "Plan doesn't account for: " + missing.join(", ")
  // A name the model invented for one of its own new entries sometimes
  // also turns up in that same entry's sources or in unchanged -- harmless
  // self-reference to a file that doesn't exist yet, not an invented *old*
  // file, so it doesn't count as "extra". The apply side separately
  // guarantees a fresh entry target is never deleted even if this same
  // confusion puts it in discard instead.
  var newTargets = entries.map(entryFile)
  var extra = Object.keys(accounted).filter(function(f) {
    return currentFiles.indexOf(f) < 0 && newTargets.indexOf(f) < 0
  })
  if (extra.length > 0) return "Plan references files not in the current index: " + extra.join(", ")

  for (var i = 0; i < entries.length; i++) {
    var target = entryFile(entries[i])
    if (currentFiles.indexOf(target) >= 0 && entrySources(entries[i]).indexOf(target) < 0)
      return "Entry targets existing file " + target + " without listing it as a source."
  }
  return ""
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

// One line of claude's --output-format stream-json, turned into what the
// panel should do about it:
//
//   { kind: "ignore" }                 nothing to show (or unparseable)
//   { kind: "progress", text }         a tool call worth narrating
//   { kind: "error", message }         the run failed, or the plan is unsafe
//   { kind: "plan", plan }             a validated plan, ready to review
//
// Keeping the interpretation here means the panel's reader only maps a
// kind onto state, and every branch below is reachable from a test.
function interpretStreamLine(line, currentFiles) {
  var text = String(line || "").trim()
  if (text === "") return { kind: "ignore" }
  var evt
  try { evt = JSON.parse(text) } catch (e) { return { kind: "ignore" } }
  if (!evt || typeof evt !== "object") return { kind: "ignore" }

  if (evt.type === "assistant" && evt.message && Array.isArray(evt.message.content))
    return interpretToolUse(evt.message.content)
  if (evt.type !== "result") return { kind: "ignore" }
  if (evt.is_error)
    return { kind: "error", message: String(evt.result || "Claude Code exited with an error.") }

  var plan
  try { plan = JSON.parse(String(evt.result || "")) } catch (e) {
    return { kind: "error", message: "Claude's response wasn't valid JSON." }
  }
  plan = sanitizeConsolidatePlan(plan)
  var invalid = validateConsolidatePlan(plan, currentFiles)
  return invalid !== "" ? { kind: "error", message: invalid } : { kind: "plan", plan: plan }
}

// The last tool_use in the message wins, matching the order they'd have
// run in. A tool with nothing worth narrating clears the line rather than
// leaving the previous tool's text up as if it were still running.
function interpretToolUse(blocks) {
  var found = false
  var text = ""
  blocks.forEach(function(block) {
    if (!block || block.type !== "tool_use") return
    found = true
    text = toolProgressText(block.name, block.input)
  })
  return found ? { kind: "progress", text: text } : { kind: "ignore" }
}
