"""consolidate-apply.py end to end: what a validated plan actually does to
a memory dir, and what an invalid one is prevented from doing.

Validation itself is covered file-by-file in test_plan_validation.py; the
scenarios here are about the mutation on the other side of it.
"""
import json

INDEX = """# Project Memory

Notes about this project.

- [Feed](feed.md) — the feed
- [Feed follow-up](./feed_notes.md) — more feed
- [Keep](keep.md) — still useful
- [Junk](junk.md) — stale
"""

NOTES = {
    "feed.md": "---\nname: Feed\ndescription: the feed\ntype: note\n---\n\nfeed body",
    "feed_notes.md": "more feed body",
    "keep.md": "keep body",
    "junk.md": "junk body",
}

PLAN = {
    "unchanged": ["keep.md"],
    "entries": [{
        "file": "feed.md",
        "title": "Feed",
        "description": "everything about the feed",
        "type": "note",
        "body": "merged feed body",
        "sources": ["feed.md", "feed_notes.md"],
    }],
    "discard": [{"file": "junk.md", "reason": "stale"}],
}


def apply(run_script, memory, plan, home):
    return run_script("consolidate-apply.py", str(memory), stdin=json.dumps(plan), home=home)


def test_applying_a_plan_merges_discards_and_rewrites_the_index(write_memory, run_script, tmp_path):
    memory = write_memory(INDEX, NOTES)
    code, lines = apply(run_script, memory, PLAN, tmp_path)

    assert code == 0
    assert sorted(line[1] for line in lines) == ["MEMORY.md", "feed.md", "feed_notes.md", "junk.md"]
    assert all(line[0] == "ok" for line in lines)

    assert (memory / "feed.md").read_text() == (
        "---\nname: Feed\ndescription: everything about the feed\ntype: note\n---\n\n"
        "merged feed body\n")
    assert not (memory / "feed_notes.md").exists()
    assert not (memory / "junk.md").exists()
    assert (memory / "keep.md").read_text() == "keep body"

    index = (memory / "MEMORY.md").read_text()
    assert "Notes about this project." in index
    assert "feed_notes.md" not in index and "junk.md" not in index
    assert index.rstrip().endswith("- [Feed](feed.md) — everything about the feed")
    # The rewritten entry gets exactly one line, not its old one plus a new.
    assert index.count("feed.md") == 1


def test_the_memory_dir_is_backed_up_before_anything_changes(write_memory, run_script, tmp_path):
    memory = write_memory(INDEX, NOTES)
    apply(run_script, memory, PLAN, tmp_path)

    backups = list((tmp_path / ".cache" / "omarchy-claude-memory" / "backups").iterdir())
    assert len(backups) == 1
    # The pre-apply content, since there's no undo in the panel.
    assert (backups[0] / "feed_notes.md").read_text() == "more feed body"
    assert (backups[0] / "MEMORY.md").read_text() == INDEX


def test_an_invalid_plan_changes_nothing(write_memory, run_script, tmp_path):
    memory = write_memory(INDEX, NOTES)
    incomplete = dict(PLAN, unchanged=[])

    code, lines = apply(run_script, memory, incomplete, tmp_path)

    assert code == 1
    assert lines[0][0] == "error" and "doesn't account for: keep.md" in lines[0][2]
    assert (memory / "MEMORY.md").read_text() == INDEX
    assert (memory / "feed_notes.md").exists()
    assert not (tmp_path / ".cache").exists()


def test_a_plan_naming_the_index_as_a_source_never_deletes_it(write_memory, run_script, tmp_path):
    # This one is why sanitizing happens before validating: a model that
    # lists MEMORY.md among an entry's sources would otherwise have the
    # index deleted as superseded, taking every link with it.
    memory = write_memory(INDEX, NOTES)
    plan = json.loads(json.dumps(PLAN))
    plan["entries"][0]["sources"].append("MEMORY.md")

    code, _ = apply(run_script, memory, plan, tmp_path)

    assert code == 0
    assert (memory / "MEMORY.md").exists()
    assert "- [Feed](feed.md) — everything about the feed" in (memory / "MEMORY.md").read_text()


def test_a_merge_into_a_new_file_leaves_no_trace_of_its_sources(write_memory, run_script, tmp_path):
    memory = write_memory(INDEX, NOTES)
    plan = json.loads(json.dumps(PLAN))
    plan["entries"][0]["file"] = "feed_all.md"

    apply(run_script, memory, plan, tmp_path)

    assert (memory / "feed_all.md").exists()
    assert not (memory / "feed.md").exists()
    index = (memory / "MEMORY.md").read_text()
    assert "](feed.md)" not in index and "feed_notes.md" not in index


def test_malformed_json_is_reported_as_a_result_line(write_memory, run_script, tmp_path):
    memory = write_memory(INDEX, NOTES)
    code, lines = run_script("consolidate-apply.py", str(memory), stdin="{not json", home=tmp_path)

    assert code == 1
    assert lines[0][0] == "error" and lines[0][2].startswith("invalid plan JSON:")
    assert (memory / "MEMORY.md").read_text() == INDEX


def test_it_refuses_a_directory_that_isnt_a_memory_dir(run_script, tmp_path):
    code, lines = run_script("consolidate-apply.py", str(tmp_path),
                             stdin=json.dumps(PLAN), home=tmp_path)
    assert code == 1
    assert lines == [["error", str(tmp_path), "not a memory directory"]]
