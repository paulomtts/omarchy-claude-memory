"""Reason about a consolidation plan without touching the filesystem.

A plan is model-generated JSON:

  {"unchanged": ["file.md", ...],
   "entries": [{"file", "title", "description", "type", "body", "sources"}],
   "discard": [{"file", "reason"}]}

validate_plan() is the last gate before anything is written or deleted, so
it re-derives every invariant from the plan and the *current* index rather
than trusting the model's own bookkeeping. It takes the index contents as
an argument instead of reading MEMORY.md itself, which is what makes the
decision matrix in tests/test_plan_validation.py possible.

logic.js runs the same checks in the same order, so the panel can reject a
bad plan before offering it for review. Change one, change the other.
"""
from claude_memory import MEMORY_INDEX, is_safe_filename

_REQUIRED_TEXT_FIELDS = ("title", "description", "type")


def sanitize_plan(plan):
    """MEMORY.md is the index, not one of the notes it links to, but the
    model lists it in unchanged/sources/discard anyway often enough to
    matter. The mention is harmless noise -- strip it wherever it appears
    rather than let it either block an otherwise-complete plan (accounted
    for but absent from the index) or, far worse, sit in some entry's
    sources, where apply would delete the index as "superseded"."""
    if not isinstance(plan, dict):
        return plan
    if isinstance(plan.get("unchanged"), list):
        plan["unchanged"] = [f for f in plan["unchanged"] if f != MEMORY_INDEX]
    if isinstance(plan.get("entries"), list):
        for entry in plan["entries"]:
            if isinstance(entry, dict) and isinstance(entry.get("sources"), list):
                entry["sources"] = [s for s in entry["sources"] if s != MEMORY_INDEX]
    if isinstance(plan.get("discard"), list):
        plan["discard"] = [item for item in plan["discard"]
                           if not (isinstance(item, dict) and item.get("file") == MEMORY_INDEX)]
    return plan


def validate_plan(plan, current_files):
    """Returns an error string, or None if the plan is safe to apply against
    a memory dir whose index currently links to `current_files`."""
    shape_error = _check_shape(plan)
    if shape_error:
        return shape_error
    for check in (_check_filenames, _check_fields, _check_unique_targets):
        error = check(plan)
        if error:
            return error
    return _check_accounting(plan, set(current_files))


def _check_shape(plan):
    if not isinstance(plan, dict):
        return "plan is not a JSON object"
    if not all(isinstance(plan.get(key, []), list) for key in ("unchanged", "entries", "discard")):
        return "plan has the wrong shape"
    return None


def _check_filenames(plan):
    """Nothing in a plan may name anything but a plain file in the memory
    dir -- checked before any other field, so a traversal attempt is
    rejected even if the rest of the entry is garbage.

    An entry's own file is checked against MEMORY_INDEX too: sanitize_plan()
    strips the index out of unchanged/sources/discard, where it's just
    noise, but an entry writing *to* MEMORY.md is different -- that's a
    plan trying to overwrite the index itself with note content, which
    apply_plan()'s write-then-rewrite-index order would silently turn into
    losing that entry's content instead of the index (rewrite_index() runs
    last and clobbers it back). Reject it outright rather than guess."""
    for name in _unchanged(plan):
        if not is_safe_filename(name):
            return "unsafe filename in unchanged: " + str(name)
    for entry in _entries(plan):
        target = _field(entry, "file")
        if not is_safe_filename(target):
            return "unsafe filename in entries: " + str(target)
        if target == MEMORY_INDEX:
            return "entry targets the index file itself: " + MEMORY_INDEX
        for source in _sources(entry):
            if not is_safe_filename(source):
                return "unsafe source filename: " + str(source)
    for item in _discard(plan):
        if not is_safe_filename(_field(item, "file")):
            return "unsafe filename in discard: " + str(_field(item, "file"))
    return None


def _check_fields(plan):
    """Every field write_entry() and the index rewriter interpolate has to
    be a string, and the single-line ones can't smuggle a newline into a
    YAML frontmatter key or an index line."""
    for entry in _entries(plan):
        for field in _REQUIRED_TEXT_FIELDS:
            if not _is_single_line_str(_field(entry, field)):
                return "entry missing or invalid field: " + field
        if not isinstance(_field(entry, "body"), str):
            return "entry missing or invalid field: body"
        if not isinstance(_field(entry, "sources"), list):
            return "entry missing or invalid field: sources"
    for item in _discard(plan):
        if not _is_single_line_str(_field(item, "reason")):
            return "discard item missing or invalid field: reason"
    return None


def _check_unique_targets(plan):
    targets = [_field(entry, "file") for entry in _entries(plan)]
    if len(targets) != len(set(targets)):
        return "two entries target the same file"
    return None


def _check_accounting(plan, current):
    """The invariant the whole feature rests on: every file the index links
    to today ends up in exactly one bucket, and the plan invents no files
    that aren't there. Anything else means the model lost track of a note,
    and applying would silently drop or clobber it."""
    accounted = {}
    for name in _unchanged(plan):
        conflict = _account(accounted, name, "unchanged")
        if conflict:
            return conflict
    for entry in _entries(plan):
        for source in _sources(entry):
            conflict = _account(accounted, source, "entries[].sources")
            if conflict:
                return conflict
    for item in _discard(plan):
        conflict = _account(accounted, _field(item, "file"), "discard")
        if conflict:
            return conflict

    missing = current - set(accounted)
    if missing:
        return "plan doesn't account for: " + ", ".join(sorted(missing))
    # Two kinds of harmless noise the model sometimes puts in
    # unchanged/sources/discard, neither of which is an invented *old* file
    # that got silently dropped: (1) an entry's own new target, mentioned
    # again while explaining what it's about -- files_to_delete()
    # separately guarantees that one is never deleted even if this same
    # confusion puts it in discard instead; and (2) something that was
    # never a filename at all, e.g. a phrase or identifier it picked up
    # from the source project and mistook for one of the notes. Every real
    # note -- existing or newly created -- ends in .md by this plugin's own
    # naming convention, so anything that doesn't can't legitimately be a
    # lost note; only .md-suffixed extras are worth rejecting the plan over.
    new_targets = set(_field(entry, "file") for entry in _entries(plan))
    extra = set(name for name in set(accounted) - current - new_targets if name.endswith(".md"))
    if extra:
        return "plan references files that aren't in the current index: " + ", ".join(sorted(extra))

    for entry in _entries(plan):
        target = _field(entry, "file")
        if target in current and target not in _sources(entry):
            return "entry targets existing file %s without listing it as a source" % target
    return None


def _account(accounted, name, bucket):
    if name in accounted:
        return "%s is listed in both %s and %s" % (name, accounted[name], bucket)
    accounted[name] = bucket
    return None


# Accessors, not attribute access: a plan is model output, so any element
# of any list may turn out not to be an object at all. Reading a missing
# field as None lets the checks above report it as invalid instead of
# raising, which would strand the panel mid-run.
def _field(obj, name):
    return obj.get(name) if isinstance(obj, dict) else None


def _unchanged(plan):
    return plan.get("unchanged", [])


def _entries(plan):
    return plan.get("entries", [])


def _discard(plan):
    return plan.get("discard", [])


def _sources(entry):
    sources = _field(entry, "sources")
    return sources if isinstance(sources, list) else []


def _is_single_line_str(value):
    return isinstance(value, str) and "\n" not in value


def superseded_sources(plan):
    """Files folded into an entry under a different name. An entry that
    reuses one of its own sources' filenames is rewriting it in place, not
    superseding it."""
    return set(source
               for entry in _entries(plan)
               for source in _sources(entry)
               if source != _field(entry, "file"))


def files_to_delete(plan):
    """Every entry's own target is excluded unconditionally, even if the
    same name also turns up in discard -- apply_plan() writes entries
    before deleting this set, so without this a plan that confusedly
    discards the file it just created would delete its own fresh output
    in the same run."""
    written = set(_field(entry, "file") for entry in _entries(plan))
    to_delete = superseded_sources(plan) | set(_field(item, "file") for item in _discard(plan))
    return to_delete - written


def stale_index_files(plan, current_files):
    """Which index lines the rewrite must drop: everything being deleted,
    plus the lines for entries that already exist and are about to be
    re-listed with fresh text."""
    rewritten = set(_field(entry, "file") for entry in _entries(plan)) & set(current_files)
    return files_to_delete(plan) | rewritten


def entry_document(entry):
    """The full .md file for one entry: frontmatter the panel's parseEntry()
    can read back, then the body."""
    return (
        "---\n"
        "name: " + entry["title"] + "\n"
        "description: " + entry["description"] + "\n"
        "type: " + entry["type"] + "\n"
        "---\n\n"
        + entry["body"].strip() + "\n"
    )


def index_line(entry):
    return "- [" + entry["title"] + "](" + entry["file"] + ") — " + entry["description"]
