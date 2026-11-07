# Agent support

tmux-agent-picker works with any agent that can run a shell command on its lifecycle events. pi is supported out of the box; this page describes how to add another agent.

For state meanings and how the picker orders rows, see [State model](DEVELOPMENT.md#state-model).

## The contract

From a process running inside the agent's tmux pane, call this command on each lifecycle event. These examples use the TPM path; substitute your direct checkout path when using the [direct checkout installation](DEVELOPMENT.md#direct-checkout-installation):

```sh
~/.tmux/plugins/tmux-agent-picker/bin/agent-state set <agent> <state>
```

Call this when the agent exits:

```sh
~/.tmux/plugins/tmux-agent-picker/bin/agent-state clear
```

The process inherits `TMUX_PANE`, so the commands know which pane to update. The command always exits 0, prints nothing, and does nothing when the state is repeated. It is safe to call on every event and cannot break the agent. `<agent>` must match `^[a-z0-9_-]{1,16}$`; it appears in the list's agent column. There is nothing to register and you do not need to change `bin/agent-pick`.

`seen` is called by the tmux focus hooks, not by agent integrations. It changes only `done` to `idle` and preserves `@ap_since`.

## Lifecycle events

| Agent event | Report |
| --- | --- |
| You submit a prompt, or the agent resumes | `working` |
| The agent waits for a permission prompt or question | `blocked` |
| The turn finishes | `done` |
| The turn is aborted | `idle` |
| The process exits | `clear` |

Do not report `idle` after `done` yourself. The tmux focus hooks do that when you look at the pane, while keeping the original `@ap_since` value.

## Where to hook in

Use the agent's own hook, plugin, or extension system. `pi/agent-state.ts` is the reference implementation: it gates on the root TUI session, serializes calls so events cannot land out of order, and resolves the state script relative to the extension checkout. Put a new integration in `~/.tmux/plugins/tmux-agent-picker/<agent>/`, next to `pi/`; substitute your direct checkout path when using the fallback installation.

## Claude Code example — unverified example

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

## Agents without hooks

A shell wrapper can report `working` when it starts and `clear` on exit. It cannot report `blocked` or `done`, so treat that wrapper as a fallback, not full support.

## Check your integration

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
