# Consolidate Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "✨ Consolidate" button, visible only in a project's memory-index view, that asks Claude Code to propose a merged/pruned set of that project's memory notes, streams live progress while it works, and requires a full review (proposed content + discard reasons) before writing anything.

**Architecture:** Two new standalone Python scripts alongside the existing `resolve-projects.py`/`delete-memory.py` — `consolidate-run.py` (builds and `execvp`s into `claude -p` with read-only tool access, `--permission-mode plan`, and `--json-schema` so the model can't mutate anything and must return schema-conformant JSON) and `consolidate-apply.py` (re-validates the reviewed plan against the real filesystem and writes it, after a backup). Panel.qml gets a small state machine (`consolidateState`: idle → confirming → running → review → applying → idle/error) driving a new UI section, streaming `claude`'s `stream-json` output line-by-line for live progress text.

**Tech Stack:** QML (Quickshell.Io `Process`/`SplitParser`/`StdioCollector`), Python 3 stdlib only, the `claude` CLI.

**Spec:** `docs/superpowers/specs/2026-08-19-consolidate-memory-design.md`

## Global Constraints

- No shell interpolation of untrusted values: every path passed to a subprocess goes through `argv`, never through a `bash -c` string built by concatenation (matches `resolve-projects.py`/`delete-memory.py`'s existing convention).
- Every filename touched by a script must be validated as a plain basename (no `/`, not `.`/`..`) before any filesystem operation, exactly like `delete-memory.py`'s `is_safe_filename`-equivalent checks.
- `claude` runs with `--tools "Read,Glob,Grep"` **and** `--permission-mode plan` together — two independent mechanisms, neither optional, per the spec's "defense-in-depth" requirement.
- No live keyboard/mouse UI testing in this session (a prior incident had synthetic keystrokes leak into an unrelated live terminal). Verification is: passive log inspection after `omarchy-shell shell rescanPlugins` / `omarchy restart shell` (`journalctl --user -n N --no-pager | grep -iE "error|warn"`, excluding the known-unrelated `portal`/`ghostty` noise already seen in this session), direct standalone invocation of the two Python scripts against constructed throwaway fixtures, and careful code review — the same pattern already used for `resolve-projects.py` and `delete-memory.py` earlier in this plugin's history.
- Every task ends with `git add` + `git commit` in `/home/mtts/.config/omarchy/plugins/paulomtts.claude-memory` (the plugin dir is the git repo root, already pushed to `github.com/paulomtts/omarchy-claude-memory`). Do not `git push` until Task 6 — commit locally per task so each is independently reviewable, push once at the end.

---

## Task 1: `consolidate-apply.py`

**Files:**
- Create: `consolidate-apply.py`

**Interfaces:**
- Consumes: nothing from other tasks (standalone script).
- Produces: a CLI invoked as `python3 consolidate-apply.py <memory_dir>` with the plan JSON on stdin, shaped `{"unchanged": [...], "entries": [...], "discard": [...]}` (see script docstring below for the exact per-item shape). Emits one `ok\t<item>` / `error\t<item>\t<message>` line per file operation to stdout, matching `delete-memory.py`'s convention. Task 4 (Panel.qml UI) spawns this exact command.

- [ ] **Step 1: Write the script**

```python
#!/usr/bin/env python3
"""Apply a reviewed consolidation plan to one project's memory directory.

Invoked as: consolidate-apply.py <memory_dir>
with the plan JSON piped via stdin, shaped as:

{
  "unchanged": ["file.md", ...],
  "entries": [
    {"file": "...", "title": "...", "description": "...", "type": "...",
     "body": "...", "sources": ["file.md", ...]},
    ...
  ],
  "discard": [{"file": "...", "reason": "..."}]
}

Mirrors delete-memory.py's safety posture, plus checks specific to a
model-generated plan: the memory dir and every filename are re-validated
against the real filesystem (never trust the plan blindly), and the
file-accounting invariant -- every original file must be in exactly one of
unchanged / some entry's sources / discard -- is re-checked against the
*current* directory listing before anything is written.

Before touching anything, the whole memory dir is copied to
~/.cache/omarchy-claude-memory/backups/<slug>-<timestamp>/ as an undo
safety net, since there is no in-app undo.

One result line per file operation goes to stdout, same convention as
delete-memory.py: "ok\\t<file>" or "error\\t<file>\\t<message>".
"""
import json
import os
import re
import shutil
import sys
import time

INDEX_LINE_RE = re.compile(r"^-\s*\[([^\]]+)\]\(([^)]+)\)\s*(.*)$")


def is_memory_dir(path):
    return os.path.isdir(path) and os.path.basename(os.path.normpath(path)) == "memory"


def is_safe_filename(name):
    return name != "" and "/" not in name and name not in (".", "..")


def existing_entry_files(memory_dir):
    """Every file this project's MEMORY.md currently links to."""
    index_path = os.path.join(memory_dir, "MEMORY.md")
    if not os.path.isfile(index_path):
        return set()
    files = set()
    with open(index_path, "r", encoding="utf-8") as f:
        for line in f.read().split("\n"):
            m = INDEX_LINE_RE.match(line)
            if m:
                files.add(m.group(2).strip())
    return files


def validate_plan(memory_dir, plan):
    """Returns an error string, or None if the plan is safe to apply."""
    if not isinstance(plan, dict):
        return "plan is not a JSON object"
    unchanged = plan.get("unchanged", [])
    entries = plan.get("entries", [])
    discard = plan.get("discard", [])
    if not isinstance(unchanged, list) or not isinstance(entries, list) or not isinstance(discard, list):
        return "plan has the wrong shape"

    for name in unchanged:
        if not is_safe_filename(name):
            return "unsafe filename in unchanged: " + str(name)
    for entry in entries:
        if not is_safe_filename(entry.get("file", "")):
            return "unsafe filename in entries: " + str(entry.get("file"))
        for source in entry.get("sources", []):
            if not is_safe_filename(source):
                return "unsafe source filename: " + str(source)
    for item in discard:
        if not is_safe_filename(item.get("file", "")):
            return "unsafe filename in discard: " + str(item.get("file"))

    target_files = [entry.get("file", "") for entry in entries]
    if len(target_files) != len(set(target_files)):
        return "two entries target the same file"

    accounted = {}

    def account(name, bucket):
        if name in accounted:
            return "%s is listed in both %s and %s" % (name, accounted[name], bucket)
        accounted[name] = bucket
        return None

    for name in unchanged:
        err = account(name, "unchanged")
        if err:
            return err
    for entry in entries:
        for source in entry.get("sources", []):
            err = account(source, "entries[].sources")
            if err:
                return err
    for item in discard:
        err = account(item.get("file", ""), "discard")
        if err:
            return err

    current = existing_entry_files(memory_dir)
    missing = current - set(accounted.keys())
    extra = set(accounted.keys()) - current
    if missing:
        return "plan doesn't account for: " + ", ".join(sorted(missing))
    if extra:
        return "plan references files that aren't in the current index: " + ", ".join(sorted(extra))

    for entry in entries:
        target = entry.get("file", "")
        if target in current and target not in entry.get("sources", []):
            return "entry targets existing file %s without listing it as a source" % target

    return None


def backup(memory_dir):
    slug = os.path.basename(os.path.dirname(os.path.normpath(memory_dir)))
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime())
    dest_root = os.path.expanduser("~/.cache/omarchy-claude-memory/backups")
    dest = os.path.join(dest_root, slug + "-" + stamp)
    os.makedirs(dest_root, exist_ok=True)
    shutil.copytree(memory_dir, dest)
    return dest


def write_entry(memory_dir, entry):
    path = os.path.join(memory_dir, entry["file"])
    frontmatter = (
        "---\n"
        "name: " + entry["title"] + "\n"
        "description: " + entry["description"] + "\n"
        "type: " + entry["type"] + "\n"
        "---\n\n"
    )
    with open(path, "w", encoding="utf-8") as f:
        f.write(frontmatter + entry["body"].strip() + "\n")


def rewrite_index(memory_dir, plan):
    index_path = os.path.join(memory_dir, "MEMORY.md")
    superseded = set()
    for entry in plan["entries"]:
        for source in entry["sources"]:
            if source != entry["file"]:
                superseded.add(source)
    discarded = set(item["file"] for item in plan["discard"])
    drop = superseded | discarded

    lines = []
    if os.path.isfile(index_path):
        with open(index_path, "r", encoding="utf-8") as f:
            lines = f.read().split("\n")

    kept = []
    for line in lines:
        m = INDEX_LINE_RE.match(line)
        if m and m.group(2).strip() in drop:
            continue
        kept.append(line)

    while kept and kept[-1].strip() == "":
        kept.pop()

    for entry in plan["entries"]:
        kept.append("- [" + entry["title"] + "](" + entry["file"] + ") — " + entry["description"])

    with open(index_path, "w", encoding="utf-8") as f:
        f.write("\n".join(kept) + "\n")


def apply_plan(memory_dir, plan):
    for entry in plan["entries"]:
        try:
            write_entry(memory_dir, entry)
            print("ok\t" + entry["file"])
        except OSError as e:
            print("error\t" + entry["file"] + "\t" + str(e))

    superseded = set()
    for entry in plan["entries"]:
        for source in entry["sources"]:
            if source != entry["file"]:
                superseded.add(source)
    to_delete = superseded | set(item["file"] for item in plan["discard"])
    for name in to_delete:
        target = os.path.join(memory_dir, name)
        try:
            if os.path.isfile(target):
                os.remove(target)
            print("ok\t" + name)
        except OSError as e:
            print("error\t" + name + "\t" + str(e))

    try:
        rewrite_index(memory_dir, plan)
        print("ok\tMEMORY.md")
    except OSError as e:
        print("error\tMEMORY.md\t" + str(e))


def main():
    if len(sys.argv) < 2:
        print("error\t\tusage: consolidate-apply.py <memory_dir> (plan JSON on stdin)")
        sys.exit(2)
    memory_dir = sys.argv[1]

    if not is_memory_dir(memory_dir):
        print("error\t" + memory_dir + "\tnot a memory directory")
        sys.exit(1)

    try:
        plan = json.loads(sys.stdin.read())
    except ValueError as e:
        print("error\t\tinvalid plan JSON: " + str(e))
        sys.exit(1)

    error = validate_plan(memory_dir, plan)
    if error:
        print("error\t\t" + error)
        sys.exit(1)

    try:
        backup(memory_dir)
    except OSError as e:
        print("error\t\tcould not back up memory dir: " + str(e))
        sys.exit(1)

    apply_plan(memory_dir, plan)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Build throwaway test fixtures**

```bash
T=/tmp/consolidate-apply-test
rm -rf "$T"
mkdir -p "$T/memory"
cat > "$T/memory/MEMORY.md" <<'EOF'
# Test project memory

## Some inline section (not an index line -- must survive untouched)
- Plain bullet with no link, just prose.

- [Entry A](a.md) — hook a
- [Entry B](b.md) — hook b
- [Entry C](c.md) — hook c
- [Entry D](d.md) — hook d
EOF
echo "content a" > "$T/memory/a.md"
echo "content b" > "$T/memory/b.md"
echo "content c" > "$T/memory/c.md"
echo "content d" > "$T/memory/d.md"
```

- [ ] **Step 3: Verify the happy path — merge two, discard one, leave one unchanged**

```bash
cd /home/mtts/.config/omarchy/plugins/paulomtts.claude-memory
python3 consolidate-apply.py "$T/memory" <<'EOF'
{
  "unchanged": ["d.md"],
  "entries": [
    {"file": "a.md", "title": "Merged A+B", "description": "combined hook",
     "type": "feedback", "body": "Merged content.", "sources": ["a.md", "b.md"]}
  ],
  "discard": [{"file": "c.md", "reason": "stale"}]
}
EOF
```
Expected: three `ok\t...` lines (`a.md`, `b.md`, `c.md` — b.md and c.md are the ones actually deleted; a.md is overwritten in place) plus `ok\tMEMORY.md`, and exit code 0.

- [ ] **Step 4: Inspect the result**

```bash
cat "$T/memory/a.md"
echo "--- b.md exists: $([ -f "$T/memory/b.md" ] && echo yes || echo no)"
echo "--- c.md exists: $([ -f "$T/memory/c.md" ] && echo yes || echo no)"
echo "--- d.md exists: $([ -f "$T/memory/d.md" ] && echo yes || echo no)"
cat "$T/memory/MEMORY.md"
ls ~/.cache/omarchy-claude-memory/backups/
```
Expected: `a.md` now has the merged frontmatter+body; `b.md`/`c.md` gone; `d.md` untouched; `MEMORY.md` still has the "Some inline section" prose exactly as before, the `d.md` index line untouched, the `a.md`/`b.md`/`c.md` lines replaced by one new line for the merged entry; a backup directory exists under `~/.cache/omarchy-claude-memory/backups/`.

- [ ] **Step 5: Verify invariant rejection — plan omits a file**

```bash
mkdir -p "$T/memory2"
cat > "$T/memory2/MEMORY.md" <<'EOF'
- [Entry X](x.md) — hook x
- [Entry Y](y.md) — hook y
EOF
echo x > "$T/memory2/x.md"
echo y > "$T/memory2/y.md"
python3 consolidate-apply.py "$T/memory2" <<'EOF'
{"unchanged": ["x.md"], "entries": [], "discard": []}
EOF
echo "exit: $?"
```
Expected: `error\t\tplan doesn't account for: y.md` and a nonzero exit code. Confirm nothing was written: `cat "$T/memory2/MEMORY.md"` still shows both original lines, `x.md`/`y.md` both still exist.

- [ ] **Step 6: Verify duplicate-accounting rejection**

```bash
python3 consolidate-apply.py "$T/memory2" <<'EOF'
{"unchanged": ["x.md", "y.md"], "entries": [], "discard": [{"file": "y.md", "reason": "dup"}]}
EOF
echo "exit: $?"
```
Expected: `error\t\ty.md is listed in both unchanged and discard` and nonzero exit.

- [ ] **Step 7: Verify path-traversal / unsafe-filename rejection**

```bash
python3 consolidate-apply.py "$T/memory2" <<'EOF'
{"unchanged": [], "entries": [], "discard": [{"file": "../x.md", "reason": "escape attempt"}]}
EOF
echo "exit: $?"
```
Expected: `error\t\tunsafe filename in discard: ../x.md` and nonzero exit. (Note this also fails the invariant since `x.md`/`y.md` from `memory2` wouldn't be accounted for either, but the unsafe-filename check runs first and should be what's reported.)

- [ ] **Step 8: Verify non-memory-directory rejection**

```bash
python3 consolidate-apply.py "$T" <<'EOF'
{"unchanged": [], "entries": [], "discard": []}
EOF
echo "exit: $?"
rm -rf "$T" ~/.cache/omarchy-claude-memory/backups/consolidate-apply-test-*
```
Expected: `error\t/tmp/consolidate-apply-test\tnot a memory directory` (since `$T` itself, not `$T/memory`, was passed) and nonzero exit. The final cleanup also removes the real backup directory Step 4 created under `~/.cache/omarchy-claude-memory/backups/` (that path is outside `$T`, since backups are meant to survive even if the source memory dir is later removed).

- [ ] **Step 9: Commit**

```bash
cd /home/mtts/.config/omarchy/plugins/paulomtts.claude-memory
git add consolidate-apply.py
git commit -m "$(cat <<'EOF'
Add consolidate-apply.py: safely write a reviewed consolidation plan

Re-validates the memory dir and the plan's file-accounting invariant
against the real filesystem before touching anything, backs the memory
dir up first, then writes new/merged entries, deletes superseded and
discarded files, and rewrites MEMORY.md's index lines only -- any other
prose in MEMORY.md is left untouched.
EOF
)"
```

---

## Task 2: `consolidate-run.py`

**Files:**
- Create: `consolidate-run.py`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a CLI invoked as `python3 consolidate-run.py <memory_dir> <source_dir>` (source_dir may be `""`). On success it `execvp`s into `claude`, so its stdout *becomes* `claude`'s raw `--output-format stream-json` stream — Task 3 spawns this exact command with `Process.workingDirectory` set to `<memory_dir>` first. A leading `--dry-run` flag prints `{"argv": [...]}` and exits instead of exec'ing, for testing without spending money.

- [ ] **Step 1: Write the script**

```python
#!/usr/bin/env python3
"""Build and exec the `claude` invocation that proposes a memory
consolidation plan for one project.

Usage: consolidate-run.py [--dry-run] <memory_dir> [<source_dir>]

<source_dir> is the project's real source tree (already resolved by
resolve-projects.py), or "" if it couldn't be resolved -- in that case
Claude only sees the memory notes, not the source code they're about.

Execs `claude` directly (no subprocess layer holding a pipe buffer in
between), so the caller sees claude's own --output-format stream-json
lines with no added latency or transformation. The caller (Panel.qml) sets
Process.workingDirectory to <memory_dir> before spawning this script, so
`claude` inherits that same cwd across the exec.

--dry-run prints the argv that would be exec'd, as a JSON object, and
exits without spending anything -- for testing the path validation and
command construction without invoking the real (paid) `claude` CLI.
"""
import json
import os
import sys

SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "unchanged": {"type": "array", "items": {"type": "string"}},
        "entries": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "file": {"type": "string"},
                    "title": {"type": "string"},
                    "description": {"type": "string"},
                    "type": {"type": "string"},
                    "body": {"type": "string"},
                    "sources": {"type": "array", "items": {"type": "string"}},
                },
                "required": ["file", "title", "description", "type", "body", "sources"],
            },
        },
        "discard": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "file": {"type": "string"},
                    "reason": {"type": "string"},
                },
                "required": ["file", "reason"],
            },
        },
    },
    "required": ["summary", "unchanged", "entries", "discard"],
}

INSTRUCTIONS_WITH_SOURCE = """You are consolidating the persistent memory notes for a software project.
The current directory contains that project's Claude Code memory: MEMORY.md
(an index of notes) and the *.md files it links to. An additional directory
has been granted read-only for reference: the actual source project these
notes are about, so you can check whether a note is still accurate against
the current code rather than judging the note text alone.

Read MEMORY.md and every note file it links to. Then:
- Merge notes that are clearly redundant or that overlap enough that one
  higher-quality note serves better than several partial ones.
- Discard notes that are stale, factually wrong, or no longer useful --
  check against the source project when a note makes a claim about code
  that still exists.
- Leave a note unchanged if it's still accurate and useful and doesn't
  belong in a merge.

Every original note file must be accounted for in exactly one of: unchanged,
one merged/edited entry's sources, or discard. When a merge needs a new
file (rather than reusing one source's filename), give it a short
snake_case name ending in .md, in the style of the existing note filenames
(e.g. feedback_topic.md). Do not modify any files -- report your plan only.
Return your plan as JSON matching the provided schema."""

INSTRUCTIONS_NO_SOURCE = """You are consolidating the persistent memory notes for a software project.
The current directory contains that project's Claude Code memory: MEMORY.md
(an index of notes) and the *.md files it links to. The project's own
source code is not available this time (its directory could not be
resolved), so judge each note on the note text alone.

Read MEMORY.md and every note file it links to. Then:
- Merge notes that are clearly redundant or that overlap enough that one
  higher-quality note serves better than several partial ones.
- Discard notes that are stale, internally contradictory, or no longer
  useful.
- Leave a note unchanged if it's still useful and doesn't belong in a merge.

Every original note file must be accounted for in exactly one of: unchanged,
one merged/edited entry's sources, or discard. When a merge needs a new
file (rather than reusing one source's filename), give it a short
snake_case name ending in .md, in the style of the existing note filenames
(e.g. feedback_topic.md). Do not modify any files -- report your plan only.
Return your plan as JSON matching the provided schema."""


def is_memory_dir(path):
    return os.path.isdir(path) and os.path.basename(os.path.normpath(path)) == "memory"


def error_result(message):
    """A stream-json-shaped final line, so the caller's normal per-line
    stream-json parser handles a validation failure the same way it would
    handle claude itself reporting is_error -- no separate error protocol
    needed on the QML side."""
    print(json.dumps({"type": "result", "is_error": True, "result": message}))


def build_argv(source_dir):
    have_source = source_dir != "" and os.path.isdir(source_dir)
    instructions = INSTRUCTIONS_WITH_SOURCE if have_source else INSTRUCTIONS_NO_SOURCE
    argv = [
        "claude", "-p",
        "--output-format", "stream-json",
        "--verbose",
        "--tools", "Read,Glob,Grep",
        "--permission-mode", "plan",
    ]
    if have_source:
        argv += ["--add-dir", source_dir]
    argv += [
        "--json-schema", json.dumps(SCHEMA),
        "--max-budget-usd", "1.00",
        instructions,
    ]
    return argv


def main():
    args = sys.argv[1:]
    dry_run = False
    if args and args[0] == "--dry-run":
        dry_run = True
        args = args[1:]

    if len(args) < 1:
        error_result("usage: consolidate-run.py [--dry-run] <memory_dir> [<source_dir>]")
        sys.exit(2)

    memory_dir = args[0]
    source_dir = args[1] if len(args) > 1 else ""

    if not is_memory_dir(memory_dir):
        error_result("not a memory directory: " + memory_dir)
        sys.exit(1)

    argv = build_argv(source_dir)

    if dry_run:
        print(json.dumps({"argv": argv}))
        return

    try:
        os.execvp("claude", argv)
    except OSError as e:
        error_result("could not run claude: " + str(e))
        sys.exit(1)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Build fixtures and verify `--dry-run` with a resolvable source dir**

```bash
T=/tmp/consolidate-run-test
rm -rf "$T"
mkdir -p "$T/memory" "$T/source"
echo "- [A](a.md) — hook" > "$T/memory/MEMORY.md"
echo content > "$T/memory/a.md"

cd /home/mtts/.config/omarchy/plugins/paulomtts.claude-memory
python3 consolidate-run.py --dry-run "$T/memory" "$T/source" | python3 -m json.tool
```
Expected: valid JSON with an `argv` array containing, in order, `"claude"`, `"-p"`, `"--output-format"`, `"stream-json"`, `"--verbose"`, `"--tools"`, `"Read,Glob,Grep"`, `"--permission-mode"`, `"plan"`, `"--add-dir"`, `"<T>/source"`, `"--json-schema"`, a JSON-schema string, `"--max-budget-usd"`, `"1.00"`, and finally the instructions string containing "An additional directory has been granted".

- [ ] **Step 3: Verify `--dry-run` with an unresolvable source dir**

```bash
python3 consolidate-run.py --dry-run "$T/memory" "$T/does-not-exist" | python3 -c "
import json, sys
argv = json.load(sys.stdin)['argv']
assert '--add-dir' not in argv, 'should not add --add-dir for a missing source dir'
assert 'source code is not available' in argv[-1]
print('ok: no --add-dir, no-source instructions used')
"
```

- [ ] **Step 4: Verify `--dry-run` with no source dir at all (empty string)**

```bash
python3 consolidate-run.py --dry-run "$T/memory" "" | python3 -c "
import json, sys
argv = json.load(sys.stdin)['argv']
assert '--add-dir' not in argv
print('ok')
"
```

- [ ] **Step 5: Verify the schema embedded in argv is itself valid JSON**

```bash
python3 consolidate-run.py --dry-run "$T/memory" "" | python3 -c "
import json, sys
argv = json.load(sys.stdin)['argv']
schema = json.loads(argv[argv.index('--json-schema') + 1])
assert schema['required'] == ['summary', 'unchanged', 'entries', 'discard']
print('ok: schema parses and has the expected top-level required fields')
"
```

- [ ] **Step 6: Verify rejection of a non-memory directory**

```bash
python3 consolidate-run.py --dry-run "$T" "" ; echo "exit: $?"
```
Expected: a `{"type": "result", "is_error": true, "result": "not a memory directory: ..."}` line and exit code 1.

- [ ] **Step 7: Verify the real exec path is reachable (without actually spending money) by pointing at a stand-in binary**

This checks that dropping `--dry-run` really does replace the process image via `execvp` with the right argv, using a throwaway shell script standing in for `claude` on `PATH`, instead of the real (paid) CLI.

```bash
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'EOF'
#!/bin/bash
echo "STUB CALLED WITH: $*"
EOF
chmod +x "$T/bin/claude"
PATH="$T/bin:$PATH" python3 consolidate-run.py "$T/memory" "$T/source"
```
Expected: one line starting `STUB CALLED WITH: -p --output-format stream-json --verbose --tools Read,Glob,Grep --permission-mode plan --add-dir /tmp/consolidate-run-test/source --json-schema {...} --max-budget-usd 1.00 You are consolidating...` — confirming `execvp` really did replace the process and passed the exact argv.

```bash
rm -rf "$T"
```

- [ ] **Step 8: Commit**

```bash
cd /home/mtts/.config/omarchy/plugins/paulomtts.claude-memory
git add consolidate-run.py
git commit -m "$(cat <<'EOF'
Add consolidate-run.py: build and exec the read-only claude invocation

Read-only by two independent mechanisms (--tools "Read,Glob,Grep" and
--permission-mode plan), --json-schema forces structured output, and
--add-dir is only added when the resolved source project directory
actually still exists on disk. --dry-run prints the argv instead of
exec'ing, so the command construction can be verified without spending
against the real (paid) claude CLI.
EOF
)"
```

---

## Task 3: Panel.qml — consolidate state, functions, and processes

**Files:**
- Modify: `Panel.qml`

**Interfaces:**
- Consumes: `consolidate-run.py` and `consolidate-apply.py` from Tasks 1–2 (exact argv shapes above); `root.pluginDir`, `root.selectedDir`, `root.selectedProjectLabel`, `root.indexEntries`, `root.focusForView()`, `root.resetSearch()` pattern already defined in the existing file (see `Panel.qml:1-390` as read during planning).
- Produces, for Task 4 to bind UI against: properties `consolidateState` (string: `"idle"|"confirming"|"running"|"review"|"applying"|"error"`), `consolidateProgress` (string), `consolidateElapsedText` (readonly string), `consolidatePlan` (object or `null`, shaped like the schema in Task 2), `consolidateError` (string), `consolidateApplyText` (string), `consolidateActive` (readonly bool = `viewMode === "index" && consolidateState !== "idle"`); functions `startConsolidate()`, `cancelConsolidateConfirm()`, `runConsolidate()`, `cancelConsolidate()`, `dismissConsolidateError()`, `performConsolidateApply()`, `titleForFile(file)`; item ids `consolidateProc`, `consolidateApplyProc`, `consolidateApplyField` (the last one is created in Task 4, referenced here only inside `focusForView()`).

This task adds no visible UI (the button that reaches `startConsolidate()` doesn't exist until Task 4), so nothing changes for a user opening the panel — verification is a clean reload plus code review.

- [ ] **Step 1: Add the new properties**

In `Panel.qml`, find this existing block (around line 47-55):

```qml
  // Manage mode: select projects (by dir) or memory entries (by file) for
  // deletion. Gated behind typing the literal word "delete" so a stray
  // Enter/click can't destroy anything by itself.
  property bool manageMode: false
  property var selectedKeys: ({})
  property bool confirmOpen: false
  property string confirmText: ""
  property string deleteError: ""
  property bool deleting: false
```

Insert immediately after it:

```qml

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

  readonly property bool consolidateActive: root.viewMode === "index" && root.consolidateState !== "idle"

  readonly property string consolidateElapsedText: {
    if (root.consolidateState !== "running" || root.consolidateStartMs === 0) return ""
    var secs = Math.max(0, Math.round((root.consolidateNowMs - root.consolidateStartMs) / 1000))
    return secs + "s elapsed"
  }
```

- [ ] **Step 2: Add the consolidate functions**

Find the existing `deleteCurrentItem()` function (around line 121-135) and insert the new functions immediately after its closing `}` (before `function toggleManageMode() {`):

```qml

  function titleForFile(file) {
    for (var i = 0; i < root.indexEntries.length; i++)
      if (root.indexEntries[i].file === file) return root.indexEntries[i].title
    return file
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
    return name ? name + "…" : ""
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
      root.focusForView()
    }
  }

  // Re-checks the same invariant consolidate-apply.py enforces before
  // writing anything: every currently-indexed file must appear in exactly
  // one of unchanged / some entry's sources / discard. Returns "" if the
  // plan is safe to show for review, or an error string.
  function validateConsolidatePlan(plan) {
    if (!plan || typeof plan !== "object") return "Claude's response wasn't a JSON object."
    var unchanged = Array.isArray(plan.unchanged) ? plan.unchanged : null
    var entries = Array.isArray(plan.entries) ? plan.entries : null
    var discard = Array.isArray(plan.discard) ? plan.discard : null
    if (!unchanged || !entries || !discard) return "Claude's response was missing unchanged/entries/discard."

    var accounted = {}
    var conflict = ""
    function account(name, bucket) {
      if (conflict !== "") return
      if (accounted[name]) { conflict = name + " is listed in both " + accounted[name] + " and " + bucket; return }
      accounted[name] = bucket
    }
    unchanged.forEach(function(name) { account(name, "unchanged") })
    entries.forEach(function(entry) {
      (entry.sources || []).forEach(function(source) { account(source, "entries[].sources") })
    })
    discard.forEach(function(item) { account(item.file, "discard") })
    if (conflict !== "") return conflict

    var current = root.indexEntries.map(function(e) { return e.file })
    var missing = current.filter(function(f) { return !accounted[f] })
    var extra = Object.keys(accounted).filter(function(f) { return current.indexOf(f) < 0 })
    if (missing.length > 0) return "Plan doesn't account for: " + missing.join(", ")
    if (extra.length > 0) return "Plan references files not in the current index: " + extra.join(", ")
    return ""
  }

  function cancelConsolidate() {
    root.consolidateState = "idle"
    root.consolidatePlan = null
    root.consolidateError = ""
    root.consolidateApplyText = ""
    root.focusForView()
  }

  function dismissConsolidateError() {
    root.consolidateState = "idle"
    root.consolidateError = ""
    root.focusForView()
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
```

- [ ] **Step 3: Extend `focusForView()` to route focus during the consolidate flow**

Find the existing function (around line 78-84):

```qml
  function focusForView() {
    Qt.callLater(function() {
      if (!root.opened) return
      if (root.viewMode === "entry") { if (keyCatcher) keyCatcher.forceActiveFocus() }
      else if (searchField) searchField.forceActiveFocus()
    })
  }
```

Replace it with:

```qml
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
```

- [ ] **Step 4: Add the two Process blocks**

Find the existing `deleteProc` block's closing (around line 345-374, ending `}` before `FileView { id: indexFile`). Insert the two new `Process` blocks immediately after `deleteProc`'s closing `}` and before `FileView { id: indexFile`:

```qml

  Process {
    id: consolidateProc
    stdout: SplitParser {
      onRead: function(line) { root.handleConsolidateLine(line) }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (root.consolidateState !== "running") return
      // A clean stream always ends with a "result" line that
      // handleConsolidateLine() already turned into "review" or "error" --
      // reaching here while still "running" means the process died
      // without ever emitting one (crash, killed, claude not on PATH).
      root.consolidateError = "Claude Code exited unexpectedly" + (exitCode !== 0 ? " (exit code " + exitCode + ")." : ".")
      root.consolidateState = "error"
    }
  }

  Timer {
    interval: 1000
    running: root.consolidateState === "running"
    repeat: true
    onTriggered: root.consolidateNowMs = Date.now()
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
```

- [ ] **Step 5: Reload and check for QML errors (passive, no interaction)**

```bash
omarchy-shell shell rescanPlugins
sleep 1
journalctl --user -n 40 --no-pager 2>/dev/null | grep -iE "error|warn" | grep -v -E "portal|ghostty"
```
Expected: no output (or only the two known-unrelated warnings). If anything mentions `paulomtts.claude-memory` or a QML syntax/type error, fix before continuing.

```bash
omarchy restart shell
sleep 3
journalctl --user -n 20 --no-pager 2>/dev/null | grep -iE "error|warn" | grep -v -E "portal|ghostty"
pgrep -a quickshell
```
Expected: clean (or only known-unrelated warnings), and `quickshell` still running (confirms the shell didn't crash on load).

- [ ] **Step 6: Code review checklist (no UI exists yet to click, so this is the real verification for this task)**

Re-read the four new functions plus `handleConsolidateLine`/`validateConsolidatePlan` and confirm:
- `runConsolidate()` sets `consolidateProc.workingDirectory` *and* `command` *before* `running = true` (both must be set before the transition, per Quickshell's `Process` semantics — a property changed after the process has already started only affects the *next* start).
- `performConsolidateApply()` sets `consolidateApplyProc.stdinEnabled = true` before `running = true` (required every time, not just the first) — verify this line is present.
- `validateConsolidatePlan()`'s `current`/`accounted` comparison matches `consolidate-apply.py`'s `validate_plan()` invariant logic (same three buckets, same "missing"/"extra" framing) — the two must never silently diverge, since the QML check gates the review UI and the Python check gates the actual write.
- `handleConsolidateLine()` never throws on unexpected/partial JSON — every `JSON.parse` is wrapped in `try/catch` with a graceful fallback (return, or transition to the `error` state with a message — never an uncaught exception that would kill the QML engine's event handling).

- [ ] **Step 7: Commit**

```bash
cd /home/mtts/.config/omarchy/plugins/paulomtts.claude-memory
git add Panel.qml
git commit -m "$(cat <<'EOF'
Add consolidate state machine, functions, and processes to Panel.qml

idle -> confirming -> running -> review -> applying -> idle/error. No UI
yet (the button that reaches startConsolidate() lands in the next
commit) -- this is the engine: streams consolidate-run.py's stream-json
output for live progress, re-validates the plan's file-accounting
invariant before ever showing it, and pipes the reviewed plan to
consolidate-apply.py over stdin (closing the write channel afterward to
signal EOF).
EOF
)"
```

---

## Task 4: Panel.qml — consolidate UI

**Files:**
- Modify: `Panel.qml`

**Interfaces:**
- Consumes: everything from Task 3 (`consolidateState`, `consolidateActive`, `consolidateProgress`, `consolidateElapsedText`, `consolidatePlan`, `consolidateError`, `consolidateApplyText`, `titleForFile()`, `startConsolidate()`, `cancelConsolidateConfirm()`, `runConsolidate()`, `cancelConsolidate()`, `dismissConsolidateError()`, `performConsolidateApply()`).
- Produces: the visible feature. Item id `consolidateApplyField` (already referenced by Task 3's `focusForView()`).

- [ ] **Step 1: Add the header button**

Find the existing "Manage" `Button` in the header `RowLayout` (around line 479-489):

```qml
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
```

Replace it with (adds the new button before it, and hides both while a consolidate flow owns this view):

```qml
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
```

- [ ] **Step 2: Hide Back and search while a consolidate flow is active**

Find the "‹ Back" `Text` (around line 458-465):

```qml
            Text {
              visible: root.viewMode !== "projects"
              text: "‹ Back"
```

Change `visible` to:

```qml
              visible: root.viewMode !== "projects" && !root.consolidateActive
```

Find the `searchField` `TextField` (around line 493-495):

```qml
          TextField {
            id: searchField
            visible: root.viewMode !== "entry"
```

Change `visible` to:

```qml
            visible: root.viewMode !== "entry" && !root.consolidateActive
```

- [ ] **Step 3: Hide the normal entries list while a consolidate flow is active**

Find the "Memory index" `Column` (around line 698-701):

```qml
          // ---------- Memory index ----------
          Column {
            visible: root.viewMode === "index"
            width: parent.width
            spacing: Style.space(6)
```

Change `visible` to:

```qml
            visible: root.viewMode === "index" && !root.consolidateActive
```

- [ ] **Step 4: Add the five new consolidate-state Column sections**

Insert this whole block immediately after the "Memory index" `Column`'s closing `}` (i.e. right after the block that ends with the `indexRepeater` `Repeater`, before the "---------- Single entry ----------" comment):

```qml

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
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  text: modelData.title
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  wrapMode: Text.WordWrap
                }
                Text {
                  width: parent.width
                  text: "supersedes: " + modelData.sources.join(", ")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
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
```

- [ ] **Step 5: Update the keyCatcher's Escape handling to be consolidate-aware**

Find the existing `onCloseRequested` in `PanelKeyCatcher` (around line 434):

```qml
      onCloseRequested: root.goBack()
```

Replace it with:

```qml
      onCloseRequested: {
        if (root.viewMode === "index" && root.consolidateState === "confirming") root.cancelConsolidateConfirm()
        else if (root.viewMode === "index" && root.consolidateState === "review") root.cancelConsolidate()
        else if (root.viewMode === "index" && root.consolidateState === "error") root.dismissConsolidateError()
        else if (root.consolidateActive) { /* running/applying: nothing to cancel onto yet */ }
        else root.goBack()
      }
```

(In practice `"review"` is normally handled by `consolidateApplyField`'s own `Keys.onPressed` since that field has focus during review — this is the fallback for `"confirming"`/`"error"`, where `keyCatcher` itself holds focus per Task 3's `focusForView()`.)

- [ ] **Step 6: Reload and check for QML errors (passive)**

```bash
omarchy-shell shell rescanPlugins
sleep 1
journalctl --user -n 60 --no-pager 2>/dev/null | grep -iE "error|warn" | grep -v -E "portal|ghostty"
omarchy restart shell
sleep 3
journalctl --user -n 20 --no-pager 2>/dev/null | grep -iE "error|warn" | grep -v -E "portal|ghostty"
pgrep -a quickshell
```
Expected: clean (or only known-unrelated warnings) both times, and `quickshell` still running after the restart.

- [ ] **Step 7: Code review checklist**

Re-read the full new block plus the three edited `visible` bindings and confirm:
- Every one of the five new `Column`s' `visible` starts with `root.viewMode === "index" &&` — none of them can show while looking at the projects list or an entry.
- The five `consolidateState` values in those five `visible` bindings are mutually exclusive and exhaustive (`confirming`, `running`, `review`, `applying`, `error` — matches the `property string consolidateState` comment from Task 3 exactly).
- `consolidateActive` (Task 3) is `true` for every one of those five states, so the Back/search/Manage/entries-list hides for all of them, not just some.
- The "PROPOSED"/"DISCARDED" Repeaters guard every `root.consolidatePlan.X` access with `root.consolidatePlan ?` — `consolidatePlan` is `null` outside the `review` state, and even briefly during the render pass a `null`-check-free binding would throw.

- [ ] **Step 8: Commit**

```bash
cd /home/mtts/.config/omarchy/plugins/paulomtts.claude-memory
git add Panel.qml
git commit -m "$(cat <<'EOF'
Add consolidate UI: header button, confirm/running/review/applying/error

The "Consolidate" button only shows while viewing a project's memory
index. Starting a run hides Back/search/Manage/the entries list for that
view until Cancel, Apply, or Dismiss returns to idle -- reusing the same
type-to-confirm pattern as manage-mode delete for Apply, since it does
overwrite/delete files.
EOF
)"
```

---

## Task 5: README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing (documentation only).
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Add a Consolidate bullet to the Features list**

Find this line in `README.md`:

```markdown
- **Manage mode** — select projects or memory entries and delete them,
```

Insert a new bullet immediately before it:

```markdown
- **Consolidate** — inside a project's memory index, a "✨ Consolidate"
  button asks Claude Code to review every note (plus, when the project's
  source directory can still be resolved, the actual source project — so
  it can check a note's claims against the current code) and propose a
  merged/pruned set. Nothing is written until you review the full
  proposal — new/merged content, discarded notes with reasons, and what's
  left unchanged — and type `apply` to confirm. A backup of the memory
  directory is kept before applying. This runs `claude -p` with read-only
  tool access (`Read`/`Glob`/`Grep` only, `--permission-mode plan`, and a
  `--json-schema`-enforced response) and counts against your normal
  Claude subscription usage.
```

- [ ] **Step 2: Add a Requirements note about the `claude` CLI**

Find the existing Requirements section:

```markdown
## Requirements

`python3` on `PATH` (used for filesystem-aware slug decoding and for
manage-mode deletion).
```

Replace with:

```markdown
## Requirements

`python3` on `PATH` (used for filesystem-aware slug decoding and for
manage-mode deletion). The `claude` CLI on `PATH`, logged in, is required
only for the Consolidate feature — everything else works without it.
```

- [ ] **Step 3: Commit**

```bash
cd /home/mtts/.config/omarchy/plugins/paulomtts.claude-memory
git add README.md
git commit -m "Document the consolidate-memory feature in the README"
```

---

## Task 6: Ship

**Files:** none (verification and push only).

**Interfaces:** none.

- [ ] **Step 1: Full clean restart and log check**

```bash
omarchy restart shell
sleep 3
journalctl --user -n 40 --no-pager 2>/dev/null | grep -iE "error|warn" | grep -v -E "portal|ghostty"
pgrep -a quickshell
```
Expected: clean (or only known-unrelated warnings), `quickshell` running.

- [ ] **Step 2: Confirm the working tree is clean and every commit landed**

```bash
cd /home/mtts/.config/omarchy/plugins/paulomtts.claude-memory
git status --short
git log --oneline -8
```
Expected: no uncommitted changes; the last several commits are the ones from Tasks 1–5 in order.

- [ ] **Step 3: Push**

```bash
git push
```

- [ ] **Step 4: Confirm on GitHub**

```bash
gh repo view paulomtts/omarchy-claude-memory --json url,pushedAt
```
