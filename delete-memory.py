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

Every path is validated before anything is removed: it must exist, the
memory dir's basename must literally be "memory", and an "entries" filename
must be a plain basename (no "/", no "..") so it can't escape the directory
it's being deleted from. One result line per item goes to stdout as
"ok\\t<item>" or "error\\t<item>\\t<message>", so the caller can report
partial failures instead of an opaque nonzero exit.
"""
import os
import re
import shutil
import sys

INDEX_LINE_RE = re.compile(r"^-\s*\[([^\]]+)\]\(([^)]+)\)\s*(.*)$")


def is_memory_dir(path):
    return os.path.isdir(path) and os.path.basename(os.path.normpath(path)) == "memory"


def delete_projects(memory_dirs):
    for path in memory_dirs:
        if not is_memory_dir(path):
            print("error\t" + path + "\tnot a memory directory")
            continue
        try:
            shutil.rmtree(path)
            print("ok\t" + path)
        except OSError as e:
            print("error\t" + path + "\t" + str(e))


def delete_entries(memory_dir, filenames):
    if not is_memory_dir(memory_dir):
        for name in filenames:
            print("error\t" + name + "\tnot a memory directory: " + memory_dir)
        return

    removed = set()
    for name in filenames:
        if name == "" or "/" in name or name in (".", ".."):
            print("error\t" + name + "\tinvalid filename")
            continue
        target = os.path.join(memory_dir, name)
        if os.path.dirname(os.path.abspath(target)) != os.path.abspath(memory_dir):
            print("error\t" + name + "\tinvalid filename")
            continue
        if not os.path.isfile(target):
            print("error\t" + name + "\tnot found")
            continue
        try:
            os.remove(target)
            removed.add(name)
            print("ok\t" + name)
        except OSError as e:
            print("error\t" + name + "\t" + str(e))

    if not removed:
        return

    index_path = os.path.join(memory_dir, "MEMORY.md")
    if not os.path.isfile(index_path):
        return
    with open(index_path, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")
    kept = []
    for line in lines:
        m = INDEX_LINE_RE.match(line)
        if m and m.group(2).strip() in removed:
            continue
        kept.append(line)
    with open(index_path, "w", encoding="utf-8") as f:
        f.write("\n".join(kept))


def main():
    if len(sys.argv) < 3:
        print("error\t\tusage: delete-memory.py project|entries ...")
        sys.exit(2)
    mode = sys.argv[1]
    if mode == "project":
        delete_projects(sys.argv[2:])
    elif mode == "entries":
        delete_entries(sys.argv[2], sys.argv[3:])
    else:
        print("error\t\tunknown mode: " + mode)
        sys.exit(2)


if __name__ == "__main__":
    main()
