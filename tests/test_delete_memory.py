"""delete-memory.py end to end, against real directories: what it removes,
what it refuses to touch, and what it leaves in MEMORY.md afterwards.
"""
INDEX = """# Project Memory

- [Feed](feed.md) — the feed
- [VFR](./feedback_vfr.md) — brightness
- [Keep](keep.md) — still useful
"""

NOTES = {"feed.md": "feed body", "feedback_vfr.md": "vfr body", "keep.md": "keep body"}


def test_deleting_an_entry_removes_the_file_and_its_index_line(write_memory, run_script):
    memory = write_memory(INDEX, NOTES)
    code, lines = run_script("delete-memory.py", "entries", str(memory), "feed.md")

    assert code == 0
    assert lines == [["ok", "feed.md"]]
    assert not (memory / "feed.md").exists()
    index = (memory / "MEMORY.md").read_text()
    assert "feed.md" not in index
    assert "keep.md" in index and "feedback_vfr.md" in index


# The ./-prefixed link is why this is worth an end-to-end test: the file is
# deleted by its bare name, but the index line spells it "./feedback_vfr.md".
def test_a_dot_slash_index_line_is_still_pruned(write_memory, run_script):
    memory = write_memory(INDEX, NOTES)
    run_script("delete-memory.py", "entries", str(memory), "feedback_vfr.md")
    assert "feedback_vfr" not in (memory / "MEMORY.md").read_text()


def test_a_failed_delete_leaves_its_index_line_in_place(write_memory, run_script):
    memory = write_memory(INDEX, NOTES)
    code, lines = run_script("delete-memory.py", "entries", str(memory), "feed.md", "gone.md")

    assert lines == [["ok", "feed.md"], ["error", "gone.md", "not found"]]
    index = (memory / "MEMORY.md").read_text()
    assert "feed.md" not in index
    # Only files that were actually removed are pruned, so a partial
    # failure can't strip a link to a note that's still there.
    assert "keep.md" in index


def test_nothing_escapes_the_memory_dir(write_memory, run_script, tmp_path):
    memory = write_memory(INDEX, NOTES)
    outside = tmp_path / "secret.md"
    outside.write_text("private")

    _, lines = run_script("delete-memory.py", "entries", str(memory),
                          "../secret.md", "sub/x.md", "..", ".")

    assert all(line[0] == "error" and line[2] == "invalid filename" for line in lines)
    assert outside.exists()
    assert (memory / "MEMORY.md").read_text() == INDEX


def test_only_a_directory_named_memory_can_be_deleted(write_memory, run_script, tmp_path):
    write_memory(INDEX, NOTES)
    decoy = tmp_path / "notes"
    decoy.mkdir()

    code, lines = run_script("delete-memory.py", "project", str(decoy))

    assert lines == [["error", str(decoy), "not a memory directory"]]
    assert decoy.exists()


def test_deleting_a_project_removes_the_whole_memory_dir(write_memory, run_script):
    memory = write_memory(INDEX, NOTES)
    code, lines = run_script("delete-memory.py", "project", str(memory))

    assert lines == [["ok", str(memory)]]
    assert not memory.exists()
    # The project's other Claude Code data is none of this script's business.
    assert memory.parent.exists()


def test_each_item_reports_its_own_outcome(write_memory, run_script, tmp_path):
    memory = write_memory(INDEX, NOTES)
    missing = tmp_path / "-gone" / "memory"

    _, lines = run_script("delete-memory.py", "project", str(memory), str(missing))

    assert lines == [["ok", str(memory)], ["error", str(missing), "not a memory directory"]]


def test_an_unknown_mode_is_a_usage_error(run_script):
    code, lines = run_script("delete-memory.py", "wipe", "/tmp")
    assert code == 2
    assert lines == [["error", "", "unknown mode: wipe"]]
