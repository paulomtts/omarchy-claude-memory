"""The rules for reading a MEMORY.md index and for deciding what a script
is allowed to touch. Every filename these scripts act on -- from argv, from
an index line, from a model-written plan -- comes through here first.
"""
import json

import pytest

from claude_memory import (drop_index_lines, index_link, index_targets, is_memory_dir,
                           is_safe_filename, normalize_href, verified_source_dir)

INDEX = """# Project Memory

Some prose about this project.

- [Feed feature](feed.md) — how the feed works
- [VFR fix](./feedback_vfr.md) — brightness oscillation
- a plain bullet that isn't a link
"""


@pytest.mark.parametrize("name, safe", [
    ("notes.md", True),
    (".hidden.md", True),
    ("", False),
    ("sub/notes.md", False),
    ("../../.bashrc", False),
    (".", False),
    ("..", False),
    # A plan is JSON from a model, so a filename slot can hold anything.
    (None, False),
    (42, False),
])
def test_only_a_plain_basename_is_a_safe_filename(name, safe):
    assert is_safe_filename(name) is safe


def test_only_a_directory_named_memory_counts_as_one(tmp_path):
    (tmp_path / "memory").mkdir()
    (tmp_path / "notes").mkdir()
    assert is_memory_dir(str(tmp_path / "memory"))
    assert is_memory_dir(str(tmp_path / "memory") + "/")
    assert not is_memory_dir(str(tmp_path / "notes"))
    assert not is_memory_dir(str(tmp_path / "memory" / "gone"))


# The bug that had to be fixed three times independently: "./name" opens the
# same file but compares equal to nothing, so a plan that named the file
# bare looked like it had forgotten about it.
@pytest.mark.parametrize("href, expected", [
    ("feed.md", "feed.md"),
    ("./feed.md", "feed.md"),
    ("  ./feed.md  ", "feed.md"),
    ("../feed.md", "../feed.md"),
])
def test_a_dot_slash_prefix_is_normalized_away(href, expected):
    assert normalize_href(href) == expected


def test_reads_title_file_and_hook_from_a_link_line():
    assert index_link("- [Feed feature](feed.md) — how the feed works") == (
        "Feed feature", "feed.md", "— how the feed works")


@pytest.mark.parametrize("line", [
    "## A heading",
    "- a plain bullet",
    "[not a bullet](feed.md)",
    "",
])
def test_anything_that_isnt_a_link_line_is_prose(line):
    assert index_link(line) is None


def test_index_targets_are_the_linked_files_only():
    assert index_targets(INDEX) == {"feed.md", "feedback_vfr.md"}


def test_dropping_a_link_leaves_every_other_line_untouched():
    result = drop_index_lines(INDEX, {"feed.md"})
    assert "feed.md" not in result
    assert "Some prose about this project." in result
    assert "- [VFR fix](./feedback_vfr.md) — brightness oscillation" in result
    assert "- a plain bullet that isn't a link" in result


def test_a_dot_slash_link_is_dropped_by_its_bare_name():
    assert "feedback_vfr.md" not in drop_index_lines(INDEX, {"feedback_vfr.md"})


def test_dropping_nothing_changes_nothing():
    assert drop_index_lines(INDEX, set()) == INDEX


# ---- verified_source_dir: the authoritative alternative to decode_slug's
# guess, used wherever a real directory is granted to Claude -------------

def write_transcript(project_dir, name, cwd):
    project_dir.mkdir(parents=True, exist_ok=True)
    (project_dir / name).write_text(json.dumps({"cwd": cwd}) + "\n", encoding="utf-8")


def test_reads_cwd_from_a_session_transcript(tmp_path):
    real = tmp_path / "Code" / "my-app"
    real.mkdir(parents=True)
    project_dir = tmp_path / "projects" / "-some-slug"
    write_transcript(project_dir, "session.jsonl", str(real))
    assert verified_source_dir(str(project_dir)) == str(real)


def test_a_cwd_that_no_longer_exists_is_not_verified(tmp_path):
    project_dir = tmp_path / "projects" / "-some-slug"
    write_transcript(project_dir, "session.jsonl", str(tmp_path / "gone"))
    assert verified_source_dir(str(project_dir)) == ""


def test_no_transcript_at_all_is_not_verified(tmp_path):
    project_dir = tmp_path / "projects" / "-some-slug"
    project_dir.mkdir(parents=True)
    assert verified_source_dir(str(project_dir)) == ""


def test_a_transcript_with_garbled_json_is_skipped_not_raised(tmp_path):
    real = tmp_path / "Code" / "my-app"
    real.mkdir(parents=True)
    project_dir = tmp_path / "projects" / "-some-slug"
    project_dir.mkdir(parents=True)
    (project_dir / "broken.jsonl").write_text("not json\n", encoding="utf-8")
    (project_dir / "session.jsonl").write_text(json.dumps({"cwd": str(real)}) + "\n", encoding="utf-8")
    assert verified_source_dir(str(project_dir)) == str(real)
