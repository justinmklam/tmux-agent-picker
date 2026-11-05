# Repository guidance

## Purpose

This repository contains a tmux popup that lists pi agents across all tmux sessions. It also provides a zoxide-backed directory picker and a pi extension that reports agent lifecycle state.

Keep the implementation small and shell-first. Do not add a daemon, compiled component, or screen-scraping integration unless the scope is explicitly expanded.

## Repository layout

- `bin/agent-state` — best-effort tmux pane state writer. It supports `set`, `seen`, and `clear`.
- `bin/agent-pick` — agent listing and modal fzf picker.
- `bin/agent-new` — zoxide directory picker and switch-or-create session logic.
- `pi/agent-state.ts` — pi lifecycle extension for the root TUI session.
- `tmux/tmux-agent-picker.tmux.conf` — tmux binding and focus hooks.
- `theme/catppuccin-mocha.tmux.conf` — active theme values consumed by tmux and both fzf pickers.
- `tests/run.sh` — end-to-end shell test harness using a private tmux server and zoxide data directory.
- `README.md` — user installation, state model, theming, and integration documentation.
- `.ai/` — implementation plans and completed plans. Do not rewrite completed plans.

## Development workflow

1. Inspect the relevant script, tmux configuration, and nearby tests before editing.
2. For behavior changes, add or update a focused test in `tests/run.sh` before changing implementation code.
3. Run the complete test suite:

   ```sh
   bash tests/run.sh
   ```

4. Run shell syntax checks:

   ```sh
   bash -n bin/* \
     tests/run.sh
   ```

5. If `shellcheck` is installed, run it against `bin/*` and `tests/run.sh`. Do not claim ShellCheck validation when it is unavailable.
6. After tmux configuration changes, reload the active configuration and verify the binding and hooks:

   ```sh
   tmux source-file ~/.tmux.conf
   tmux list-keys -T prefix a
   for h in pane-focus-in after-select-pane after-select-window client-session-changed; do
     tmux show-hooks -g "$h" | grep -c "bin/agent-state"
   done
   ```

The test harness must use a private tmux server, `TMUX_TMPDIR`, and `_ZO_DATA_DIR`. Do not let tests modify the user's tmux server or zoxide history. Start private tmux servers with `-f /dev/null` so the user's `~/.tmux.conf` does not affect test setup.

## Implementation conventions

### State reporting

- Pane options are `@ap_agent`, `@ap_state`, and `@ap_since`.
- Valid states are `working`, `blocked`, `done`, and `idle`.
- Agent names must match `^[a-z0-9_-]{1,16}$`.
- `agent-state` is deliberately best-effort: it must always exit 0 and print nothing.
- Repeated `set` calls must not refresh `@ap_since`.
- `seen` changes only `done` to `idle` and preserves `@ap_since`.
- Calls from the pi extension must remain serialized so lifecycle events cannot land out of order.
- The extension reports only for the root pi TUI session. Do not make sub-agents overwrite the visible pane state.

### Picker behavior

- Agent order is state tier (`blocked`, `done`, `idle`, `working`), then newest `@ap_since` within a tier.
- Bare shell foreground commands (`zsh`, `bash`, `fish`, and `sh`) are hidden as stale panes.
- Every client switch must target the client passed to the popup with `switch-client -c`.
- Keep user paths out of fzf action text. Use fzf placeholders and its quoting for `{q}` and `{}`.
- Preserve the modal behavior: `n` opens the directory picker, `/` enters filter mode, and Esc first leaves filter mode and then closes or returns to the previous picker.
- Use `exec fzf` and process substitution so picker transitions do not leave waiting shells behind.

### Theme changes

The active theme is `theme/catppuccin-mocha.tmux.conf`. It defines:

- `@ap_fzf_colors` — fzf `--color` syntax.
- `@ap_popup_style` — tmux popup foreground and background style.
- `@ap_popup_border_style` — tmux popup border style.

Both picker scripts read `@ap_fzf_colors` from tmux. The tmux binding reads the two popup style options. Add or switch themes by changing the sourced theme file in `tmux/tmux-agent-picker.tmux.conf`; do not duplicate palette values in the scripts.

### Configuration boundaries

- Do not edit taw-managed files such as `taw-agent-state.ts`.
- Keep the pi extension additive and compatible with existing pi extensions.
- Keep the tmux hook index stable so re-sourcing replaces hooks instead of stacking duplicates.
- Do not change `~/.tmux.conf` or `~/.pi/agent/extensions/` unless the requested change includes installation or configuration updates.

## Documentation

Keep `README.md` synchronized with command names, paths, theme options, state meanings, and installation steps. Preserve exact commands and paths when editing technical documentation. Document unverified integrations as unverified examples.

## Scope and safety

- Do not commit, push, or rewrite history unless explicitly asked.
- Do not print or commit secrets, credentials, or `.env` contents.
- Do not use destructive tmux, cloud, or data-deletion commands without confirmation.
- Prefer targeted edits and leave no scratch files behind.
