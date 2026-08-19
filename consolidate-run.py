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

from claude_memory import is_memory_dir

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

Prefer several focused files over one large file -- only merge notes that
are genuinely about the same narrow topic. There's no requirement to
collapse everything down to a single file; keep unrelated topics as
separate entries even when you're touching many source files.

Every original note file must be accounted for in exactly one of: unchanged,
one merged/edited entry's sources, or discard. MEMORY.md itself is the
index, not one of the notes -- do not list it in unchanged, sources, or
discard. When a merge needs a new file (rather than reusing one source's
filename), give it a short snake_case name ending in .md, in the style of
the existing note filenames (e.g. feedback_topic.md). Do not modify any
files -- report your plan only.
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

Prefer several focused files over one large file -- only merge notes that
are genuinely about the same narrow topic. There's no requirement to
collapse everything down to a single file; keep unrelated topics as
separate entries even when you're touching many source files.

Every original note file must be accounted for in exactly one of: unchanged,
one merged/edited entry's sources, or discard. MEMORY.md itself is the
index, not one of the notes -- do not list it in unchanged, sources, or
discard. When a merge needs a new file (rather than reusing one source's
filename), give it a short snake_case name ending in .md, in the style of
the existing note filenames (e.g. feedback_topic.md). Do not modify any
files -- report your plan only.
Return your plan as JSON matching the provided schema."""


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
        "--max-budget-usd", "3.00",
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
