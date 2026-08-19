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
manage-mode deletion).

## License

MIT — see [LICENSE](LICENSE).
