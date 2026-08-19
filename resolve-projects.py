#!/usr/bin/env python3
"""List Claude Code project memory dirs and resolve each project's real path.

Claude Code encodes a project's cwd by replacing every "/" with "-"
(e.g. /home/mtts/Code/refactor-nori -> -home-mtts-Code-refactor-nori). That
encoding is lossy: a literal hyphen in a directory name is indistinguishable
from a path separator once encoded. A naive "replace every dash with slash"
decode gets directories like "refactor-nori" wrong (splits it into
"refactor/nori"). Instead, walk the slug's dash-separated tokens and, at each
level, greedily grow a candidate component only as long as needed to match a
real directory on disk -- the filesystem is the source of truth, not the
encoding.

A project whose directory was since renamed, moved, or deleted can't be
verified past whatever prefix still exists (e.g. a project last seen at
~/Code/chat-go where ~/Code exists but chat-go no longer does). Rather than
discard the whole decode and show the raw, fully-hyphenated slug, keep the
verified prefix and fall back to a plain per-token split (one dash = one
slash) for the part that can no longer be checked -- still a guess, but the
same guess the original encoding makes on average, and far more readable
than the untouched slug.
"""
import os
import sys


def decode_slug(slug):
    if not slug.startswith("-"):
        return None
    parts = slug[1:].split("-")
    path = "/"
    i = 0
    n = len(parts)
    while i < n:
        j = i
        candidate = parts[i]
        matched = os.path.isdir(os.path.join(path, candidate))
        while not matched and j + 1 < n:
            j += 1
            candidate = candidate + "-" + parts[j]
            matched = os.path.isdir(os.path.join(path, candidate))
        if not matched:
            # Nothing from here to the end matches a real directory (likely
            # renamed/moved/deleted) -- stop verifying and split whatever
            # remains one token per path segment instead of merging it into
            # one big guessed component.
            return os.path.join(path, *parts[i:])
        path = os.path.join(path, candidate)
        i = j + 1
    return path


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] != "" else os.path.expanduser("~/.claude/projects")
    if not os.path.isdir(root):
        return
    for slug in sorted(os.listdir(root)):
        memory_dir = os.path.join(root, slug, "memory")
        if not os.path.isfile(os.path.join(memory_dir, "MEMORY.md")):
            continue
        resolved = decode_slug(slug)
        label = resolved if resolved else slug
        print(memory_dir + "\t" + label)


if __name__ == "__main__":
    main()
