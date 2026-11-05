#!/usr/bin/env bash
set -u

CURRENT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
tmux set-environment -g TMUX_AGENT_PICKER_ROOT "$CURRENT_DIR"
tmux source-file "$CURRENT_DIR/tmux/tmux-agent-picker.tmux.conf"
