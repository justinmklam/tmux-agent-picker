# Agent support

tmux-agent-picker works with any agent that can run a shell command on its lifecycle events. pi is supported out of the box, agents without an integration are still detected from their process, and this page describes how to add lifecycle reporting for another agent.

For state meanings and how the picker orders rows, see [State model](DEVELOPMENT.md#state-model).

## The contract

From a process running inside the agent's tmux pane, call the shared wrapper on each lifecycle event. These examples use the TPM path; substitute your direct checkout path when using the [direct checkout installation](DEVELOPMENT.md#direct-checkout-installation):

```sh
~/.tmux/plugins/tmux-agent-picker/bin/agent-hook <agent> <verb>
```

The verbs are `session` (`idle`), `prompt` (`working`), `permission` (`blocked`), `activity` (`working`, skipped when the pane is already `done` or `idle`), `stop` (`done`), `interrupt` (`idle`), and `end` (cleared). The wrapper reads the agent's hook payload from stdin, ignores events from subagents, and serializes writes per pane. For a manual check you can still call the state writer directly:

```sh
~/.tmux/plugins/tmux-agent-picker/bin/agent-state set <agent> <state>
~/.tmux/plugins/tmux-agent-picker/bin/agent-state clear
```

The process inherits `TMUX_PANE`, so the commands know which pane to update. Both commands always exit 0, print nothing, and do nothing when the state is repeated. They are safe to call on every event and cannot break the agent. `<agent>` must match `^[a-z0-9_-]{1,16}$`; it appears in the list's agent column. There is nothing to register and you do not need to change `bin/agent-pick`.

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

Use the agent's own hook, plugin, or extension system. `agents/pi/agent-state.ts` is the reference implementation: it gates on the root TUI session, serializes calls so events cannot land out of order, and resolves the state script relative to the extension checkout. Put a new integration under `agents/`; substitute your direct checkout path when using the fallback installation.

## Claude Code

Claude Code reports its lifecycle through hooks in `~/.claude/settings.json`. Merge the block from [`agents/claude/settings.hooks.json`](../agents/claude/settings.hooks.json) into that file; the repository never writes to your home directory.

| Claude event | Reported state |
| --- | --- |
| `SessionStart` | `idle` |
| `UserPromptSubmit` | `working` |
| `PermissionRequest` | `blocked` |
| `PostToolUse` | `working` |
| `Stop` | `done` |
| `StopFailure` | `done` |
| `SessionEnd` | cleared |

### Install

1. Open `~/.claude/settings.json` and merge the `hooks` object from `agents/claude/settings.hooks.json` into its existing `hooks` key. Merge the event arrays; do not replace the file or an existing event array.
2. Confirm the plugin path. Each command uses `${TMUX_AGENT_PICKER_ROOT:-$HOME/.tmux/plugins/tmux-agent-picker}`; `TMUX_AGENT_PICKER_ROOT` is exported by the plugin, so a TPM install works without edits and a direct checkout resolves through that variable.
3. Restart Claude Code or start a new session so it reloads the settings.

### Uninstall

Remove the `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `Stop`, `StopFailure`, and `SessionEnd` entries that call `bin/agent-hook` from `~/.claude/settings.json`, then restart Claude Code.

### Limits

- Hooks fired inside a subagent carry `agent_id` and are ignored, so subagents never overwrite the state of the visible session.
- `Notification` is deliberately not mapped: it also fires for non-blocking messages and would flip a `working` pane to `blocked` spuriously.
- `PostToolUse` can arrive after `Stop`; the shared wrapper skips `activity` when the pane is already `done` or `idle`.
- The hook block depends on `TMUX_AGENT_PICKER_ROOT` or the default TPM path; a checkout in another directory needs the variable or an edited literal path.

## Codex CLI

Codex CLI reports its lifecycle through a user-level hook file. Copy [`agents/codex/hooks.json`](../agents/codex/hooks.json) to `~/.codex/hooks.json`, then trust the hooks in Codex.

| Codex event | Reported state |
| --- | --- |
| `SessionStart` | `idle` |
| `UserPromptSubmit` | `working` |
| `PermissionRequest` | `blocked` |
| `PostToolUse` | `working` |
| `Stop` | `done` |
| `Interrupt` | `idle` |
| `SessionEnd` | cleared |

### Install

1. Copy the file into place. If `~/.codex/hooks.json` already exists, merge the event arrays instead of replacing it.

   ```sh
   cp agents/codex/hooks.json ~/.codex/hooks.json
   ```

2. Open Codex settings and choose `Settings > Hooks`. Review and trust the `tmux-agent-picker` entries; Codex does not run unreviewed hooks.
3. Start a new Codex session inside tmux so its hooks inherit `TMUX_PANE`.

### Uninstall

Delete `~/.codex/hooks.json`, or remove the events that call `bin/agent-hook`, then re-run the hook review in Codex settings.

### Limits

- Hooks stay inactive when `[features] hooks = false` appears in `~/.codex/config.toml` or an admin `requirements.toml` restricts hook sources.
- `SessionEnd` and `Interrupt` are capped at 3 seconds; the shared wrapper finishes in a single `tmux set-option` plus an at-most-one-second lock wait.
- Subagent events are not subscribed. If a subagent `Stop` reaches this file, the `agent_id` gate keeps the pane state untouched.
- Command hooks receive the event JSON on stdin, which is what supplies the stop reason and the subagent id.

## GitHub Copilot CLI

Copilot CLI reports its lifecycle through a user-level hook file. Copy [`agents/copilot/hooks.json`](../agents/copilot/hooks.json) into `~/.copilot/hooks/`.

| Copilot event | Reported state |
| --- | --- |
| `sessionStart` | `idle` |
| `userPromptSubmitted` | `working` |
| `permissionRequest` | `blocked` |
| `postToolUse` | `working` |
| `postToolUseFailure` | `working` |
| `agentStop` | `done` |
| `errorOccurred` | `done` |
| `sessionEnd` | cleared |

### Install

```sh
mkdir -p ~/.copilot/hooks
cp agents/copilot/hooks.json ~/.copilot/hooks/tmux-agent-picker.json
```

When `COPILOT_HOME` is set, copy into `$COPILOT_HOME/hooks/` instead. Start a new Copilot CLI session inside tmux so its hooks inherit `TMUX_PANE`.

### Uninstall

```sh
rm ~/.copilot/hooks/tmux-agent-picker.json
```

### Limits

- `disableAllHooks` in Copilot settings turns reporting off.
- `/clear` fires `sessionEnd` and then `sessionStart`, so a cleared session returns to `idle`.
- `notification` is deliberately not mapped: it also fires for non-blocking messages.
- `errorOccurred` can fire mid-turn on a recoverable error and show `done` while the agent keeps working; the next `postToolUse` returns it to `working` unless the turn already finished.
- Repository-level hook files are not used here; they would additionally require workspace admission.
- Copilot runs hook commands inside its own sandbox. If that sandbox cannot start, hooks fail open and the pane keeps its detected `idle` row. On Linux, the sandbox needs `bubblewrap`, `slirp4netns`, user namespaces, and the rest of the documented prerequisites; setting `sandbox.enabled` to `false` in `~/.copilot/settings.json` also lets the hooks run, at the cost of that isolation.

## agy (Antigravity CLI)

agy reports its lifecycle through a plugin that calls the shared wrapper. The repository ships the manifest, hook mapping, and hook shim under [`agents/agy/`](../agents/agy/); install it by symlinking that directory into agy's plugin folder.

| agy event | Reported state |
| --- | --- |
| `SessionStart` | `idle` |
| `PreInvocation` | `working` |
| `PreToolUse` (`ask_question`) | `blocked` |
| `PostToolUse` (`ask_question`) | `working` |
| `Stop` | `done`, or `idle` when `terminationReason` is `USER_CANCELED` |

### Install

```sh
plugin_dir=$(tmux show-environment -g TMUX_PLUGIN_MANAGER_PATH | cut -d= -f2-)
mkdir -p ~/.gemini/config/plugins
ln -s "$plugin_dir/tmux-agent-picker/agents/agy" ~/.gemini/config/plugins/tmux-agent-picker
agy plugin list
```

`agy plugin list` reports `tmux-agent-picker (enabled)`. Start a new agy session inside tmux so its hooks inherit `TMUX_PANE`.

### Uninstall

```sh
rm ~/.gemini/config/plugins/tmux-agent-picker
```

### Limits

- agy exposes no `SessionEnd` hook, so an exited session is not cleared explicitly; the picker hides panes whose foreground command is a bare shell, which covers an exited agent.
- Only `ask_question` prompts are reported as `blocked`. Other permission prompts keep the pane in its previous state.
- Subagent events are ignored by the conversation-id gate. The shim stores the root `conversationId` in `${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tmux-agent-picker/agy-<uid>-<pane>.conv` and overwrites it on `SessionStart`.
- agy marks a tool call failed when a hook prints non-JSON, so the shim always prints exactly `{}` and exits 0.

## Agents without hooks

The picker detects an agent process automatically. A pane with no reported state is scanned for a name from `@ap_detect_agents` in the foreground command, the pane's command line, and its child processes, so agents like `claude`, `codex`, and `copilot` appear as `idle` rows with an age of `-` even before you write any integration. See [Detected agents](DEVELOPMENT.md#detected-agents) for the match order, the default list, and the limits.

Detection reads a process name, so it cannot report `working`, `blocked`, or `done`. For those states, keep the hook integration: it is what turns an `idle` row into an actionable one. When an integration reports state, that state replaces the detected row in the same pane. To list only panes that report state, set `@ap_detect_agents` to `off`; no process inspection runs in that mode. `on`, or no option at all, selects the built-in name list.

If the agent's name never appears in its process tree — an obvious case is a command that is renamed at launch, or a launcher that keeps the real command line hidden — use a shell wrapper:

```sh
#!/bin/sh
~/.tmux/plugins/tmux-agent-picker/bin/agent-state set myagent working
exec /path/to/agent "$@"
```

A wrapper reports `working` when it starts and `clear` on exit, but it cannot report `blocked` or `done`, so treat it as a fallback. It is only needed when detection cannot see the agent name; a plain `exec` wrapper is usually detected without one.

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
