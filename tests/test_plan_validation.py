"""validate_plan() is the last gate before files are written and deleted on
the strength of model output, so the scenarios below are organised as a
decision matrix over the ways a plan can be wrong -- one case per distinct
failure, rather than every combination of them.

The baseline plan is the same throughout: an index of four notes, one kept
as-is, two merged into a new file, one discarded.
"""
import copy

import pytest

from consolidate_plan import (files_to_delete, index_line, sanitize_plan, stale_index_files,
                              superseded_sources, validate_plan)

CURRENT = {"keep.md", "a.md", "b.md", "junk.md"}


def entry(file, sources, **overrides):
    fields = {"file": file, "title": "T", "description": "D", "type": "note",
              "body": "Body", "sources": sources}
    fields.update(overrides)
    return fields


@pytest.fixture
def plan():
    return {
        "unchanged": ["keep.md"],
        "entries": [entry("merged.md", ["a.md", "b.md"])],
        "discard": [{"file": "junk.md", "reason": "stale"}],
    }


def mutate(plan, **changes):
    plan = copy.deepcopy(plan)
    plan.update(changes)
    return plan


# ---- plans that are safe to apply ----------------------------------------

def test_a_complete_plan_is_accepted(plan):
    assert validate_plan(plan, CURRENT) is None


def test_an_entry_may_rewrite_one_of_its_own_sources_in_place(plan):
    # Reusing a source's filename is an edit, not an overwrite: the old
    # content was read, so nothing is lost.
    assert validate_plan(mutate(plan, entries=[entry("a.md", ["a.md", "b.md"])]), CURRENT) is None


def test_a_plan_that_changes_nothing_is_accepted():
    assert validate_plan({"unchanged": sorted(CURRENT), "entries": [], "discard": []}, CURRENT) is None


def test_an_empty_index_accepts_an_empty_plan():
    assert validate_plan({"unchanged": [], "entries": [], "discard": []}, set()) is None


# ---- the accounting invariant --------------------------------------------

def test_a_note_left_out_of_every_bucket_is_rejected(plan):
    # The whole point of the check: an unaccounted note would be neither
    # kept, merged nor discarded, and the index rewrite would lose it.
    assert "doesn't account for: keep.md" in validate_plan(mutate(plan, unchanged=[]), CURRENT)


def test_a_note_that_isnt_in_the_index_is_rejected(plan):
    invented = mutate(plan, unchanged=["keep.md", "ghost.md"])
    assert "aren't in the current index: ghost.md" in validate_plan(invented, CURRENT)


@pytest.mark.parametrize("changes, expected", [
    ({"unchanged": ["keep.md", "a.md"]}, "a.md is listed in both unchanged and entries[].sources"),
    ({"discard": [{"file": "keep.md", "reason": "r"}, {"file": "junk.md", "reason": "r"}]},
     "keep.md is listed in both unchanged and discard"),
    ({"entries": [entry("m1.md", ["a.md"]), entry("m2.md", ["a.md", "b.md"])]},
     "a.md is listed in both entries[].sources and entries[].sources"),
])
def test_a_note_accounted_for_twice_is_rejected(plan, changes, expected):
    assert validate_plan(mutate(plan, **changes), CURRENT) == expected


def test_two_entries_writing_the_same_file_are_rejected(plan):
    collide = mutate(plan, entries=[entry("same.md", ["a.md"]), entry("same.md", ["b.md"])])
    assert validate_plan(collide, CURRENT) == "two entries target the same file"


def test_an_entry_overwriting_a_file_it_never_read_is_rejected(plan):
    # Everything is accounted for, so only the last check catches this: the
    # merge writes over keep.md, which it called unchanged and never read.
    clobber = mutate(plan, entries=[entry("keep.md", ["a.md", "b.md"])])
    assert validate_plan(clobber, CURRENT) == (
        "entry targets existing file keep.md without listing it as a source")


# ---- filename safety -----------------------------------------------------

@pytest.mark.parametrize("changes, expected", [
    ({"unchanged": ["../../.bashrc"]}, "unsafe filename in unchanged: ../../.bashrc"),
    ({"entries": [entry("../evil.md", ["a.md"])]}, "unsafe filename in entries: ../evil.md"),
    ({"entries": [entry("m.md", ["sub/a.md"])]}, "unsafe source filename: sub/a.md"),
    ({"discard": [{"file": "..", "reason": "r"}]}, "unsafe filename in discard: .."),
    ({"entries": [{"sources": ["a.md"]}]}, "unsafe filename in entries: None"),
])
def test_nothing_may_name_a_file_outside_the_memory_dir(plan, changes, expected):
    # Checked before accounting, so a traversal attempt is refused even
    # while the plan is incoherent in other ways too.
    assert validate_plan(mutate(plan, **changes), CURRENT) == expected


# ---- field shapes --------------------------------------------------------

@pytest.mark.parametrize("overrides, expected", [
    ({"title": None}, "entry missing or invalid field: title"),
    ({"description": 3}, "entry missing or invalid field: description"),
    ({"type": "note\nsmuggled: yes"}, "entry missing or invalid field: type"),
    ({"title": "a\nb"}, "entry missing or invalid field: title"),
    ({"body": None}, "entry missing or invalid field: body"),
])
def test_entry_fields_must_be_writable_as_they_are(plan, overrides, expected):
    # title/description/type are interpolated into YAML frontmatter and into
    # an index line, so a newline in one would forge a second key or line.
    broken = mutate(plan, entries=[entry("merged.md", ["a.md", "b.md"], **overrides)])
    assert validate_plan(broken, CURRENT) == expected


def test_an_entry_needs_a_real_list_of_sources(plan):
    one_string = mutate(plan, entries=[entry("merged.md", "a.md")])
    assert validate_plan(one_string, CURRENT) == "entry missing or invalid field: sources"


def test_a_discard_needs_a_single_line_reason(plan):
    no_reason = mutate(plan, discard=[{"file": "junk.md"}])
    assert validate_plan(no_reason, CURRENT) == "discard item missing or invalid field: reason"


@pytest.mark.parametrize("bad_plan, expected", [
    ("not a plan", "plan is not a JSON object"),
    (None, "plan is not a JSON object"),
    ({"unchanged": {}, "entries": [], "discard": []}, "plan has the wrong shape"),
    ({"unchanged": [], "entries": None, "discard": []}, "plan has the wrong shape"),
    ({"unchanged": [], "entries": []}, "plan doesn't account for: a.md, b.md, junk.md, keep.md"),
])
def test_a_plan_of_the_wrong_shape_is_rejected(bad_plan, expected):
    assert validate_plan(bad_plan, CURRENT) == expected


@pytest.mark.parametrize("bad_plan", [
    {"unchanged": [None], "entries": [], "discard": []},
    {"unchanged": [], "entries": [None, "oops"], "discard": []},
    {"unchanged": [], "entries": [], "discard": [None]},
    {"unchanged": [], "entries": [{"file": "m.md", "sources": None}], "discard": []},
])
def test_garbled_json_is_reported_not_raised(bad_plan):
    # A model can put anything in any slot. An exception here would escape
    # as a traceback on stderr and no result line at all.
    assert isinstance(validate_plan(bad_plan, CURRENT), str)


# ---- MEMORY.md is the index, never an accountable note -------------------

def test_the_index_is_stripped_from_every_bucket():
    plan = sanitize_plan({
        "unchanged": ["MEMORY.md", "keep.md"],
        "entries": [entry("merged.md", ["MEMORY.md", "a.md"])],
        "discard": [{"file": "MEMORY.md", "reason": "x"}, {"file": "junk.md", "reason": "y"}],
    })
    assert plan["unchanged"] == ["keep.md"]
    assert plan["entries"][0]["sources"] == ["a.md"]
    assert plan["discard"] == [{"file": "junk.md", "reason": "y"}]


def test_a_plan_mentioning_the_index_still_validates(plan):
    # Left in sources it would be deleted as superseded, taking the index
    # with it; rejected outright it would fail a plan that's otherwise fine.
    plan["entries"][0]["sources"].append("MEMORY.md")
    assert validate_plan(sanitize_plan(plan), CURRENT) is None


def test_sanitizing_leaves_a_malformed_plan_alone_for_validation_to_reject():
    assert sanitize_plan("nonsense") == "nonsense"


# ---- what a validated plan implies ---------------------------------------

def test_only_sources_folded_under_another_name_are_superseded():
    plan = {"unchanged": [], "discard": [], "entries": [
        entry("a.md", ["a.md", "b.md"]),   # a.md is rewritten in place
        entry("new.md", ["c.md"]),         # c.md is folded into a new file
    ]}
    assert superseded_sources(plan) == {"b.md", "c.md"}


def test_deletions_are_the_superseded_sources_plus_the_discards(plan):
    assert files_to_delete(plan) == {"a.md", "b.md", "junk.md"}


def test_stale_index_lines_include_entries_being_relisted(plan):
    # merged.md is new, so no line for it exists yet; a.md would already
    # have one, and its line has to go before the fresh one is appended.
    assert stale_index_files(plan, CURRENT) == {"a.md", "b.md", "junk.md"}
    rewrite = mutate(plan, entries=[entry("a.md", ["a.md", "b.md"])])
    assert stale_index_files(rewrite, CURRENT) == {"a.md", "b.md", "junk.md"}


def test_an_index_line_carries_the_title_file_and_description():
    assert index_line(entry("m.md", [], title="Merged", description="two notes in one")) == (
        "- [Merged](m.md) — two notes in one")
