# tmux agent picker

## Install with TPM

Install [TPM](https://github.com/tmux-plugins/tpm), then add the plugin declaration alongside your other `@plugin` lines in `~/.tmux.conf`, above TPM's bootstrap line. The TPM bootstrap line should remain last:

```tmux
set -g @plugin 'justinmklam/tmux-agent-picker'
run '~/.tmux/plugins/tpm/tpm'
```

Reload tmux, then press `prefix + I` to install the plugin:

```sh
tmux source-file ~/.tmux.conf
```

TPM installs the tmux integration under its plugin directory, normally `~/.tmux/plugins/tmux-agent-picker`. If your TPM installation uses a different `TMUX_PLUGIN_MANAGER_PATH`—for example with an XDG-based tmux configuration—substitute that directory in the paths below. TPM does not install the Pi extension, so create its symlink separately:

```sh
plugin_dir=$(tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH | cut -d= -f2-)
ln -s "$plugin_dir/tmux-agent-picker/pi/agent-state.ts" ~/.pi/agent/extensions/agent-state.ts
```

In a running pi, run `/reload`, then press `prefix + a` to open the picker.

Check the binding and focus hooks with:

```sh
tmux list-keys -T prefix a
for h in pane-focus-in after-select-pane after-select-window client-session-changed; do
  tmux show-hooks -g "$h" | grep -c "bin/agent-state"
done
```

To uninstall, remove the `@plugin` line from `~/.tmux.conf`, then remove the active binding and hooks before reloading the file. This order lets any personal `prefix + a` binding in `~/.tmux.conf` be restored by the reload:

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

After reloading, press `prefix + alt + u` to ask TPM to clean the removed plugin, or delete its directory under `$TMUX_PLUGIN_MANAGER_PATH` manually.

Run `/reload` in pi after removing the symlink. Restarting the tmux server instead also removes the binding and hooks. The `@ap_*` theme options remain set, and `focus-events` remains enabled, until the tmux server restarts. If this installation exclusively enabled them, you can unset the theme options with `tmux set -gu @ap_fzf_colors`, `tmux set -gu @ap_popup_style`, and `tmux set -gu @ap_popup_border_style`; leave `focus-events` unchanged if other configuration uses it.

## Direct checkout installation

For a checkout that is not managed by TPM, place it at `~/.config/tmux-agent-picker` or another directory of your choice. Add these lines to `~/.tmux.conf` after the plugin block, replacing the path if needed:

```tmux
set-environment -g TMUX_AGENT_PICKER_ROOT "$HOME/.config/tmux-agent-picker"
source-file "$HOME/.config/tmux-agent-picker/tmux/tmux-agent-picker.tmux.conf"
```

Then reload tmux and create the Pi extension symlink from that checkout:

```sh
tmux source-file ~/.tmux.conf
ln -s ~/.config/tmux-agent-picker/pi/agent-state.ts ~/.pi/agent/extensions/agent-state.ts
```

Run `/reload` in pi. To remove a direct checkout, remove its `set-environment` and `source-file` lines, then run the cleanup commands in the TPM uninstall section without removing an `@plugin` line. Paths with spaces are supported; for compatibility with tmux and fzf command parsing, avoid parentheses, quotes, dollar signs, hash signs, and backticks in the install path.

The picker does not remove directories from zoxide. If you want to remove one, run `zoxide remove <directory>` yourself.

## Developing against a TPM install

You can keep the normal `@plugin` line and still edit a working checkout without reinstalling. TPM treats a plugin as installed when `$TMUX_PLUGIN_MANAGER_PATH/tmux-agent-picker` exists and contains a git remote, so a symlink from that directory to your checkout satisfies the check and tmux reads your live files on every reload.

Move any TPM-managed copy aside first. Do not create the symlink inside an existing clone:

```sh
checkout=~/Documents/tmux-agent-picker   # replace with your checkout
plugin_dir=$(tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH | cut -d= -f2-)
mv "$plugin_dir/tmux-agent-picker" "$plugin_dir/tmux-agent-picker.bak" 2>/dev/null
ln -s "$checkout" "$plugin_dir/tmux-agent-picker"
ln -sf "$checkout/pi/agent-state.ts" ~/.pi/agent/extensions/agent-state.ts
```

Keep the `set -g @plugin` line and TPM `run` line in `~/.tmux.conf` as documented in the TPM install section, then reload tmux and run `/reload` in pi. TPM reports the plugin as already installed and never clones over your checkout.

### What to reload for each change

| Changed file | Action |
| --- | --- |
| `bin/agent-pick`, `bin/agent-new`, `bin/agent-state` | Nothing. Each invocation runs the script fresh, so reopening the popup picks up the change. |
| `tmux/tmux-agent-picker.tmux.conf`, `theme/*.conf` | `tmux source-file ~/.tmux.conf`, or source the plugin entrypoint directly. |
| `tmux-agent-picker.tmux` | `tmux source-file ~/.tmux.conf`. It re-exports `TMUX_AGENT_PICKER_ROOT`, which the binding and hooks capture at source time. |
| `pi/agent-state.ts` | `/reload` in pi. |
| Anything | `bash tests/run.sh`. The harness uses a private tmux server and zoxide data directory, so it does not touch your sessions. |

Configuration changes need a reload because the binding and hook commands expand `$TMUX_AGENT_PICKER_ROOT` when the plugin entrypoint is sourced. Scripts under `bin/` do not:

```sh
tmux source-file ~/.tmux.conf
```

### TPM commands to avoid while developing

- `prefix + U` runs `git pull` inside the plugin directory, which is now your checkout. It is harmless when the branch is clean and in sync, but it can fail or conflict on a dirty tree with upstream commits. Pull manually instead.
- `prefix + alt + u` skips the plugin while its `@plugin` line is present. If you remove that line and clean, TPM removes the symlink only, not the checkout, but you have to recreate the link.

To validate the real TPM install and clone path without disturbing this setup, use a throwaway server with its own plugin directory, then run TPM's install in that server's config:

```sh
tmux -L tpmtest -f /dev/null new-session -d \; \
  set-environment -g TMUX_PLUGIN_MANAGER_PATH /tmp/tpmtest-plugins
```

## Theming

The paths in the remaining examples use TPM's default `~/.tmux/plugins` directory. If TPM reports a different `TMUX_PLUGIN_MANAGER_PATH`, substitute that directory in each command and example.

The active theme is defined in:

```text
~/.tmux/plugins/tmux-agent-picker/theme/catppuccin-mocha.tmux.conf
```

For a direct checkout, substitute that checkout's `theme/` path.

Edit `@ap_fzf_colors` for fzf's color names `@ap_popup_style` for the tmux popup style, and `@ap_popup_border_style` for the popup border. Both pickers read the fzf option from tmux, so you only need to change this one file. After changing it, reload tmux:

```sh
tmux source-file ~/.tmux.conf
```

To add another theme, copy the file, change the three options, and update the `source-file` line in `tmux/tmux-agent-picker.tmux.conf`.

## How agent state works

The integration stores state in pane-scoped tmux options:

| Option | Values | Meaning |
| --- | --- | --- |
| `@ap_agent` | `pi`, or another agent name | The agent shown in the list. |
| `@ap_state` | `working`, `blocked`, `done`, `idle` | The agent's current attention state. |
| `@ap_since` | Unix seconds | When the current state last changed. |

The four states tell you:

- **`blocked`** — the agent is waiting for your permission, answer, or other input. These agents appear first.
- **`done`** — the agent finished a turn and needs your attention. These appear after blocked agents.
- **`idle`** — the agent is not running, or you have already looked at a finished agent. These appear after done agents.
- **`working`** — the agent is actively handling a prompt. These appear last.

The picker sorts agent rows by state tier (`blocked`, `working`, `done`, `idle`) and then by newest `@ap_since` within each tier. Sessions without a visible stateful agent pane appear once as `session <name>` rows after the agent rows; selecting one switches to that session's active pane. The pane focus hooks call `bin/agent-state seen` when you look at a pane. That changes `done` to `idle` without changing `@ap_since`, so the agent keeps its original finished-time position among idle agents.

The list hides panes whose foreground command is a bare shell (`zsh`, `bash`, `fish`, or `sh`). This removes stale agent rows after an agent exits without reporting `clear`; ordinary sessions are listed regardless of what their panes are running. A pane running another program can still retain stale state until you clear it.

## Adding an agent

### The contract

From a process running inside the agent's tmux pane, call the following command on each lifecycle event. These examples use the TPM path; substitute your direct checkout path when using the fallback installation:

```sh
~/.tmux/plugins/tmux-agent-picker/bin/agent-state set <agent> <state>
```

Call this when the agent exits:

```sh
~/.tmux/plugins/tmux-agent-picker/bin/agent-state clear
```

The process inherits `TMUX_PANE`, so the commands know which pane to update. The command always exits 0, prints nothing, and does nothing when the state is repeated. It is safe to call on every event and cannot break the agent. `<agent>` must match `^[a-z0-9_-]{1,16}$`; it appears in the list's agent column. There is nothing to register and you do not need to change `bin/agent-pick`.

### Map the agent events

| Agent event | Report |
| --- | --- |
| You submit a prompt, or the agent resumes | `working` |
| The agent waits for a permission prompt or question | `blocked` |
| The turn finishes | `done` |
| The turn is aborted | `idle` |
| The process exits | `clear` |

Do not report `idle` after `done` yourself. The tmux focus hooks do that when you look at the pane, while keeping the original `@ap_since` value.

### Where to hook in

Use the agent's own hook, plugin, or extension system. `pi/agent-state.ts` is the reference implementation: it gates on the root TUI session, serializes calls, and resolves the state script relative to the extension checkout. Put a new integration in `~/.tmux/plugins/tmux-agent-picker/<agent>/`, next to `pi/`; substitute your direct checkout path when using the fallback installation.

### Claude Code example — unverified example

This is an unverified example for `~/.claude/settings.json`. Adapt its hook event payload and notification variables to your Claude Code version:

```json
{
  "hooks": {
    "UserPromptSubmit": [{"hooks":[{"type":"command","command":"~/.tmux/plugins/tmux-agent-picker/bin/agent-state set claude working"}]}],
    "PostToolUse": [{"hooks":[{"type":"command","command":"~/.tmux/plugins/tmux-agent-picker/bin/agent-state set claude working"}]}],
    "PostToolUseFailure": [{"hooks":[{"type":"command","command":"~/.tmux/plugins/tmux-agent-picker/bin/agent-state set claude working"}]}],
    "Notification": [{"hooks":[{"type":"command","command":"~/.tmux/plugins/tmux-agent-picker/bin/agent-state set claude blocked"}]}],
    "Stop": [{"hooks":[{"type":"command","command":"~/.tmux/plugins/tmux-agent-picker/bin/agent-state set claude done"}]}],
    "StopFailure": [{"hooks":[{"type":"command","command":"~/.tmux/plugins/tmux-agent-picker/bin/agent-state set claude done"}]}],
    "SessionEnd": [{"hooks":[{"type":"command","command":"~/.tmux/plugins/tmux-agent-picker/bin/agent-state clear"}]}]
  }
}
```

This example does not yet verify whether `blocked` ends after approval or denial, or whether Esc interruption fires `Stop`. Those behaviors need checking before you rely on this mapping.

### Agents without hooks

A shell wrapper can report `working` when it starts and `clear` on exit. It cannot report `blocked` or `done`, so treat that wrapper as a fallback, not full support.

### Check your integration

In the agent's pane, save its pane id, set the state, and keep the agent process (or a temporary command) in the foreground:

```sh
pane=$TMUX_PANE
echo "$pane"
~/.tmux/plugins/tmux-agent-picker/bin/agent-state set myagent blocked
sleep 60
```

From another pane, run:

```sh
~/.tmux/plugins/tmux-agent-picker/bin/agent-pick --list
```

Look for the `myagent` row. A pane whose foreground process is a bare shell is hidden, so use the check while the agent (or `sleep 60`) holds the pane. Paste the pane id printed earlier when you clean up from another pane; for example:

```sh
~/.tmux/plugins/tmux-agent-picker/bin/agent-state clear %42
```
