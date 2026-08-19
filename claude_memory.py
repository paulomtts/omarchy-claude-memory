"""Shared vocabulary for Claude Code's on-disk memory layout.

Every script here reads or writes the same two things: a project's "memory"
directory, and the MEMORY.md index inside it. Those rules used to live
inline in each script, which is how one bug -- a "./"-prefixed index link,
a no-op for opening the file but fatal to every exact-string filename
comparison -- managed to need fixing in three files independently. They
live here once instead.

Nothing in this module touches global state or prints; the scripts that
import it own all the I/O and all the result reporting.
"""
import os
import re

MEMORY_INDEX = "MEMORY.md"

# "- [Title](file.md) — optional hook text". The only line shape MEMORY.md
# uses to link a note; every other line in the file is prose and is left
# strictly alone by the rewriters below.
INDEX_LINE_RE = re.compile(r"^-\s*\[([^\]]+)\]\(([^)]+)\)\s*(.*)$")


def is_memory_dir(path):
    """A memory dir is the only thing these scripts may delete inside of, so
    the check is deliberately literal: it exists, and it's named "memory"."""
    return os.path.isdir(path) and os.path.basename(os.path.normpath(path)) == "memory"


def is_safe_filename(name):
    """A note filename must be a plain basename, so joining it onto a memory
    dir can't reach outside that dir. Non-strings (a malformed plan, argv is
    always str) are unsafe rather than a TypeError."""
    return isinstance(name, str) and name != "" and "/" not in name and name not in (".", "..")


def normalize_href(href):
    """A leading "./" resolves identically on disk but breaks comparison by
    string equality -- and filenames are compared that way everywhere here,
    against argv and against consolidation plans, which name files the bare
    way Read/Glob report them. Every href enters the code through here."""
    href = href.strip()
    return href[2:] if href.startswith("./") else href


def index_link(line):
    """(title, file, hook) for a MEMORY.md note link, or None for any other
    line."""
    m = INDEX_LINE_RE.match(line)
    if not m:
        return None
    return m.group(1).strip(), normalize_href(m.group(2)), m.group(3).strip()


def index_targets(text):
    """Every note filename the given MEMORY.md content links to."""
    return set(link[1] for link in map(index_link, text.split("\n")) if link)


def drop_index_lines(text, filenames):
    """MEMORY.md content with the link lines pointing at `filenames` removed
    and everything else preserved verbatim, including trailing blank lines --
    callers decide how the file should end."""
    kept = []
    for line in text.split("\n"):
        link = index_link(line)
        if link and link[1] in filenames:
            continue
        kept.append(line)
    return "\n".join(kept)


def read_index(memory_dir):
    """MEMORY.md's content, or "" if this project has no index yet."""
    path = os.path.join(memory_dir, MEMORY_INDEX)
    if not os.path.isfile(path):
        return ""
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_index(memory_dir, text):
    with open(os.path.join(memory_dir, MEMORY_INDEX), "w", encoding="utf-8") as f:
        f.write(text)


def decode_slug(slug, isdir=os.path.isdir):
    """Reconstruct a project's real path from the slug Claude Code names its
    project directory with.

    The encoding replaces every "/" with "-", which is lossy: a literal
    hyphen in a directory name is indistinguishable from a separator once
    encoded, so a naive "every dash is a slash" decode turns
    ~/Code/refactor-nori into ~/Code/refactor/nori. Instead, walk the
    dash-separated tokens and at each level grow a candidate component only
    as far as it takes to match a real directory -- the filesystem is the
    source of truth, not the encoding.

    A project since renamed, moved, or deleted can't be verified past
    whatever prefix still exists (say ~/Code/chat-go where ~/Code is still
    there but chat-go isn't). Rather than discard the decode and show the
    raw fully-hyphenated slug, keep the verified prefix and fall back to a
    plain per-token split for the unverifiable tail -- still a guess, but
    the same guess the encoding makes on average, and far more readable.

    `isdir` is injected so the greedy matcher can be exercised against a
    known directory set instead of whatever happens to be on this machine.
    """
    if not slug.startswith("-"):
        return None
    tokens = slug[1:].split("-")
    path = "/"
    i = 0
    while i < len(tokens):
        component, consumed = _match_component(path, tokens, i, isdir)
        if component is None:
            return os.path.join(path, *tokens[i:])
        path = os.path.join(path, component)
        i = consumed
    return path


def _match_component(base, tokens, start, isdir):
    """The shortest join of tokens[start:] that names a real directory under
    `base`, as (component, index after it), or (None, start) if no join
    does."""
    candidate = tokens[start]
    end = start
    while not isdir(os.path.join(base, candidate)):
        if end + 1 >= len(tokens):
            return None, start
        end += 1
        candidate = candidate + "-" + tokens[end]
    return candidate, end + 1
