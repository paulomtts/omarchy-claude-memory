import os
import subprocess
import sys

import pytest

PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PLUGIN_DIR)


@pytest.fixture
def memory_dir(tmp_path):
    """A project directory laid out the way Claude Code lays one out: a
    slug-named dir with a "memory" dir inside it. The name matters -- every
    script refuses to touch a directory not called "memory"."""
    path = tmp_path / "-home-someone-Code-project" / "memory"
    path.mkdir(parents=True)
    return path


@pytest.fixture
def write_memory(memory_dir):
    """Populate a memory dir: an index, plus a file per note it links to."""
    def write(index, notes=None):
        (memory_dir / "MEMORY.md").write_text(index, encoding="utf-8")
        for name, content in (notes or {}).items():
            (memory_dir / name).write_text(content, encoding="utf-8")
        return memory_dir
    return write


@pytest.fixture
def run_script():
    """Invoke one of the plugin's CLIs the way Panel.qml does, and hand back
    the ok/error result lines it printed."""
    def run(script, *args, stdin="", home=None):
        # consolidate-apply.py backs up under $HOME before it writes, so a
        # test that points HOME at a tmp dir keeps the real one out of it.
        env = dict(os.environ, HOME=str(home)) if home else None
        proc = subprocess.run([sys.executable, os.path.join(PLUGIN_DIR, script), *args],
                              input=stdin, capture_output=True, text=True, env=env)
        lines = [line.split("\t") for line in proc.stdout.strip().split("\n") if line]
        return proc.returncode, lines
    return run
