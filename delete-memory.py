#!/usr/bin/env python3
"""Delete Claude Code memory data on behalf of the panel's manage mode.

Two modes, always operating on a real "memory" directory (never a project
directory itself, and never anything outside one):

  project <memory_dir> [<memory_dir> ...]
      rmtree() each memory dir wholesale (MEMORY.md + every linked note),
      leaving the rest of that project's Claude Code data untouched.

  entries <memory_dir> <filename> [<filename> ...]
      Delete specific linked note files inside one memory dir, then rewrite
      that dir's MEMORY.md to drop the index lines pointing at whichever of
      them were actually deleted -- otherwise the index would keep dead
      links to notes that no longer exist.

One result line per item goes to stdout as "ok\\t<item>" or
"error\\t<item>\\t<message>", so the caller can report partial failures
instead of an opaque nonzero exit.
"""
import os
import shutil
import sys

from claude_memory import drop_index_lines, is_memory_dir, is_safe_filename, read_index, write_index


def ok(item):
    print("ok\t" + item)


def failed(item, message):
    print("error\t" + item + "\t" + message)


def delete_projects(memory_dirs):
    for path in memory_dirs:
        if not is_memory_dir(path):
            failed(path, "not a memory directory")
            continue
        try:
            shutil.rmtree(path)
            ok(path)
        except OSError as e:
            failed(path, str(e))


def delete_entries(memory_dir, filenames):
    if not is_memory_dir(memory_dir):
        for name in filenames:
            failed(name, "not a memory directory: " + memory_dir)
        return

    removed = set()
    for name in filenames:
        error = delete_entry(memory_dir, name)
        if error:
            failed(name, error)
        else:
            removed.add(name)
            ok(name)

    if removed:
        prune_index(memory_dir, removed)


def delete_entry(memory_dir, name):
    """Removes one note file. Returns an error message, or None on success."""
    if not is_safe_filename(name):
        return "invalid filename"
    target = os.path.join(memory_dir, name)
    # Belt and braces: is_safe_filename() already rules out anything that
    # could escape, but this is the last check before an unlink.
    if os.path.dirname(os.path.abspath(target)) != os.path.abspath(memory_dir):
        return "invalid filename"
    if not os.path.isfile(target):
        return "not found"
    try:
        os.remove(target)
    except OSError as e:
        return str(e)
    return None


def prune_index(memory_dir, removed):
    """Drop the index lines pointing at notes that are now gone. A project
    with no MEMORY.md has nothing to prune."""
    index = read_index(memory_dir)
    if index == "":
        return
    write_index(memory_dir, drop_index_lines(index, removed))


def main():
    if len(sys.argv) < 3:
        failed("", "usage: delete-memory.py project|entries ...")
        sys.exit(2)
    mode = sys.argv[1]
    if mode == "project":
        delete_projects(sys.argv[2:])
    elif mode == "entries":
        delete_entries(sys.argv[2], sys.argv[3:])
    else:
        failed("", "unknown mode: " + mode)
        sys.exit(2)


if __name__ == "__main__":
    main()
