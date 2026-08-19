#!/usr/bin/env python3
"""Read raw content of specific memory note files, for the consolidate
review screen's before/after comparison.

Usage: read-entries.py <memory_dir> <file1> [<file2> ...]

Outputs a single JSON object {filename: content, ...} to stdout. A file
that fails validation, doesn't exist, or can't be read is simply omitted
from the result rather than erroring the whole batch -- one missing file
shouldn't block seeing the rest. The caller (Panel.qml) treats a missing
key as "no preview available" for that file.
"""
import json
import os
import sys

from claude_memory import is_memory_dir, is_safe_filename


def read_entries(memory_dir, filenames):
    if not is_memory_dir(memory_dir):
        return {}
    contents = {}
    for name in filenames:
        if not is_safe_filename(name):
            continue
        path = os.path.join(memory_dir, name)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as f:
                contents[name] = f.read()
        except OSError:
            pass
    return contents


def main():
    if len(sys.argv) < 2:
        print(json.dumps({}))
        return
    print(json.dumps(read_entries(sys.argv[1], sys.argv[2:])))


if __name__ == "__main__":
    main()
