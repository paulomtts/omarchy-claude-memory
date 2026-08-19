# omarchy-claude-memory

An [Omarchy](https://omarchy.org/) shell plugin that browses [Claude Code](https://claude.com/product/claude-code)'s
persistent memory — the `MEMORY.md` index and linked notes each project
builds up under `~/.claude/projects/<slug>/memory/` — not the conversation
context. One bar icon, one panel: pick a project, read its memory index,
open any linked note.

## Features

- **Projects list** — every project with a `memory/` directory, with the
  Claude Code path-encoding slug (`-home-user-Code-my-app`) decoded back to
  a real path by checking the filesystem, not by guessing. This correctly
  tells a literal hyphen in a directory name (`refactor-nori`) apart from an
  encoded path separator, and falls back to the raw slug for a project
  whose directory has since moved or been deleted rather than guessing wrong.
- **Memory index** — parses `MEMORY.md` for `- [Title](file.md) — hook`
  lines and lists them.
- **Entry view** — opens a linked note, showing its frontmatter (`name`,
  `description`, `type`) and body.
- **Search** — type to filter projects or memory entries live.
- **Full keyboard navigation** — Up/Down move the cursor; Enter, or Right
  once the caret is at the end of the search text, opens the highlighted
  item; Left at the start of the search text (or Escape) backs out, and
  Escape closes the panel at the top level; Tab switches to the next bar
  panel. The search box has focus by default, so typing works immediately,
  and editing mid-query still moves the caret normally with Left/Right.
- **Consolidate** — inside a project's memory index, a "✨ Consolidate"
  button asks Claude Code to review every note (plus, when the project's
  source directory can still be resolved, the actual source project — so
  it can check a note's claims against the current code) and propose a
  merged/pruned set. Nothing is written until you review the full
  proposal — new/merged content, discarded notes with reasons, and what's
  left unchanged — and type `apply` to confirm. A backup of the memory
  directory is kept before applying. This runs `claude -p` with read-only
  tool access (`Read`/`Glob`/`Grep` only, `--permission-mode plan`, and a
  `--json-schema`-enforced response) and counts against your normal
  Claude subscription usage.
- **Manage mode** — select projects or memory entries and delete them,
  gated behind typing the word `delete` to confirm. Deleting a project only
  removes its `memory/` directory (not its Claude Code conversation
  history); deleting a memory entry removes the note file and its line in
  `MEMORY.md`. The `Delete` key is also a "delete this one" shortcut for
  whatever's under the cursor, in or out of manage mode.
- Live-reloads if `MEMORY.md` or a note changes on disk while the panel is open.

## Install

```bash
omarchy plugin add https://github.com/paulomtts/omarchy-claude-memory.git --enable --yes
```

Or by hand:

```bash
git clone https://github.com/paulomtts/omarchy-claude-memory.git \
  ~/.config/omarchy/plugins/paulomtts.claude-memory
omarchy-shell shell rescanPlugins
omarchy plugin enable paulomtts.claude-memory
```

## Uninstall

```bash
omarchy plugin remove paulomtts.claude-memory --yes
```

Or by hand:

```bash
omarchy plugin disable paulomtts.claude-memory
rm -rf ~/.config/omarchy/plugins/paulomtts.claude-memory
```

Consolidate's pre-apply backups live outside the plugin directory, at
`~/.cache/omarchy-claude-memory/backups/`, and aren't touched by either
removal path — delete that folder too for a full cleanup.

## Keybinding (optional)

Add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("CTRL + SUPER + M", "Toggle Claude Memory", "omarchy-shell shell toggle paulomtts.claude-memory '{}'")
```

## Settings

| Key | Default | Description |
|---|---|---|
| `projectsRoot` | `""` (→ `~/.claude/projects`) | Override only if Claude Code stores its projects elsewhere. |

## Requirements

`python3` on `PATH` (used for filesystem-aware slug decoding and for
manage-mode deletion). The `claude` CLI on `PATH`, logged in, is required
only for the Consolidate feature — everything else works without it.

## Tests

```bash
./run-tests.sh
```

Two suites: `pytest` over the Python scripts (needs `pytest`), and Qt's
`qmltestrunner` over `logic.js` (needs `qt6-declarative`, which the shell
already pulls in). They cover the rules the plugin can't afford to get
wrong — slug decoding, filename safety, `MEMORY.md` parsing and rewriting,
and the consolidation plan's accounting invariant, which is enforced twice
over: once in `logic.js` before a plan is offered for review, once in
`consolidate_plan.py` before anything is written. The panel's bindings,
layout and `Process` wiring aren't tested; there are no decisions in them.

## License

MIT — see [LICENSE](LICENSE).
