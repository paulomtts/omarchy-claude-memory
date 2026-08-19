#!/usr/bin/env python3
"""List Claude Code project memory dirs, each with its project's real path.

One tab-separated line per project that actually has a MEMORY.md:

    <memory_dir>\t<label>\t<verified source dir, or "">

`label` is decode_slug()'s best-effort guess, good enough to show the user
but not to trust -- the slug encoding is lossy, so a guess can land on a
real but wrong directory. `verified source dir` is read from a session
transcript's own cwd field by verified_source_dir() and is empty when no
transcript confirms it; that third field, never the label, is what the
consolidate feature may pass to Claude as a directory to read.
"""
import os
import sys

from claude_memory import MEMORY_INDEX, decode_slug, verified_source_dir

DEFAULT_ROOT = "~/.claude/projects"


def projects(root):
    for slug in sorted(os.listdir(root)):
        project_dir = os.path.join(root, slug)
        memory_dir = os.path.join(project_dir, "memory")
        if os.path.isfile(os.path.join(memory_dir, MEMORY_INDEX)):
            yield memory_dir, decode_slug(slug) or slug, verified_source_dir(project_dir)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] != "" else os.path.expanduser(DEFAULT_ROOT)
    if not os.path.isdir(root):
        return
    for memory_dir, label, source_dir in projects(root):
        print(memory_dir + "\t" + label + "\t" + source_dir)


if __name__ == "__main__":
    main()
