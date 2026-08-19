import QtQuick
import QtTest
import "../../logic.js" as Logic

// Runs on the same QML engine the panel does, so what passes here is what
// the panel will actually do. Covers the rules -- index/entry parsing, plan
// validation, stream interpretation -- and not the panel's bindings, layout
// or Process wiring, none of which have logic worth asserting on.
TestCase {
  name: "MemoryPanelLogic"

  // ---- parsing MEMORY.md -------------------------------------------------

  function test_parse_index_reads_title_file_and_hook() {
    var entries = Logic.parseIndex("# Memory\n\n- [Feed feature](feed.md) — how the feed works\nsome prose\n")
    compare(entries.length, 1)
    compare(entries[0].title, "Feed feature")
    compare(entries[0].file, "feed.md")
    compare(entries[0].hook, "how the feed works")
  }

  // The bug that cost three separate fixes: "./name" opens fine but never
  // compares equal to the bare "name" a plan or an argv talks about.
  function test_parse_index_strips_dot_slash_prefix() {
    compare(Logic.parseIndex("- [X](./feedback_x.md) — hi")[0].file, "feedback_x.md")
  }

  function test_parse_index_ignores_lines_that_arent_links() {
    compare(Logic.parseIndex("## Heading\n\n- a plain bullet\n[not a bullet](x.md)\n").length, 0)
  }

  function test_parse_index_accepts_a_link_with_no_hook() {
    var entries = Logic.parseIndex("- [Solo](solo.md)")
    compare(entries.length, 1)
    compare(entries[0].hook, "")
  }

  function test_parse_entry_splits_frontmatter_from_body() {
    var parsed = Logic.parseEntry("---\nname: Title\ndescription: Desc\ntype: note\n---\n\nBody text\n")
    compare(parsed.name, "Title")
    compare(parsed.description, "Desc")
    compare(parsed.type, "note")
    compare(parsed.body, "Body text")
  }

  function test_parse_entry_treats_a_note_without_frontmatter_as_all_body() {
    var parsed = Logic.parseEntry("Just a hand-written note.\n")
    compare(parsed.name, "")
    compare(parsed.body, "Just a hand-written note.")
  }

  // ---- filename safety ---------------------------------------------------

  function test_safe_name_data() {
    return [
      { tag: "plain", name: "notes.md", safe: true },
      { tag: "empty", name: "", safe: false },
      { tag: "subdir", name: "sub/notes.md", safe: false },
      { tag: "traversal", name: "../../.bashrc", safe: false },
      { tag: "dot", name: ".", safe: false },
      { tag: "dotdot", name: "..", safe: false },
      { tag: "leading dot is fine", name: ".hidden.md", safe: true }
    ]
  }

  function test_safe_name(data) {
    compare(Logic.safeName(data.name), data.safe)
  }

  // ---- plan validation ---------------------------------------------------

  function entry(file, sources) {
    return { file: file, title: "T", description: "D", type: "note", body: "B", sources: sources }
  }

  function validPlan() {
    return {
      unchanged: ["keep.md"],
      entries: [entry("merged.md", ["a.md", "b.md"])],
      discard: [{ file: "junk.md", reason: "stale" }]
    }
  }

  function currentFiles() {
    return ["keep.md", "a.md", "b.md", "junk.md"]
  }

  function test_valid_plan_passes() {
    compare(Logic.validateConsolidatePlan(validPlan(), currentFiles()), "")
  }

  function test_entry_may_rewrite_one_of_its_own_sources_in_place() {
    var plan = validPlan()
    plan.entries = [entry("a.md", ["a.md", "b.md"])]
    compare(Logic.validateConsolidatePlan(plan, currentFiles()), "")
  }

  function test_rejects_a_missing_file() {
    var plan = validPlan()
    plan.unchanged = []
    verify(Logic.validateConsolidatePlan(plan, currentFiles()).indexOf("doesn't account for: keep.md") >= 0)
  }

  function test_rejects_a_file_that_isnt_in_the_index() {
    var plan = validPlan()
    plan.unchanged = ["keep.md", "ghost.md"]
    verify(Logic.validateConsolidatePlan(plan, currentFiles()).indexOf("not in the current index") >= 0)
  }

  function test_rejects_a_file_accounted_for_twice() {
    var plan = validPlan()
    plan.unchanged = ["keep.md", "a.md"]
    verify(Logic.validateConsolidatePlan(plan, currentFiles()).indexOf("a.md is listed in both") >= 0)
  }

  function test_rejects_two_entries_targeting_the_same_file() {
    var plan = validPlan()
    plan.entries = [entry("same.md", ["a.md"]), entry("same.md", ["b.md"])]
    verify(Logic.validateConsolidatePlan(plan, currentFiles()).indexOf("Two entries target the same file") >= 0)
  }

  // Every file is accounted for here, so only the last check catches it:
  // the merge writes over keep.md, which it called "unchanged" and never
  // listed as a source, so keep.md's content vanishes unread.
  function test_rejects_an_entry_clobbering_a_file_it_doesnt_own() {
    var plan = validPlan()
    plan.entries = [entry("keep.md", ["a.md", "b.md"])]
    verify(Logic.validateConsolidatePlan(plan, currentFiles()).indexOf("without listing it as a source") >= 0)
  }

  function test_rejects_unsafe_names_data() {
    return [
      { tag: "unchanged", plan: { unchanged: ["../x.md"], entries: [], discard: [] }, reason: "Unsafe filename in unchanged" },
      { tag: "entry file", plan: { unchanged: [], entries: [{ file: "../x.md", sources: [] }], discard: [] }, reason: "Unsafe filename in entries" },
      { tag: "source", plan: { unchanged: [], entries: [{ file: "x.md", sources: ["a/b.md"] }], discard: [] }, reason: "Unsafe source filename" },
      { tag: "discard", plan: { unchanged: [], entries: [], discard: [{ file: "..", reason: "r" }] }, reason: "Unsafe filename in discard" }
    ]
  }

  function test_rejects_unsafe_names(data) {
    verify(Logic.validateConsolidatePlan(data.plan, []).indexOf(data.reason) === 0)
  }

  function test_rejects_a_plan_that_isnt_shaped_like_one_data() {
    return [
      { tag: "not an object", plan: "nope" },
      { tag: "null", plan: null },
      { tag: "missing entries", plan: { unchanged: [], discard: [] } },
      { tag: "entries not a list", plan: { unchanged: [], entries: {}, discard: [] } }
    ]
  }

  function test_rejects_a_plan_that_isnt_shaped_like_one(data) {
    verify(Logic.validateConsolidatePlan(data.plan, []) !== "")
  }

  // Model output, so a null or a bare string can turn up anywhere an object
  // was asked for. It has to come back as an error string; a throw here
  // would leave the panel stuck on "running" with no way out.
  function test_garbled_entries_produce_an_error_not_a_throw() {
    var plan = { unchanged: [], entries: [null, "oops"], discard: [null] }
    verify(Logic.validateConsolidatePlan(plan, []) !== "")
  }

  // ---- MEMORY.md is the index, never an accountable note -----------------

  function test_sanitize_strips_the_index_from_every_bucket() {
    var plan = {
      unchanged: ["MEMORY.md", "keep.md"],
      entries: [entry("merged.md", ["MEMORY.md", "a.md"])],
      discard: [{ file: "MEMORY.md", reason: "x" }, { file: "junk.md", reason: "y" }]
    }
    Logic.sanitizeConsolidatePlan(plan)
    compare(plan.unchanged, ["keep.md"])
    compare(plan.entries[0].sources, ["a.md"])
    compare(plan.discard.length, 1)
    compare(plan.discard[0].file, "junk.md")
  }

  // Left in sources, MEMORY.md would be deleted as "superseded" by the
  // apply step -- so a plan mentioning it must still validate afterwards.
  function test_a_plan_mentioning_the_index_validates_once_sanitized() {
    var plan = validPlan()
    plan.entries[0].sources.push("MEMORY.md")
    compare(Logic.validateConsolidatePlan(Logic.sanitizeConsolidatePlan(plan), currentFiles()), "")
  }

  // ---- interpreting claude's stream --------------------------------------

  function streamResult(plan) {
    return JSON.stringify({ type: "result", is_error: false, result: JSON.stringify(plan) })
  }

  function test_ignores_noise_data() {
    return [
      { tag: "blank", line: "   " },
      { tag: "not json", line: "starting up..." },
      { tag: "unrelated event", line: '{"type":"system","subtype":"init"}' },
      { tag: "assistant text only", line: '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' }
    ]
  }

  function test_ignores_noise(data) {
    compare(Logic.interpretStreamLine(data.line, []).kind, "ignore")
  }

  function test_reports_tool_progress_data() {
    return [
      { tag: "read", tool: "Read", input: { file_path: "/home/x/memory/notes.md" }, text: "Reading notes.md…" },
      { tag: "grep", tool: "Grep", input: { pattern: "TODO" }, text: "Searching TODO…" },
      { tag: "glob", tool: "Glob", input: { path: "src" }, text: "Listing src…" },
      { tag: "unnarrated tool clears the line", tool: "TodoWrite", input: {}, text: "" }
    ]
  }

  function test_reports_tool_progress(data) {
    var line = JSON.stringify({
      type: "assistant",
      message: { content: [{ type: "tool_use", name: data.tool, input: data.input }] }
    })
    var event = Logic.interpretStreamLine(line, [])
    compare(event.kind, "progress")
    compare(event.text, data.text)
  }

  function test_surfaces_a_failed_run() {
    var event = Logic.interpretStreamLine('{"type":"result","is_error":true,"result":"budget exceeded"}', [])
    compare(event.kind, "error")
    compare(event.message, "budget exceeded")
  }

  function test_surfaces_a_result_that_isnt_json() {
    var event = Logic.interpretStreamLine('{"type":"result","is_error":false,"result":"I could not do it."}', [])
    compare(event.kind, "error")
    compare(event.message, "Claude's response wasn't valid JSON.")
  }

  function test_a_result_carrying_a_bad_plan_is_an_error_not_a_review() {
    var plan = validPlan()
    plan.unchanged = []
    var event = Logic.interpretStreamLine(streamResult(plan), currentFiles())
    compare(event.kind, "error")
    verify(event.message.indexOf("doesn't account for") >= 0)
  }

  function test_a_result_carrying_a_good_plan_yields_the_plan() {
    var event = Logic.interpretStreamLine(streamResult(validPlan()), currentFiles())
    compare(event.kind, "plan")
    compare(event.plan.entries[0].file, "merged.md")
  }

  // Sanitizing before validating is what keeps a stray MEMORY.md mention
  // from failing a run that's otherwise fine.
  function test_a_result_mentioning_the_index_still_reaches_review() {
    var plan = validPlan()
    plan.unchanged.push("MEMORY.md")
    compare(Logic.interpretStreamLine(streamResult(plan), currentFiles()).kind, "plan")
  }
}
