# tmux focus-events + declarative config migration

**Date:** 2026-07-02
**Status:** Approved

## Goal

Enable tmux focus-event forwarding (`focus-events on`) so applications running
inside panes — chiefly nvim — receive terminal `FocusGained`/`FocusLost`
events. While adding it, migrate the entire external `~/repos/dotfiles/tmux.conf`
into the declarative `programs.tmux` block in `home/john/home.nix`, eliminating
the `source-file` indirection so the flake is the single source of truth for
tmux configuration.

## Context

- tmux is managed by the home-manager `programs.tmux` module (the one exposing
  `secureSocket`, `plugins`, `clock24`).
- The pinned home-manager (`b1f916b`) exposes a native `focusEvents` option that
  defaults to `off`, and nothing in the current config overrides it. It is
  currently **off** — this is a real change. Set `focusEvents = true` rather
  than a raw `set -g focus-events on` in `extraConfig`, per the idiomatic
  mapping.
- Current `extraConfig` does nothing but `source-file ${homeDir}/repos/dotfiles/tmux.conf`.
- The `cpu` and `battery` tmux plugins are already declared; the status bar
  depends on the `battery` plugin's format strings.

## Approach

**Idiomatic migration.** Translate every external setting that has a native
home-manager option into that option; put the remainder (colors, status bar,
custom binds) into `extraConfig`; add `set -g focus-events on`; drop the
`source-file` line.

### External line → native option mapping

| External `tmux.conf` | Becomes |
|---|---|
| `set-option -g prefix C-a`, `bind-key C-a last-window`, `bind-key a send-prefix` | `shortcut = "a"` |
| `set-window-option -g mode-keys vi` | `keyMode = "vi"` |
| `bind h/j/k/l select-pane` | `customPaneNavigationAndResize = true` |
| `set -g base-index 1` | `baseIndex = 1` |
| `set -s escape-time 0` | `escapeTime = 0` |
| `setw -g aggressive-resize on` | `aggressiveResize = true` |
| *(new)* `focus-events on` | `focusEvents = true` |

### Stays in `extraConfig` (no native option)

- Solarized status colors + window-status / display-panes / clock styling
- Status bar (`status-left`, `status-interval`, `status-right` with battery)
- Custom split binds using `#{pane_current_path}` (`v`, `b`, `"`, `%`, `c`)
- Vi copy-mode selection binds (`v` begin-selection, `y` copy-selection)
- `bind m` main-horizontal 60% layout
- `bind C` named-new-window prompt
- `bind r` reload (`source-file ~/.config/tmux/tmux.conf`)
- `set-window-option -g automatic-rename on`

## Deliberate behavior changes

These are accepted consequences of the idiomatic mapping, not accidents:

1. **`H/J/K/L` pane-resize binds are added** — `customPaneNavigationAndResize`
   emits both the `hjkl` select-pane binds (which the external had) and `HJKL`
   resize-pane binds (which it did not). A bonus, not present today.
2. **`unbind C-b`** is emitted by `shortcut = "a"` — harmless; C-b was never the
   configured prefix here anyway.
3. **`status-keys` becomes `vi`** — `keyMode = "vi"` sets both `mode-keys` and
   `status-keys`; the external only set `mode-keys`. Affects command-prompt line
   editing. Expected for a vi-mode setup.
4. **`status-left` written as `""`** instead of `''` — behavior-identical
   (tmux treats both as empty), chosen to avoid Nix indented-string quote
   escaping. Purely a representation change.

## Non-goals

- No change to `terminal` (`screen-256color` stays; focus-events need no
  terminal-override).
- No nixvim change. nvim handles focus autocmds natively; configuring *what*
  nvim does on focus (autosave, autoread) is a separate follow-up.
- No change to the external `~/repos/dotfiles/tmux.conf` file itself (the flake
  simply stops sourcing it; the file can be removed by the user later).

## Verification

After `nixos-rebuild switch` (or the darwin equivalent) and starting a fresh
tmux server:

- `tmux show-options -g focus-events` reports `on`.
- `tmux show-options -g prefix` reports `C-a`.
- `tmux show-options -g mode-keys` reports `vi`.
- `tmux show-options -g base-index` reports `1`.
- Prefix `v` / `b` still split in the current path; `bind r` still reloads.
- In nvim inside tmux, `:autocmd FocusLost` fires when switching away (or set
  `autoread` and edit the file externally to confirm reload on refocus).
