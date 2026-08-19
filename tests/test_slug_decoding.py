"""decode_slug() undoes an encoding that threw information away: every "/"
became a "-", and a directory whose own name contains a hyphen is now
indistinguishable from two nested directories. The only thing that can tell
them apart is the filesystem, so these scenarios are written as "given
these directories exist".
"""
import pytest

from claude_memory import decode_slug


def fake_isdir(*directories):
    known = set(directories)
    return lambda path: path.rstrip("/") in known or path == "/"


HOME = ("/home", "/home/mtts", "/home/mtts/Code")


@pytest.mark.parametrize("slug, existing, expected", [
    # A hyphen in a real directory name: only the filesystem says whether
    # refactor-nori is one directory or two.
    ("-home-mtts-Code-refactor-nori", HOME + ("/home/mtts/Code/refactor-nori",),
     "/home/mtts/Code/refactor-nori"),
    ("-home-mtts-Code-refactor-nori", HOME + ("/home/mtts/Code/refactor", "/home/mtts/Code/refactor/nori"),
     "/home/mtts/Code/refactor/nori"),
    # Several hyphens in one component, and several hyphenated components.
    ("-home-mtts-Code-my-cool-app", HOME + ("/home/mtts/Code/my-cool-app",),
     "/home/mtts/Code/my-cool-app"),
    ("-home-mtts-Code-my-app-src-web-ui", HOME + ("/home/mtts/Code/my-app", "/home/mtts/Code/my-app/src",
                                                  "/home/mtts/Code/my-app/src/web-ui"),
     "/home/mtts/Code/my-app/src/web-ui"),
    # No hyphens to disambiguate at all.
    ("-home-mtts", HOME, "/home/mtts"),
    # The shortest match wins: with both Code/chat and Code/chat-go present,
    # the encoding of Code/chat-go is ambiguous and "chat" is chosen, then
    # "go" is looked for beneath it. That's the wrong guess, but it's the
    # only one that's greedy-consistent -- documented, not accidental.
    ("-home-mtts-Code-chat-go", HOME + ("/home/mtts/Code/chat", "/home/mtts/Code/chat-go"),
     "/home/mtts/Code/chat/go"),
])
def test_decodes_against_the_real_filesystem(slug, existing, expected):
    assert decode_slug(slug, isdir=fake_isdir(*existing)) == expected


@pytest.mark.parametrize("slug, existing, expected", [
    # Renamed/moved/deleted since: keep the prefix that still exists and
    # fall back to one-dash-one-slash for the rest, which reads far better
    # than the raw slug and is the guess the encoding makes on average.
    ("-home-mtts-Code-chat-go", HOME, "/home/mtts/Code/chat/go"),
    # Nothing verifiable at all beyond the root.
    ("-var-lib-something", (), "/var/lib/something"),
    # A partial prefix: /home exists, /home/gone does not.
    ("-home-gone-deep-path", ("/home",), "/home/gone/deep/path"),
])
def test_falls_back_to_a_plain_split_past_what_it_can_verify(slug, existing, expected):
    assert decode_slug(slug, isdir=fake_isdir(*existing)) == expected


def test_a_slug_that_isnt_an_encoded_path_is_not_decoded():
    # Claude Code always encodes an absolute path, so a slug with no leading
    # dash isn't one; resolve-projects.py prints it raw rather than guessing.
    assert decode_slug("not-a-path", isdir=fake_isdir()) is None


def test_decodes_a_real_directory_tree(tmp_path):
    (tmp_path / "my-project" / "src").mkdir(parents=True)
    slug = str(tmp_path / "my-project" / "src").replace("/", "-")
    assert decode_slug(slug) == str(tmp_path / "my-project" / "src")
