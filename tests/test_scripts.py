"""The three smaller CLIs: listing projects, reading note content back for
the review screen, and building the `claude` invocation.
"""
import json

import pytest

INDEX = "- [Note](note.md) — a note\n"


@pytest.fixture
def projects_root(tmp_path):
    """Two projects with memory, one without -- plus a real directory tree
    for one of them so its slug resolves to a verified path."""
    (tmp_path / "Code" / "my-app").mkdir(parents=True)
    root = tmp_path / "projects"
    for slug in ("-" + str(tmp_path / "Code" / "my-app").lstrip("/").replace("/", "-"), "-gone-project"):
        (root / slug / "memory").mkdir(parents=True)
        (root / slug / "memory" / "MEMORY.md").write_text(INDEX)
    (root / "-no-memory-here").mkdir(parents=True)
    return root, tmp_path


def test_lists_only_projects_that_have_a_memory_index(run_script, projects_root):
    root, tmp_path = projects_root
    _, lines = run_script("resolve-projects.py", str(root))

    labels = {line[1] for line in lines}
    assert len(lines) == 2
    # A slug whose directories still exist resolves to the real path, hyphen
    # in "my-app" and all; one that doesn't falls back to a plain split.
    assert str(tmp_path / "Code" / "my-app") in labels
    assert "/gone/project" in labels
    assert all(line[0].endswith("/memory") for line in lines)


def test_a_projects_root_that_isnt_there_lists_nothing(run_script, tmp_path):
    code, lines = run_script("resolve-projects.py", str(tmp_path / "nope"))
    assert code == 0 and lines == []


def test_reads_the_requested_notes(write_memory, run_script):
    memory = write_memory(INDEX, {"note.md": "note body", "other.md": "other body"})
    _, lines = run_script("read-entries.py", str(memory), "note.md")
    assert json.loads(lines[0][0]) == {"note.md": "note body"}


def test_unreadable_or_unsafe_names_are_omitted_not_fatal(write_memory, run_script):
    # The review screen shows "no preview" for a missing key, so one bad
    # name must not cost the whole batch.
    memory = write_memory(INDEX, {"note.md": "note body"})
    _, lines = run_script("read-entries.py", str(memory), "note.md", "gone.md", "../../.bashrc", "..")
    assert json.loads(lines[0][0]) == {"note.md": "note body"}


def test_a_directory_that_isnt_a_memory_dir_reads_as_empty(run_script, tmp_path):
    _, lines = run_script("read-entries.py", str(tmp_path), "note.md")
    assert json.loads(lines[0][0]) == {}


def test_the_source_project_is_granted_read_only_when_it_resolves(write_memory, run_script, tmp_path):
    memory = write_memory(INDEX, {"note.md": "body"})
    source = tmp_path / "src"
    source.mkdir()

    _, lines = run_script("consolidate-run.py", "--dry-run", str(memory), str(source))
    argv = json.loads(lines[0][0])["argv"]

    assert argv[:2] == ["claude", "-p"]
    assert "--add-dir" in argv and argv[argv.index("--add-dir") + 1] == str(source)
    assert "check whether a note is still accurate against" in argv[-1]
    # Read-only by construction: no tool that could write, and plan mode.
    assert argv[argv.index("--tools") + 1] == "Read,Glob,Grep"
    assert argv[argv.index("--permission-mode") + 1] == "plan"


@pytest.mark.parametrize("source", ["", "/nonexistent/project"])
def test_an_unresolved_source_project_falls_back_to_judging_the_notes_alone(
        write_memory, run_script, source):
    memory = write_memory(INDEX, {"note.md": "body"})
    _, lines = run_script("consolidate-run.py", "--dry-run", str(memory), source)
    argv = json.loads(lines[0][0])["argv"]

    assert "--add-dir" not in argv
    assert "source code is not available this time" in argv[-1]


def test_it_refuses_a_directory_that_isnt_a_memory_dir(run_script, tmp_path):
    # Reported as a stream-json result line, so the panel's normal parser
    # surfaces it without a second error protocol.
    code, lines = run_script("consolidate-run.py", "--dry-run", str(tmp_path))
    assert code == 1
    event = json.loads(lines[0][0])
    assert event["type"] == "result" and event["is_error"]
    assert event["result"].startswith("not a memory directory:")
