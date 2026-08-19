#!/usr/bin/env python3
"""Apply a reviewed consolidation plan to one project's memory directory.

Invoked as: consolidate-apply.py <memory_dir>, with the plan JSON piped via
stdin. consolidate_plan.py describes the plan's shape and owns every check
made against it.

Mirrors delete-memory.py's safety posture, plus checks specific to a
model-generated plan: the memory dir and every filename are re-validated
against the real filesystem (never trust the plan blindly), and the
file-accounting invariant -- every original file in exactly one of
unchanged / some entry's sources / discard -- is re-checked against the
*current* index before anything is written.

Before touching anything, the whole memory dir is copied to
~/.cache/omarchy-claude-memory/backups/<slug>-<timestamp>/ as an undo
safety net, since there is no in-app undo.

One result line per file operation goes to stdout, same convention as
delete-memory.py: "ok\\t<file>" or "error\\t<file>\\t<message>".
"""
import json
import os
import shutil
import sys
import time

from claude_memory import (MEMORY_INDEX, drop_index_lines, index_targets, is_memory_dir,
                           read_index, write_index)
from consolidate_plan import (entry_document, files_to_delete, index_line, sanitize_plan,
                              stale_index_files, validate_plan)

BACKUP_ROOT = "~/.cache/omarchy-claude-memory/backups"


def ok(item):
    print("ok\t" + item)


def failed(item, message):
    print("error\t" + item + "\t" + message)


def backup(memory_dir):
    slug = os.path.basename(os.path.dirname(os.path.normpath(memory_dir)))
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime())
    dest_root = os.path.expanduser(BACKUP_ROOT)
    dest = os.path.join(dest_root, slug + "-" + stamp)
    os.makedirs(dest_root, exist_ok=True)
    shutil.copytree(memory_dir, dest)
    return dest


def write_entry(memory_dir, entry):
    with open(os.path.join(memory_dir, entry["file"]), "w", encoding="utf-8") as f:
        f.write(entry_document(entry))


def rewrite_index(memory_dir, plan):
    """Drop the lines for everything deleted or rewritten, then append a
    fresh line per entry. Prose and untouched links keep their position; the
    entries land at the end, after any trailing blank lines are trimmed."""
    index = read_index(memory_dir)
    kept = drop_index_lines(index, stale_index_files(plan, index_targets(index))).split("\n")
    while kept and kept[-1].strip() == "":
        kept.pop()
    kept += [index_line(entry) for entry in plan["entries"]]
    write_index(memory_dir, "\n".join(kept) + "\n")


def apply_plan(memory_dir, plan):
    for entry in plan["entries"]:
        try:
            write_entry(memory_dir, entry)
            ok(entry["file"])
        except OSError as e:
            failed(entry["file"], str(e))

    for name in files_to_delete(plan):
        target = os.path.join(memory_dir, name)
        try:
            if os.path.isfile(target):
                os.remove(target)
            ok(name)
        except OSError as e:
            failed(name, str(e))

    try:
        rewrite_index(memory_dir, plan)
        ok(MEMORY_INDEX)
    except OSError as e:
        failed(MEMORY_INDEX, str(e))


def main():
    if len(sys.argv) < 2:
        failed("", "usage: consolidate-apply.py <memory_dir> (plan JSON on stdin)")
        sys.exit(2)
    memory_dir = sys.argv[1]

    if not is_memory_dir(memory_dir):
        failed(memory_dir, "not a memory directory")
        sys.exit(1)

    try:
        plan = sanitize_plan(json.loads(sys.stdin.read()))
    except ValueError as e:
        failed("", "invalid plan JSON: " + str(e))
        sys.exit(1)

    error = validate_plan(plan, index_targets(read_index(memory_dir)))
    if error:
        failed("", error)
        sys.exit(1)

    try:
        backup(memory_dir)
    except OSError as e:
        failed("", "could not back up memory dir: " + str(e))
        sys.exit(1)

    apply_plan(memory_dir, plan)


if __name__ == "__main__":
    main()
