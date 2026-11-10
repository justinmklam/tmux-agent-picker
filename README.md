# tmux agent picker

Yet another agent picker, but this one is simple and mine, and does just what I need it to do. Written in bash in just a few hundred lines of code.

![tmux agent picker popup listing agents by state, with a pane preview](docs/screencap.png)

Press `prefix + a` for a list with the current client pane first, followed by every other row in the normal state order: blocked agents at the top, then working, done, and idle, with newest rows first within each group. Press `Tab` to toggle to alphabetically sorted (`LC_ALL=C`) session groups with newest rows first within each session. `Enter` jumps to the pane. `n` opens a zoxide-backed directory picker to switch to or create a session without leaving the popup.

- **See what needs attention** — state, agent, session, and age in one line per agent.
- **Jump straight to the work** — selecting a row switches your client to that pane and window.
- **Filter or clean up** — `/` filters, `x` kills the session under the cursor.
- **Any agent** — pi reports state out of the box; other agents are detected from their process, and any agent can report state with a single command.

## Supported agents

Every agent below is matched by name — as the foreground process name, or as a token in the pane's command line. Agents without state reporting appear as `idle` with an age of `-`; agents with reporting also show `blocked`, `working`, and `done`. pi reports through the bundled extension, so it does not rely on detection.

| Agent | Process detection | Built-in state reporting |
| --- | --- | --- |
| pi | — | ✓ bundled extension |
| claude | ✓ | [✓ hooks](docs/AGENT_SUPPORT.md#claude-code) |
| codex | ✓ | [✓ hooks](docs/AGENT_SUPPORT.md#codex-cli) |
| copilot | ✓ | [✓ hooks](docs/AGENT_SUPPORT.md#github-copilot-cli) |
| agy | ✓ | [✓ hooks](docs/AGENT_SUPPORT.md#agy-antigravity-cli) |
| gemini | ✓ | — |
| aider | ✓ | — |
| opencode | ✓ | — |
| goose | ✓ | — |
| crush | ✓ | — |
| cursor-agent | ✓ | — |

Detection uses a built-in name list. Replace it, add to it, or turn it off:

```tmux
set -g @ap_detect_agents '+my-agent'                      # built-in list plus my-agent
set -g @ap_detect_agents 'claude codex copilot my-agent'  # exactly these names
set -g @ap_detect_agents 'off'                            # no detection
```

A leading `+` adds names to the built-in list. A plain list replaces it, so any default name you leave out stops being detected.

Only pi and the agents with shipped hook blocks report lifecycle state out of the box. Any other agent can report state by calling `tmux-agent-picker hook` on its lifecycle events — see [docs/AGENT_SUPPORT.md](docs/AGENT_SUPPORT.md).

## Agent integrations

`tmux-agent-picker install` installs, refreshes, reports, and removes the lifecycle integration for the agents you name. Hook configs call the bare `tmux-agent-picker hook <agent> <verb>`, so the installer links the dispatcher at `~/.local/bin/tmux-agent-picker`; that directory must be on `PATH` in whatever environment starts the agent. The installer edits only the selected agents' user-level config, writes readable pretty-printed JSON, preserves unrelated settings, and copies an existing target to `<target>.bak.<timestamp>` before changing it. A repeated install reports `unchanged` and writes nothing.

The first install has to run as `bin/agent-install` from the plugin directory, because that is the command that creates the `PATH` link. After that both forms work:

```sh
bin/agent-install --all                      # first run, from the plugin directory
tmux-agent-picker install --all              # pi, claude, codex, copilot, and agy
tmux-agent-picker install pi claude          # only the named agents
tmux-agent-picker status                     # installed, partial, not installed, missing, or invalid
tmux-agent-picker uninstall --all            # remove only what this checkout installed
```

To put the dispatcher on `PATH` without installing any agent hooks — for example to run `tmux-agent-picker pick` or `tmux-agent-picker status` by hand — run the link on its own:

```sh
bin/agent-install --link
```

`tmux-agent-picker status` lists the link as the `cli` row.

Add `--dry-run` to print the planned changes and `--yes` to skip the confirmation prompt in scripts. The installer needs `jq` for the JSON-based agents and never changes hook trust, sandbox, or permission settings. Each agent needs a restart or reload before it picks up the integration:

| Agent | After installing |
| --- | --- |
| pi | Run `/reload` in pi. |
| Claude Code | Restart Claude Code. |
| Codex CLI | Trust the hooks under `Settings > Hooks`; see [Codex limits](docs/AGENT_SUPPORT.md#codex-cli). |
| Copilot CLI | Restart Copilot. Its sandbox must allow the hook command; see [Copilot limits](docs/AGENT_SUPPORT.md#github-copilot-cli). |
| agy | Confirm `agy plugin list` shows `tmux-agent-picker`. |

For a manual install without the helper, follow the per-agent steps in [docs/AGENT_SUPPORT.md](docs/AGENT_SUPPORT.md).

## Requirements

- tmux with `display-popup` support
- [fzf](https://github.com/junegunn/fzf)
- [zoxide](https://github.com/ajeetdsouza/zoxide) for the `n` directory picker
- [jq](https://jqlang.github.io/jq/) for `tmux-agent-picker install` (optional; needed to install or remove the JSON-based agents)
- `~/.local/bin` on `PATH` so agents can find the `tmux-agent-picker` dispatcher (required for hook-based lifecycle reporting)
- pi for the built-in lifecycle reporting (optional; any agent can report state)

## Install

Install [TPM](https://github.com/tmux-plugins/tpm), then add the plugin above TPM's bootstrap line in `~/.tmux.conf`:

```tmux
set -g @plugin 'justinmklam/tmux-agent-picker'
run '~/.tmux/plugins/tpm/tpm'
```

Reload tmux and press `prefix + I`:

```sh
tmux source-file ~/.tmux.conf
```

TPM does not install the pi extension, so install it separately. From the plugin directory, `bin/agent-install pi` creates the symlink and the dispatcher link, or you can link it by hand:

```sh
plugin_dir=$(tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH | cut -d= -f2-)
ln -s "$plugin_dir/tmux-agent-picker/agents/pi/agent-state.ts" ~/.pi/agent/extensions/agent-state.ts
```

Run `/reload` in pi, then press `prefix + a`.

> TPM normally installs to `~/.tmux/plugins/tmux-agent-picker`. If `TMUX_PLUGIN_MANAGER_PATH` points elsewhere, use that directory instead. For a non-TPM checkout, see [Direct checkout installation](docs/DEVELOPMENT.md#direct-checkout-installation).

## Usage

| Key | Action |
| --- | --- |
| `Enter` | Go to the selected agent or session |
| `j` / `k` or Up/Down | Move down / up; navigation wraps at either end |
| `Tab` | Toggle between state/newest order and alphabetically sorted (`LC_ALL=C`) session/newest order |
| `n` | Open the directory picker, then switch to or create that session |
| `x` | Kill the session under the cursor; confirms with `y`/`Y` |
| `/` | Filter mode; `n` and `x` type normally there |
| `q` / `Esc` | Close; `Esc` first clears the query and leaves filter mode |

### Agent states

| State | Meaning |
| --- | --- |
| `blocked` | Waiting for your permission, answer, or other input |
| `working` | Actively handling a prompt |
| `done` | Finished a turn and needs your attention |
| `idle` | Not running, or a finished agent you already looked at |

Rows put the pane currently active in the client that opened the picker first. The default view puts the remaining agent rows into the normal state order: `blocked`, `working`, `done`, `idle`, then newest first within each group. Pressing `Tab` switches to alphabetical session groups and sorts newest `@ap_since` first within each session; pressing it again restores the default view. The current pane remains first in either view, and the order mode lasts only for the current picker. Session-only rows participate in the alphabetical session order. Looking at a pane turns its `done` state into `idle` automatically, so finished agents keep their place in the list.

Agents detected from their process appear as `idle` with an age of `-`: the process name proves the agent is running, but it cannot report what it is doing.

## Uninstall

If you installed any agent integration with `tmux-agent-picker install`, remove those entries first:

```sh
tmux-agent-picker uninstall --all
```

Remove the `@plugin` line from `~/.tmux.conf`, then clear the binding and hooks before reloading:

```sh
tmux unbind-key -T prefix a
tmux set-hook -gu 'pane-focus-in[77]'
tmux set-hook -gu 'after-select-pane[77]'
tmux set-hook -gu 'after-select-window[77]'
tmux set-hook -gu 'client-session-changed[77]'
tmux set-environment -gu TMUX_AGENT_PICKER_ROOT
tmux source-file ~/.tmux.conf
rm -f ~/.pi/agent/extensions/agent-state.ts
rm -f ~/.gemini/config/plugins/tmux-agent-picker
rm -f ~/.local/bin/tmux-agent-picker
```

Run `/reload` in pi. Press `prefix + alt + u` in tmux to let TPM remove the plugin directory, or delete it under `$TMUX_PLUGIN_MANAGER_PATH` yourself. Restarting the tmux server also clears the binding, hooks, theme options, and `focus-events`.

## Development

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for architecture, state reporting, themes, and development workflows, and [docs/AGENT_SUPPORT.md](docs/AGENT_SUPPORT.md) for adding support for other agents.
