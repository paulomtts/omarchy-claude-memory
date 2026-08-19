# Consolidate memory — design

Status: approved, not yet implemented.

## Problem

A project's memory (`MEMORY.md` + linked notes under
`~/.claude/projects/<slug>/memory/`) accumulates over time: entries go
stale, overlap, or turn out wrong. There's no way to clean that up short of
deleting entries one at a time via manage mode. This adds a button, visible
only while viewing one project's memory index, that asks Claude Code to
propose a consolidated set — merging redundant entries and dropping stale
or wrong ones — which the user reviews in full before anything is written.

## Non-goals

- Editing arbitrary prose inside `MEMORY.md` (headers, inline non-linked
  bullets). Scope is limited to the linked entries this plugin already
  understands (the `- [Title](file.md) — hook` lines and the files they
  point to). Everything else in `MEMORY.md` passes through untouched.
- Per-item accept/reject in the review UI. v1 is all-or-nothing: Apply
  everything or Cancel and, if desired, re-run.
- In-app undo. A pre-apply backup copy is the safety net instead.

## Claude invocation

Run from the memory dir (`cwd`), with `--add-dir` granting read access to
the project's actual source tree (the same path `resolve-projects.py`
already resolves), so Claude can check whether a memory claim still holds
against the current code — not just judge the note text in isolation.

```
claude -p \
  --output-format stream-json --include-partial-messages --verbose \
  --tools "Read,Glob,Grep" \
  --permission-mode plan \
  --add-dir <resolved-source-dir> \
  --json-schema '<schema below>' \
  --max-budget-usd 1.00 \
  "<instructions below>"
```

Safety is defense-in-depth by two independent mechanisms: `--tools`
restricts to read-only tools (no Write/Edit/Bash), and `--permission-mode
plan` additionally disallows any mutating action regardless of tool list.
Neither depends on the model "choosing" to behave.

`--max-budget-usd 1.00` is a hard spending cap per run, independent of both
of the above.

If the source dir can't be resolved (project moved/deleted — the same case
`resolve-projects.py` already falls back to showing the raw slug for),
`--add-dir` is omitted and the instructions note that only the memory notes
themselves are available, not the source project.

### Instructions (the prompt argument)

```
You are consolidating the persistent memory notes for a software project.
The current directory contains that project's Claude Code memory: MEMORY.md
(an index of notes) and the *.md files it links to. An additional directory
has been granted read-only for reference: the actual source project these
notes are about, so you can check whether a note is still accurate against
the current code rather than judging the note text alone.

Read MEMORY.md and every note file it links to. Then:
- Merge notes that are clearly redundant or that overlap enough that one
  higher-quality note serves better than several partial ones.
- Discard notes that are stale, factually wrong, or no longer useful —
  check against the source project when a note makes a claim about code
  that still exists.
- Leave a note unchanged if it's still accurate and useful and doesn't
  belong in a merge.

Every original note file must be accounted for in exactly one of: unchanged,
one merged/edited entry's sources, or discard. When a merge needs a new
file (rather than reusing one source's filename), give it a short
snake_case name ending in .md, in the style of the existing note filenames
(e.g. feedback_topic.md). Do not modify any files — report your plan only.
Return your plan as JSON matching the provided schema.
```

### Output schema (`--json-schema`)

```json
{
  "type": "object",
  "properties": {
    "summary": { "type": "string" },
    "unchanged": { "type": "array", "items": { "type": "string" } },
    "entries": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "file": { "type": "string" },
          "title": { "type": "string" },
          "description": { "type": "string" },
          "type": { "type": "string" },
          "body": { "type": "string" },
          "sources": { "type": "array", "items": { "type": "string" } }
        },
        "required": ["file", "title", "description", "type", "body", "sources"]
      }
    },
    "discard": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "file": { "type": "string" },
          "reason": { "type": "string" }
        },
        "required": ["file", "reason"]
      }
    }
  },
  "required": ["summary", "unchanged", "entries", "discard"]
}
```

`entries[].file` is either an existing filename (single-source edit/tighten
— that file's own content is replaced) or a new filename (multi-source
merge). `sources` lists every original file this entry's content is based
on / supersedes. `type` matches this plugin's existing frontmatter
convention (`user` / `feedback` / `project` / `reference`).

The CLI's JSON envelope wraps the reply in `.result` as a string; that
string is what gets parsed against the schema above (parse `.result` with
`JSON.parse`, not the envelope itself).

## Progress UI

`--output-format stream-json` emits one JSON object per line as the run
progresses. Parse each line; when it's an assistant message containing a
`tool_use` block, update a single "current action" line from the tool name
+ its primary path/pattern argument (e.g. "Reading feedback_x.md…",
"Searching src/auth.py…"). Not a scrolling log — just what's happening
right now, plus an elapsed-time readout from a Timer. On a `type: "result"`
line, the run is done (check `is_error` first).

## Review UI

Reached after the plan parses and its file-accounting invariant is
re-validated (every original file in exactly one of unchanged / some
entry's sources / discard — checked against the real current directory
listing, not trusted blindly from the model's output). If the invariant
fails, treat it as an error (see Error handling) rather than showing a
plan that might silently lose track of a file.

Three sections, in this order:
1. **Proposed** — each `entries[]` item: title, type badge, description,
   full rendered body (same `Text { textFormat: Text.MarkdownText }`
   treatment as the existing single-entry view), and a small "supersedes:
   a.md, b.md" line from `sources`.
2. **Discarded** — each `discard[]` item: title (looked up from the
   current index by filename) + `reason`, styled with the existing
   `urgent` color to read as a removal.
3. **Unchanged** — compact, low-emphasis: "N entries unchanged" plus their
   titles, not full content.

Two actions: **Apply**, gated behind typing the word `apply` (same
type-to-confirm `TextField` pattern as manage-mode delete — applying does
delete/overwrite files, so it gets the same safety gate) — and **Cancel**,
which discards the proposal and touches nothing.

## Apply

New script, `consolidate-apply.py`, invoked with the memory dir as argv and
the full plan JSON piped via stdin (large payload, avoids argv limits).
Mirrors `delete-memory.py`'s safety posture:

1. Re-validate the target is genuinely a `memory` directory (same
   `is_memory_dir` check).
2. Re-validate the file-accounting invariant against the *actual current*
   directory listing (not the listing from when the plan was generated —
   the two calls are seconds apart, but re-check anyway; refuse to apply on
   mismatch rather than guess).
3. Validate every filename (existing or new) is a safe plain basename — no
   `/`, no `..`, non-empty — reusing the same checks as `delete-memory.py`.
4. Copy the whole `memory/` directory to
   `~/.cache/omarchy-claude-memory/backups/<slug>-<timestamp>/` as an undo
   safety net (`<slug>` = the memory dir's parent directory name).
5. Write each `entries[]` item as frontmatter (`name`, `description`,
   `type`) + `body` to `file` (create or overwrite).
6. Delete every file in `discard[]`, and every file in some entry's
   `sources` that isn't equal to that entry's own `file`.
7. Rewrite `MEMORY.md`: for each existing line, if it's an index line
   (`- [Title](href) — hook`) whose href is in the discard/superseded set,
   drop the line; if its href is in `unchanged`, leave the line untouched;
   any line that isn't a matched index line (headers, inline bullets, etc.)
   is left untouched, unconditionally. Append one new index line per
   `entries[]` item at the end of the file: `- [title](file) — description`.

One result line per file operation to stdout (`ok\t<file>` /
`error\t<file>\t<message>`), same convention as `delete-memory.py`, so the
panel can report partial failures.

**Known limitation:** steps 5–7 are not transactional. A failure partway
through (disk full, permissions) can leave the memory dir in a mixed state.
The step-4 backup is the recovery path; there's no automatic rollback.

## State machine (Panel.qml)

```
idle -> (click Consolidate, confirm heads-up) -> running
running -> (stream-json result, plan valid) -> review
running -> (error / invalid plan / nonzero exit) -> error
review -> (Cancel) -> idle
review -> (type "apply", confirm) -> applying
applying -> (done) -> idle          // MEMORY.md rewrite is picked up by
                                     // the existing indexFile watcher, same
                                     // as the manage-mode delete flow
applying -> (error) -> error
error -> (dismiss) -> idle
```

`consolidatePlan` is discarded on both Cancel and successful Apply — a
fresh run always starts from a clean `running` state.

## UI placement

"✨ Consolidate" button in the header row, visible only when
`viewMode === "index"` (i.e. only "inside a project's folder"), alongside
the existing Back / title / Manage controls.
