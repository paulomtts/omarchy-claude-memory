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


def is_memory_dir(path):
    return os.path.isdir(path) and os.path.basename(os.path.normpath(path)) == "memory"


def is_safe_filename(name):
    return name != "" and "/" not in name and name not in (".", "..")


def main():
    if len(sys.argv) < 2:
        print(json.dumps({}))
        return
    memory_dir = sys.argv[1]
    filenames = sys.argv[2:]

    result = {}
    if is_memory_dir(memory_dir):
        for name in filenames:
            if not is_safe_filename(name):
                continue
            path = os.path.join(memory_dir, name)
            if os.path.isfile(path):
                try:
                    with open(path, "r", encoding="utf-8") as f:
                        result[name] = f.read()
                except OSError:
                    pass

    print(json.dumps(result))


if __name__ == "__main__":
    main()
