# Development

Technical details for tmux-agent-picker: how state is stored, how to theme the pickers, and how to work on a checkout. To integrate another agent, see [AGENT_SUPPORT.md](AGENT_SUPPORT.md).

- [How it works](#how-it-works)
- [Repository layout](#repository-layout)
- [State model](#state-model)
- [Picker behavior](#picker-behavior)
- [Theming](#theming)
- [Development commands](#development-commands)
- [Developing against a TPM install](#developing-against-a-tpm-install)
- [Direct checkout installation](#direct-checkout-installation)
- [Uninstall details](#uninstall-details)
- [Troubleshooting](#troubleshooting)

## How it works

There is no daemon and no screen scraping. Agents write state into pane-scoped tmux options; the picker reads those options with `tmux list-panes` and builds the fzf list in a single pass. Panes without state are also inspected for an agent process, so agents without an integration still appear.

- `bin/agent-state` is the writer. Agents call it on lifecycle events, and the focus hooks call it when you look at a pane.
- `bin/tmux-agent-picker` is the entry point. `tmux-agent-picker hook|install|status|uninstall|pick|new|state` dispatches to the `bin/agent-*` scripts, so hook configs and docs can name one command instead of a checkout path.
- `bin/agent-install` installs, refreshes, reports, and removes the lifecycle integration for named agents, and links the dispatcher into `~/.local/bin`.
- `bin/agent-pick` is the reader and modal picker. It lists agent panes, sorts them, colours them, and runs fzf.
- `bin/agent-new` is the zoxide directory picker reachable with `n` from the agent picker.
- `agents/pi/agent-state.ts` is the reference lifecycle integration. It reports only for the root pi TUI session, serializes calls, and resolves the state script relative to the extension checkout.
- `tmux-agent-picker.tmux` is the TPM entrypoint. It exports `TMUX_AGENT_PICKER_ROOT` and sources the tmux configuration.

The binding and hooks expand `$TMUX_AGENT_PICKER_ROOT` when the entrypoint is sourced, so configuration changes need a tmux reload. Scripts under `bin/` do not: every invocation runs the script fresh.

## Repository layout

| Path | Purpose |
| --- | --- |
| `bin/agent-state` | Best-effort pane state writer (`set`, `seen`, `clear`). |
| `bin/tmux-agent-picker` | Dispatcher: `hook`, `install`, `status`, `uninstall`, `pick`, `new`, `state`. |
| `bin/agent-hook` | Agent hook wrapper mapping `<agent> <verb>` payloads to `bin/agent-state` writes. |
| `bin/agent-install` | Installs, refreshes, reports, and removes agent lifecycle integrations for the selected agents. |
| `bin/agent-pick` | Agent listing and modal fzf picker. |
| `bin/agent-new` | zoxide directory picker and switch-or-create session logic. |
| `agents/pi/agent-state.ts` | pi lifecycle extension for the root TUI session. |
| `agents/claude/settings.hooks.json` | Mergeable Claude Code hook block. |
| `agents/codex/hooks.json` | Codex CLI user-level hook file. |
| `agents/copilot/hooks.json` | GitHub Copilot CLI user-level hook file. |
| `agents/agy/` | agy plugin manifest, hook mapping, and conversation-gated hook shim. |
| `tmux-agent-picker.tmux` | TPM plugin entrypoint. |
| `tmux/tmux-agent-picker.tmux.conf` | tmux binding and focus hooks. |
| `theme/catppuccin-mocha.tmux.conf` | Active theme values consumed by tmux and both fzf pickers. |
| `tests/run.sh` | End-to-end shell harness using a private tmux server and zoxide data directory. |
| `docs/` | Development docs, agent support docs, and the README screenshot. |

Keep the implementation small and shell-first. Do not add a daemon, compiled component, or screen-scraping integration.

## State model

State lives in pane-scoped tmux options:

| Option | Values | Meaning |
| --- | --- | --- |
| `@ap_agent` | `pi`, or another agent name | The agent shown in the list. |
| `@ap_state` | `working`, `blocked`, `done`, `idle` | The agent's current attention state. |
| `@ap_since` | Unix seconds | When the current state last changed. |

The four states tell you:

- **`blocked`** — the agent is waiting for your permission, answer, or other input. These agents appear first.
- **`working`** — the agent is actively handling a prompt.
- **`done`** — the agent finished a turn and needs your attention.
- **`idle`** — the agent is not running, or you have already looked at a finished agent.

Agent ordering puts the pane currently active in the client that opened the picker first. The default order for every other row is the normal state tier (`blocked`, `working`, `done`, `idle`), then newest `@ap_since` within a tier. The picker-local `Tab` toggle changes the remaining-row sort to `LC_ALL=C` session name ascending, then newest `@ap_since` within each session; a second `Tab` restores the default order. Session-only rows are included in the session grouping. The order mode is not persisted, and the current pane remains first in either mode. Sessions without a visible stateful agent pane appear once as `session <name>` rows; selecting one switches to that session's active pane.

The picker hides panes whose foreground command is a bare shell (`zsh`, `bash`, `fish`, or `sh`). This removes stale agent rows after an agent exits without reporting `clear`; ordinary sessions are listed regardless of what their panes are running. A pane running another program can still retain stale state until you clear it.

### `agent-state` commands

Run these from a process inside the agent's pane; the process inherits `TMUX_PANE`, so the command knows which pane to update. An explicit pane id can also be passed as the last argument for `seen` and `clear`.

```sh
bin/agent-state set <agent> <state>   # agent must match ^[a-z0-9_-]{1,16}$
bin/agent-state seen [pane]           # done -> idle, keeps @ap_since
bin/agent-state clear [pane]          # unset all three options
```

The command always exits 0, prints nothing, and does nothing when the state is repeated. Repeated `set` calls do not refresh `@ap_since`. It is safe to call on every lifecycle event and cannot break the agent.

`set` only accepts `working`, `blocked`, `done`, and `idle`; anything else, including an invalid agent name, is ignored. `seen` changes only `done` to `idle` and preserves `@ap_since`, so a finished agent keeps its original position among idle agents.

The tmux focus hooks call `bin/agent-state seen` on `pane-focus-in`, `after-select-pane`, `after-select-window`, and `client-session-changed`. They use hook index `77` so re-sourcing replaces the hooks instead of stacking duplicates. A process must report `done` itself; do not report `idle` immediately after `done`, or the pane will never show the attention state.

Shell integrations call `tmux-agent-picker hook <agent> <verb>` instead of calling `bin/agent-state` directly. Hook configs carry no checkout path: `tmux-agent-picker install` links the dispatcher at `~/.local/bin/tmux-agent-picker`, and the hook configs call it by name, so `~/.local/bin` must be on the `PATH` the agent inherits. A hook that must not depend on `PATH` can call `"$TMUX_AGENT_PICKER_ROOT/bin/tmux-agent-picker" hook <agent> <verb>`.

The installer recognises both the current `tmux-agent-picker hook <agent> ` command and the pre-rename `bin/agent-hook <agent> ` form, so reinstalling replaces old entries instead of leaving them orphaned. Keep both markers in `markers_for()` until you are willing to drop support for entries written before the rename.

The wrapper maps `session`, `prompt`, `permission`, `activity`, `stop`, `interrupt`, and `end` onto the state commands, ignores payloads carrying a subagent id (`agent_id` or `agentId`), skips `activity` when the pane is already `done` or `idle`, and holds a per-pane lock under `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-agent-picker` — falling back to `$HOME/.cache/tmux-agent-picker` when that directory is not writable — so lifecycle events cannot land out of order. It always exits 0 and prints nothing.

Which lifecycle events an integration should report is documented in [AGENT_SUPPORT.md](AGENT_SUPPORT.md#lifecycle-events).

## Picker behavior

- Every client switch targets the client passed to the popup with `switch-client -c`.
- User paths stay out of fzf action text; the picker uses fzf placeholders and its quoting for `{q}` and `{}`.
- Picker transitions use `exec fzf` and process substitution so no waiting shells are left behind.
- Agent order puts the current client pane first; the default view uses the normal state tier and newest `@ap_since` ordering, while `Tab` toggles the remaining rows to alphabetical session and newest-within-session ordering.
- `j`/`k` and Up/Down navigation wrap from either end of the list.
- A changed query restarts the cursor at the first row (`change:first`) so filtering never keeps a stale cursor position.
- The list reloads after an action without closing the picker.

Keys:

| Key | Action |
| --- | --- |
| `Enter` | Go to the selected agent or session. |
| `j` / `k` or Up/Down | Move the cursor down / up; navigation wraps at either end. |
| `Tab` | Toggle between the default state/newest order and alphabetical session/newest-within-session order; the mode is picker-local. |
| `n` | Open the directory picker and switch to or create that session. |
| `x` | Kill the session under the cursor. The prompt reads `kill session <name>? [y/N]` and only `y` or `Y` kills it. The session running the picker is refused so the popup cannot destroy itself. |
| `/` | Enter filter mode; `n` and `x` type normally there. Typing restarts the cursor at the first row. |
| `q` / `Esc` | Close the picker. `Esc` first clears the query and leaves filter mode. |

Killing a session terminates every window and pane in it, including unsaved work. The list reloads afterwards and keeps the picker open.

The directory picker (`n`) lists zoxide directories, switches to a session whose path matches the selection, and otherwise creates a session named after the directory, adding `-2`, `-3`, … on name collisions. Absolute paths, `~`/`~/...`, and explicit `.`/`./...` or `..`/`../...` queries are opened directly; other text is fuzzy-matched against the listed directories, so a query such as `.pi/agent` can select the displayed `~/.pi/agent` row. `Esc` returns to the agent picker. The picker does not remove directories from zoxide; run `zoxide remove <directory>` yourself.

### Detected agents

A pane without any `@ap_state` value is inspected for an agent process, so agents that have no lifecycle integration still appear in the list. One `ps -A -o pid=,ppid=,command=` snapshot serves the whole listing, and detection tries three sources in order:

1. `#{pane_current_command}` — the foreground process name, which matches native binaries such as `claude`.
2. The pane's command line from the snapshot, which matches shims such as `node …/codex/bin/codex.js`.
3. Processes below the pane PID, stopping two levels down, which matches shell wrappers that `exec` or background an agent.

Each source is split on whitespace and `/`, and a token is compared exactly against the agent name list after stripping a trailing `.js`, `.mjs`, `.cjs`, `.py`, or `.exe`. The built-in list is `claude codex copilot agy gemini aider opencode goose crush cursor-agent`. Extend or replace it with a tmux option:

```tmux
set -g @ap_detect_agents '+my-agent'                          # built-in list plus my-agent
set -g @ap_detect_agents 'claude codex copilot agy my-agent'  # exactly these names
```

`on` (or no option at all) selects the built-in list. A leading `+` appends the remaining names to the built-in list, so `+my-agent` keeps every default; a plain list replaces it, so a name you leave out stops being detected. To switch detection off entirely, so the picker lists only panes that report state:

```tmux
set -g @ap_detect_agents 'off'
```

`off` skips process inspection completely — no `ps` call, no name matching — and cannot be used as an agent name. Any other value is treated as a name list. The option is read on each listing, so a change applies to the next popup without reloading tmux.

A detected pane is reported as `idle` with an age of `-`, because no process wrote a state for it. An explicit `@ap_state` always wins, including a stale value, so a pane never appears twice.

**Detection limits**

- Detection cannot report `blocked`, `working`, or `done`, and it has no age. Install a lifecycle integration for accurate state.
- A path or argument token that happens to equal an agent name can produce a false positive; narrow `@ap_detect_agents` to a plain list so only the names you trust are detected.
- Without `ps`, only `#{pane_current_command}` is matched; command-line and child-process detection are skipped.
- Detection runs only for panes without `@ap_state`, and the process snapshot is taken once per listing, so the cost stays near one `ps` call regardless of pane count. `@ap_detect_agents 'off'` removes even that call.

For agents whose process name never appears, see the wrapper-script fallback in [AGENT_SUPPORT.md](AGENT_SUPPORT.md#agents-without-hooks).

**Limitations**

- The list hides panes whose foreground command is a bare shell, not arbitrary long-running programs. A shell pane is still listed when an agent is detected in its command line or children.
- A pane running something other than the agent can retain stale state until `clear`.
- The pi extension reports only for the root pi TUI session. Sub-agents and RPC/print sessions do not overwrite the visible pane state.

## Theming

The active theme is `theme/catppuccin-mocha.tmux.conf`; substitute your install path. It defines four tmux options:

- `@ap_fzf_colors` — fzf `--color` syntax, read by both pickers.
- `@ap_session_colors` — an ordered, space-separated `#RRGGBB` palette for session-name truecolour accents in the agent picker.
- `@ap_popup_style` — tmux popup foreground and background style, read by the binding.
- `@ap_popup_border_style` — tmux popup border style, read by the binding.

The agent picker assigns session-name colours per render from the ordered `@ap_session_colors` palette. All rows belonging to one session use the same colour during that render, while distinct visible sessions receive evenly spread palette entries. Colours can change when the visible session set changes, and uniqueness is guaranteed only up to the palette length. Invalid palette tokens are ignored; if the option is missing or no valid tokens remain, session names are uncoloured. Custom themes should provide a compatible space-separated `#RRGGBB` list.

Edit those options in the theme file, then reload tmux:

```sh
tmux source-file ~/.tmux.conf
```

To add another theme, copy the file, change the four options, and update the `source-file` line in `tmux/tmux-agent-picker.tmux.conf`. Do not duplicate palette values in the scripts.

## Development commands

```sh
make test    # end-to-end harness on a private tmux server and zoxide data dir
make check   # bash -n parse check, plus shellcheck when it is installed
make reload  # tmux source-file ~/.tmux.conf
bin/agent-install --status  # report agent integrations without writing
bin/agent-install --link    # put tmux-agent-picker on PATH without installing hooks
tmux-agent-picker status    # the same report, once the dispatcher is on PATH
```

Run `make help` to list every target. `make test` never touches your real tmux server, sessions, or zoxide history.

For behaviour changes, add or update a focused test in `tests/run.sh` first. The harness must use a private tmux server, `TMUX_TMPDIR`, and `_ZO_DATA_DIR`; start private servers with `-f /dev/null` so the user's `~/.tmux.conf` does not affect setup.

The installer tests run against an isolated home and override `HOME`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and `COPILOT_HOME`, so they never read or write your real agent config. Keep that isolation when adding cases: a test that omits one of these variables will fall back to your home directory.

### What to reload for each change

| Changed file | Action |
| --- | --- |
| `bin/agent-pick`, `bin/agent-new`, `bin/agent-state`, `bin/agent-install`, `bin/tmux-agent-picker` | Nothing. Each invocation runs the script fresh, so reopening the popup or rerunning the installer picks up the change. |
| `tmux/tmux-agent-picker.tmux.conf`, `theme/*.conf` | `tmux source-file ~/.tmux.conf`, or source the plugin entrypoint directly. |
| `tmux-agent-picker.tmux` | `tmux source-file ~/.tmux.conf`. It re-exports `TMUX_AGENT_PICKER_ROOT`, which the binding and hooks capture at source time. |
| `agents/pi/agent-state.ts` | `/reload` in pi. |
| Anything | `make test`. |

### Verify the tmux integration

```sh
tmux list-keys -T prefix a
for h in pane-focus-in after-select-pane after-select-window client-session-changed; do
  tmux show-hooks -g "$h" | grep -c "bin/agent-state"
done
```

## Developing against a TPM install

You can keep the normal `@plugin` line and still edit a working checkout without reinstalling. TPM treats a plugin as installed when `$TMUX_PLUGIN_MANAGER_PATH/tmux-agent-picker` exists and contains a git remote, so a symlink from that directory to your checkout satisfies the check and tmux reads your live files on every reload.

Move any TPM-managed copy aside first. Do not create the symlink inside an existing clone:

```sh
checkout=~/Documents/tmux-agent-picker   # replace with your checkout
plugin_dir=$(tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH | cut -d= -f2-)
mv "$plugin_dir/tmux-agent-picker" "$plugin_dir/tmux-agent-picker.bak" 2>/dev/null
ln -s "$checkout" "$plugin_dir/tmux-agent-picker"
ln -sf "$checkout/agents/pi/agent-state.ts" ~/.pi/agent/extensions/agent-state.ts
```

Keep the `set -g @plugin` line and TPM `run` line in `~/.tmux.conf`, then reload tmux and run `/reload` in pi. TPM reports the plugin as already installed and never clones over your checkout.

### TPM commands to avoid while developing

- `prefix + U` runs `git pull` inside the plugin directory, which is now your checkout. It is harmless when the branch is clean and in sync, but it can fail or conflict on a dirty tree with upstream commits. Pull manually instead.
- `prefix + alt + u` skips the plugin while its `@plugin` line is present. If you remove that line and clean, TPM removes the symlink only, not the checkout, but you have to recreate the link.

To validate the real TPM install and clone path without disturbing this setup, use a throwaway server with its own plugin directory, then run TPM's install in that server's config:

```sh
tmux -L tpmtest -f /dev/null new-session -d \; \
  set-environment -g TMUX_PLUGIN_MANAGER_PATH /tmp/tpmtest-plugins
```

## Direct checkout installation

For a checkout that is not managed by TPM, place it at `~/.config/tmux-agent-picker` or another directory of your choice. Add these lines to `~/.tmux.conf` after the plugin block, replacing the path if needed:

```tmux
set-environment -g TMUX_AGENT_PICKER_ROOT "$HOME/.config/tmux-agent-picker"
source-file "$HOME/.config/tmux-agent-picker/tmux/tmux-agent-picker.tmux.conf"
```

Then reload tmux and create the pi extension symlink from that checkout:

```sh
tmux source-file ~/.tmux.conf
ln -s ~/.config/tmux-agent-picker/agents/pi/agent-state.ts ~/.pi/agent/extensions/agent-state.ts
```

Run `/reload` in pi. To remove a direct checkout, remove its `set-environment` and `source-file` lines, then run the cleanup commands in [Uninstall details](#uninstall-details) without removing an `@plugin` line.

Paths with spaces are supported; for compatibility with tmux and fzf command parsing, avoid parentheses, quotes, dollar signs, hash signs, and backticks in the install path.

## Uninstall details

Remove the `@plugin` line from `~/.tmux.conf`, then remove the active binding and hooks before reloading the file. This order lets any personal `prefix + a` binding in `~/.tmux.conf` be restored by the reload:

```sh
tmux unbind-key -T prefix a
tmux set-hook -gu 'pane-focus-in[77]'
tmux set-hook -gu 'after-select-pane[77]'
tmux set-hook -gu 'after-select-window[77]'
tmux set-hook -gu 'client-session-changed[77]'
tmux set-environment -gu TMUX_AGENT_PICKER_ROOT
tmux source-file ~/.tmux.conf
rm ~/.pi/agent/extensions/agent-state.ts
```

Run `/reload` in pi after removing the symlink. Restarting the tmux server instead also removes the binding and hooks. The `@ap_*` theme options remain set, and `focus-events` remains enabled, until the tmux server restarts. If this installation exclusively enabled them, unset the theme options with `tmux set -gu @ap_fzf_colors`, `tmux set -gu @ap_session_colors`, `tmux set -gu @ap_popup_style`, and `tmux set -gu @ap_popup_border_style`; leave `focus-events` unchanged if other configuration uses it.

After reloading, press `prefix + alt + u` to ask TPM to clean the removed plugin, or delete its directory under `$TMUX_PLUGIN_MANAGER_PATH` manually.

## Troubleshooting

- **Popup opens but the list is empty** — check that an agent is holding its pane (a pane whose foreground command is a bare shell is hidden) and that state options are set: `tmux display-message -p -t "$TMUX_PANE" '#{@ap_agent} #{@ap_state}'`.
- **`prefix + a` does nothing** — source `~/.tmux.conf` again; the binding is a `run-shell` command that expands `$TMUX_AGENT_PICKER_ROOT` at source time.
- **No pi state updates** — confirm the extension is linked in `~/.pi/agent/extensions/` and run `/reload` in pi.
