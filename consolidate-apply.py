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


def normalize_href(href):
    """A leading "./" is a no-op for actually opening the file, but it
    breaks every comparison done by exact string equality -- notably a
    consolidation plan, which references files by the bare name Read/Glob
    report, never "./name". Every index-line href gets normalized through
    here so the rest of this script (and Panel.qml's own parseIndex())
    agree on one form."""
    href = href.strip()
    return href[2:] if href.startswith("./") else href


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
                files.add(normalize_href(m.group(2)))
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

    def is_clean_str(value):
        return isinstance(value, str) and "\n" not in value

    for entry in entries:
        for field in ("title", "description", "type"):
            if not is_clean_str(entry.get(field)):
                return "entry missing or invalid field: " + field
        if not isinstance(entry.get("body"), str):
            return "entry missing or invalid field: body"
        if not isinstance(entry.get("sources"), list):
            return "entry missing or invalid field: sources"
    for item in discard:
        if not is_clean_str(item.get("reason")):
            return "discard item missing or invalid field: reason"

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
    current = existing_entry_files(memory_dir)
    target_files = set(entry["file"] for entry in plan["entries"] if entry["file"] in current)
    drop = superseded | discarded | target_files

    lines = []
    if os.path.isfile(index_path):
        with open(index_path, "r", encoding="utf-8") as f:
            lines = f.read().split("\n")

    kept = []
    for line in lines:
        m = INDEX_LINE_RE.match(line)
        if m and normalize_href(m.group(2)) in drop:
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
