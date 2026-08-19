#!/usr/bin/env python3
"""List Claude Code project memory dirs, each with its project's real path.

One tab-separated line per project that actually has a MEMORY.md:

    <memory_dir>\t<resolved project path>

The path is reconstructed from the directory's slug by decode_slug(); see
claude_memory.py for why that isn't a plain dash-to-slash replace. A slug
that can't be decoded at all is printed as-is, so the project is still
listed rather than silently dropped.
"""
import os
import sys

from claude_memory import MEMORY_INDEX, decode_slug

DEFAULT_ROOT = "~/.claude/projects"


def projects(root):
    for slug in sorted(os.listdir(root)):
        memory_dir = os.path.join(root, slug, "memory")
        if os.path.isfile(os.path.join(memory_dir, MEMORY_INDEX)):
            yield memory_dir, decode_slug(slug) or slug


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] != "" else os.path.expanduser(DEFAULT_ROOT)
    if not os.path.isdir(root):
        return
    for memory_dir, label in projects(root):
        print(memory_dir + "\t" + label)


if __name__ == "__main__":
    main()
