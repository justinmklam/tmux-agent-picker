# tmux agent picker

## Install

Add this line to `~/.tmux.conf`, after the plugin block:

```tmux
source-file ~/Documents/personal/tmux-agent-picker/tmux/tmux-agent-picker.tmux.conf
```

Reload tmux:

```sh
tmux source-file ~/.tmux.conf
```

Install the pi extension symlink:

```sh
ln -s ~/Documents/personal/tmux-agent-picker/pi/agent-state.ts ~/.pi/agent/extensions/agent-state.ts
```

In a running pi, run `/reload` so pi loads the extension. Press `prefix + a` to open the picker.

Check the binding and focus hooks with:

```sh
tmux list-keys -T prefix a
for h in pane-focus-in after-select-pane after-select-window client-session-changed; do
  tmux show-hooks -g "$h" | grep -c "agent-state seen"
done
```

To uninstall, remove the `source-file` line from `~/.tmux.conf`, reload tmux, remove the pi symlink, and run `/reload` in pi:

```sh
rm ~/.pi/agent/extensions/agent-state.ts
tmux source-file ~/.tmux.conf
```

The picker does not remove directories from zoxide. If you want to remove one, run `zoxide remove <directory>` yourself.

## Theming

The active theme is defined in:

```text
~/Documents/personal/tmux-agent-picker/theme/catppuccin-mocha.tmux.conf
```

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

The picker sorts agent rows by state tier (`blocked`, `done`, `idle`, `working`) and then by newest `@ap_since` within each tier. Sessions without a visible stateful agent pane appear once as `session <name>` rows after the agent rows; selecting one switches to that session's active pane. The pane focus hooks call `bin/agent-state seen` when you look at a pane. That changes `done` to `idle` without changing `@ap_since`, so the agent keeps its original finished-time position among idle agents.

The list hides panes whose foreground command is a bare shell (`zsh`, `bash`, `fish`, or `sh`). This removes stale agent rows after an agent exits without reporting `clear`; ordinary sessions are listed regardless of what their panes are running. A pane running another program can still retain stale state until you clear it.

## Adding an agent

### The contract

From a process running inside the agent's tmux pane, call the following command on each lifecycle event:

```sh
~/Documents/personal/tmux-agent-picker/bin/agent-state set <agent> <state>
```

Call this when the agent exits:

```sh
~/Documents/personal/tmux-agent-picker/bin/agent-state clear
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

Use the agent's own hook, plugin, or extension system. `pi/agent-state.ts` is the reference implementation: it gates on the root TUI session, serializes calls, and uses the absolute path to the state script. Put a new integration in `~/Documents/personal/tmux-agent-picker/<agent>/`, next to `pi/`.

### Claude Code example — unverified example

This is an unverified example for `~/.claude/settings.json`. Adapt its hook event payload and notification variables to your Claude Code version:

```json
{
  "hooks": {
    "UserPromptSubmit": [{"hooks":[{"type":"command","command":"~/Documents/personal/tmux-agent-picker/bin/agent-state set claude working"}]}],
    "PostToolUse": [{"hooks":[{"type":"command","command":"~/Documents/personal/tmux-agent-picker/bin/agent-state set claude working"}]}],
    "PostToolUseFailure": [{"hooks":[{"type":"command","command":"~/Documents/personal/tmux-agent-picker/bin/agent-state set claude working"}]}],
    "Notification": [{"hooks":[{"type":"command","command":"~/Documents/personal/tmux-agent-picker/bin/agent-state set claude blocked"}]}],
    "Stop": [{"hooks":[{"type":"command","command":"~/Documents/personal/tmux-agent-picker/bin/agent-state set claude done"}]}],
    "StopFailure": [{"hooks":[{"type":"command","command":"~/Documents/personal/tmux-agent-picker/bin/agent-state set claude done"}]}],
    "SessionEnd": [{"hooks":[{"type":"command","command":"~/Documents/personal/tmux-agent-picker/bin/agent-state clear"}]}]
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
~/Documents/personal/tmux-agent-picker/bin/agent-state set myagent blocked
sleep 60
```

From another pane, run:

```sh
~/Documents/personal/tmux-agent-picker/bin/agent-pick --list
```

Look for the `myagent` row. A pane whose foreground process is a bare shell is hidden, so use the check while the agent (or `sleep 60`) holds the pane. Paste the pane id printed earlier when you clean up from another pane; for example:

```sh
~/Documents/personal/tmux-agent-picker/bin/agent-state clear %42
```
