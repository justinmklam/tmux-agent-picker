#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SERVER=ap-test
TMP_ROOT=$(mktemp -d)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
export TMUX_TMPDIR=$(mktemp -d)
export _ZO_DATA_DIR=$(mktemp -d)
export PATH="$ROOT/bin:$PATH"

cleanup() {
  tmux -L "$SERVER" kill-server >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT" "$TMUX_TMPDIR" "$_ZO_DATA_DIR"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

ok() {
  printf 'ok - %s\n' "$1"
}

assert_eq() {
  local expected=$1 actual=$2 label=$3
  [[ $actual == "$expected" ]] || {
    printf 'expected: %q\nactual:   %q\n' "$expected" "$actual" >&2
    fail "$label"
  }
  ok "$label"
}

assert_match() {
  local pattern=$1 actual=$2 label=$3
  [[ $actual =~ $pattern ]] || {
    printf 'pattern: %q\nactual:  %q\n' "$pattern" "$actual" >&2
    fail "$label"
  }
  ok "$label"
}

wait_for() {
  local pane=$1 text=$2 i screen
  for i in $(seq 1 100); do
    screen=$(tmux_cmd capture-pane -p -t "$pane" 2>/dev/null || true)
    [[ $screen == *"$text"* ]] && return 0
    sleep 0.05
  done
  printf 'timed out waiting for %q in pane %s\n' "$text" "$pane" >&2
  tmux_cmd capture-pane -p -t "$pane" >&2 || true
  return 1
}

wait_for_normal() {
  local pane=$1 i screen
  for i in $(seq 1 100); do
    screen=$(tmux_cmd capture-pane -p -t "$pane" 2>/dev/null || true)
    [[ $screen == *'Enter go'* && $screen != *'type to filter'* ]] && return 0
    sleep 0.05
  done
  return 1
}

tmux_cmd() { tmux -L "$SERVER" "$@"; }

# fzf draws the focused list line with a bold pointer and the `bg+` colour, so an
# attribute-preserving capture can report the row under the cursor.
picker_rows() {
  local pane=$1
  tmux_cmd capture-pane -e -p -t "$pane" 2>/dev/null |
    sed -E $'s/\033\\[[0-9;]*m//g' |
    sed -E 's/^(▌| )+//; s/[│╭╮╰╯].*$//; s/[[:space:]]+$//' |
    grep -E '^(blocked|done|idle|working|session)([[:space:]]|$)' || true
}

picker_focused_row() {
  local pane=$1
  tmux_cmd capture-pane -e -p -t "$pane" 2>/dev/null |
    grep -aF $'\033[1m' |
    grep -aF '▌' |
    head -n 1 |
    sed -E $'s/\033\\[[0-9;]*m//g' |
    sed -E 's/^(▌| )+//; s/[│╭╮╰╯].*$//; s/[[:space:]]+$//' || true
}

# A dedicated server started from an explicit command gives every test pane a stable shell context.
tmux -L "$SERVER" -f /dev/null new-session -d -s ap-test -c "$TMP_ROOT" 'exec sleep 3600'
SERVER_INFO=$(tmux_cmd display-message -p '#{socket_path},#{pid},0')
export TMUX=$SERVER_INFO

new_pane() {
  local name=$1 command=${2:-'exec sleep 3600'}
  tmux_cmd new-window -d -t ap-test: -n "$name" "$command"
  tmux_cmd display-message -p -t "ap-test:$name" '#{pane_id}'
}

pane_option() {
  tmux_cmd display-message -p -t "$1" "$2"
}

run_state() {
  TMUX_PANE=$1 "$ROOT/bin/agent-state" "${@:2}"
}

json_valid() {
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$1" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool "$1" >/dev/null 2>&1
  else
    return 0
  fi
}

# Create an executable symlink to sleep with a chosen process name so tests can
# stand in for a native agent binary without installing one.
agent_link() {
  local name=$1
  ln -sf "$(command -v sleep)" "$TMP_ROOT/$name"
  printf '%s' "$TMP_ROOT/$name"
}

wait_for_command() {
  local pane=$1 want=$2 i
  for i in $(seq 1 100); do
    [[ $(pane_option "$pane" '#{pane_current_command}') == "$want" ]] && return 0
    sleep 0.05
  done
  printf 'timed out waiting for command %q in pane %s, got %q\n' \
    "$want" "$pane" "$(pane_option "$pane" '#{pane_current_command}')" >&2
  return 1
}

wait_for_child() {
  local pane=$1 i pid
  for i in $(seq 1 100); do
    pid=$(pane_option "$pane" '#{pane_pid}')
    [[ -n $(pgrep -P "$pid" 2>/dev/null || true) ]] && return 0
    sleep 0.05
  done
  printf 'timed out waiting for a child process in pane %s\n' "$pane" >&2
  return 1
}

# (a) set writes valid state and list is agent-name agnostic.
PI_PANE=$(new_pane pi)
CODEX_PANE=$(new_pane codex)
run_state "$PI_PANE" set pi working
run_state "$CODEX_PANE" set codex blocked
assert_eq pi "$(pane_option "$PI_PANE" '#{@ap_agent}')" '(a) stores agent'
assert_eq working "$(pane_option "$PI_PANE" '#{@ap_state}')" '(a) stores state'
assert_match '^[0-9]+$' "$(pane_option "$PI_PANE" '#{@ap_since}')" '(a) stores numeric since'
LIST=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list)
assert_match $'blocked[[:space:]]+codex[[:space:]]' "$LIST" '(a) lists another agent'
CODEX_ROW=$(printf '%s\n' "$LIST" | grep -F "$CODEX_PANE" | head -n 1)
PI_ROW=$(printf '%s\n' "$LIST" | grep -F "$PI_PANE" | head -n 1)
assert_eq ok "$(printf '%s\n' "$CODEX_ROW" | awk '$2 == "blocked" && $3 == "codex" && $4 ~ /^ap-test:/ { print "ok" }')" '(a) separates agent list columns'
CODEX_LOCATION_COL=$(printf '%s\n' "$CODEX_ROW" | awk '{ match($0, /ap-test:[0-9]+\.[0-9]+/); print RSTART }')
PI_LOCATION_COL=$(printf '%s\n' "$PI_ROW" | awk '{ match($0, /ap-test:[0-9]+\.[0-9]+/); print RSTART }')
assert_match '^[0-9]+$' "$CODEX_LOCATION_COL" '(a) finds codex location column'
assert_match '^[0-9]+$' "$PI_LOCATION_COL" '(a) finds pi location column'
assert_eq "$CODEX_LOCATION_COL" "$PI_LOCATION_COL" '(a) aligns location columns'
CODEX_AGE_COL=$(printf '%s\n' "$CODEX_ROW" | awk '{ match($0, /[0-9]+[smhd]/); print RSTART }')
PI_AGE_COL=$(printf '%s\n' "$PI_ROW" | awk '{ match($0, /[0-9]+[smhd]/); print RSTART }')
assert_eq "$CODEX_AGE_COL" "$PI_AGE_COL" '(a) aligns age columns'
assert_match $'\tblocked {2}codex {2}ap-test:[0-9]+\.[0-9]+ {2}[0-9]+[smhd]' "$CODEX_ROW" '(a) pads columns with a two-space gutter'
TMUX_PANE=$PI_PANE "$ROOT/bin/agent-state" set 'Bad Name!' working
assert_eq pi "$(pane_option "$PI_PANE" '#{@ap_agent}')" '(a) rejects invalid agent without writing'

# (b) identical state does not refresh since.
BEFORE=$(pane_option "$PI_PANE" '#{@ap_since}')
sleep 1
run_state "$PI_PANE" set pi working
assert_eq "$BEFORE" "$(pane_option "$PI_PANE" '#{@ap_since}')" '(b) repeated state keeps since'

# (c) changed state refreshes since.
sleep 1
run_state "$PI_PANE" set pi blocked
AFTER=$(pane_option "$PI_PANE" '#{@ap_since}')
[[ $AFTER -gt $BEFORE ]] || fail '(c) changed state refreshes since'
ok '(c) changed state refreshes since'

# (d) seen only changes done.
DONE_PANE=$(new_pane done)
BLOCKED_PANE=$(new_pane blocked)
WORKING_PANE=$(new_pane working)
run_state "$DONE_PANE" set pi done
run_state "$BLOCKED_PANE" set pi blocked
run_state "$WORKING_PANE" set pi working
DONE_SINCE=$(pane_option "$DONE_PANE" '#{@ap_since}')
run_state "$DONE_PANE" seen
assert_eq idle "$(pane_option "$DONE_PANE" '#{@ap_state}')" '(d) seen changes done to idle'
assert_eq "$DONE_SINCE" "$(pane_option "$DONE_PANE" '#{@ap_since}')" '(d) seen keeps since'
run_state "$BLOCKED_PANE" seen
assert_eq blocked "$(pane_option "$BLOCKED_PANE" '#{@ap_state}')" '(d) seen leaves blocked'
run_state "$WORKING_PANE" seen
assert_eq working "$(pane_option "$WORKING_PANE" '#{@ap_state}')" '(d) seen leaves working'
IDLE_ROW=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list | grep -F "$DONE_PANE" | head -n 1)
assert_match $'\tidle {2}pi([[:space:]]|$)' "$IDLE_ROW" '(d) pads the state column with a two-space gutter'

# (e) clear removes all options.
run_state "$PI_PANE" clear
assert_eq '' "$(pane_option "$PI_PANE" '#{@ap_agent}')" '(e) clear removes agent'
assert_eq '' "$(pane_option "$PI_PANE" '#{@ap_state}')" '(e) clear removes state'
assert_eq '' "$(pane_option "$PI_PANE" '#{@ap_since}')" '(e) clear removes since'

# (f) no pane is a no-op.
unset TMUX_PANE
"$ROOT/bin/agent-state" set pi working
"$ROOT/bin/agent-state" seen
"$ROOT/bin/agent-state" clear
ok '(f) missing TMUX_PANE is a no-op'
export TMUX=$SERVER_INFO

# (g) deterministic ordering by tier, then newest since.
run_state "$CODEX_PANE" clear
run_state "$DONE_PANE" clear
run_state "$BLOCKED_PANE" clear
run_state "$WORKING_PANE" clear
ORDER_PANES=()
i=0
for state in blocked blocked done idle working; do
  i=$((i + 1))
  pane=$(new_pane "$state-$i")
  ORDER_PANES+=("$pane")
  run_state "$pane" set pi "$state"
done
now=$(date +%s)
tmux_cmd set-option -pt "${ORDER_PANES[0]}" @ap_since $((now - 90))
tmux_cmd set-option -pt "${ORDER_PANES[1]}" @ap_since $((now - 10))
tmux_cmd set-option -pt "${ORDER_PANES[2]}" @ap_since $((now - 20))
tmux_cmd set-option -pt "${ORDER_PANES[3]}" @ap_since $((now - 30))
tmux_cmd set-option -pt "${ORDER_PANES[4]}" @ap_since $((now - 40))
ORDER=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list | awk '$2 != "session" {print $1}' | paste -sd, -)
EXPECTED=$(printf '%s,' "${ORDER_PANES[1]}" "${ORDER_PANES[0]}" "${ORDER_PANES[4]}" "${ORDER_PANES[2]}" "${ORDER_PANES[3]}" | sed 's/,$//')
assert_eq "$EXPECTED" "$ORDER" '(g) orders state tiers and newest first'

# (h) bare shells are stale and hidden.
SHELL_PANE=$(new_pane shell 'exec sh')
for _ in $(seq 1 100); do
  [[ $(pane_option "$SHELL_PANE" '#{pane_current_command}') == sh ]] && break
  sleep 0.05
done
run_state "$SHELL_PANE" set pi blocked
SHELL_LIST=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list)
[[ $SHELL_LIST != *"$SHELL_PANE"* ]] || fail '(h) hides bare shell panes'
ok '(h) hides bare shell panes'

# (h2) uninstrumented sessions appear once and can be targeted.
PLAIN_PANE=$(tmux_cmd new-session -d -P -F '#{pane_id}' -s plain-session -c "$TMP_ROOT" 'exec sleep 3600')
tmux_cmd new-window -d -t plain-session: -n plain-second 'exec sleep 3600'
tmux_cmd select-window -t plain-session:plain-second
PLAIN_ACTIVE_PANE=$(tmux_cmd display-message -p -t plain-session '#{pane_id}')
PLAIN_LIST=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list)
assert_eq 1 "$(printf '%s\n' "$PLAIN_LIST" | grep -c 'session plain-session' || true)" '(h2) lists an uninstrumented session once'
assert_eq 1 "$(printf '%s\n' "$PLAIN_LIST" | grep -F -c "$PLAIN_ACTIVE_PANE"$'\tsession plain-session' || true)" '(h2) targets the active pane of an uninstrumented session'
assert_eq 0 "$(printf '%s\n' "$PLAIN_LIST" | grep -c 'session ap-test' || true)" '(h2) does not duplicate a stateful session'
# The private server has no attached tty client; client-qualified switching is
# covered by the binding check below and requires manual verification.
TMUX_PANE= "$ROOT/bin/agent-pick" --go "$PLAIN_ACTIVE_PANE"
assert_eq 1 "$(pane_option "$PLAIN_ACTIVE_PANE" '#{pane_active}')" '(h2) accepts an uninstrumented session row target'
tmux_cmd kill-session -t plain-session

# (i)-(n) session opener behavior.
mkdir -p "$TMP_ROOT/proj" "$TMP_ROOT/other/proj" "$TMP_ROOT/my.app" "$TMP_ROOT/x/proj"
OPENED=$("$ROOT/bin/agent-new" --open "$TMP_ROOT/proj") || fail '(i) opens a new directory session'
assert_eq proj "$OPENED" '(i) prints new session name'
assert_eq "$TMP_ROOT/proj" "$(tmux_cmd display-message -p -t proj '#{session_path}')" '(i) stores session path'
ZOX=$(zoxide query -l 2>/dev/null || true)
[[ $ZOX == *"$TMP_ROOT/proj"* ]] || fail '(i) adds directory to zoxide'
ok '(i) adds directory to zoxide'

SESSION_COUNT=$(tmux_cmd list-sessions | wc -l | tr -d ' ')
OPENED=$("$ROOT/bin/agent-new" --open "$TMP_ROOT/proj") || fail '(j) reopens existing directory'
assert_eq proj "$OPENED" '(j) prints existing session name'
assert_eq "$SESSION_COUNT" "$(tmux_cmd list-sessions | wc -l | tr -d ' ')" '(j) does not duplicate existing session'

OPENED=$("$ROOT/bin/agent-new" --open "$TMP_ROOT/other/proj") || fail '(k) opens colliding basename'
assert_eq proj-2 "$OPENED" '(k) appends numeric suffix'
OPENED=$("$ROOT/bin/agent-new" --open "$TMP_ROOT/my.app") || fail '(l) opens dotted basename'
assert_eq my_app "$OPENED" '(l) replaces dots'

ERR_FILE="$TMP_ROOT/agent-new.err"
BEFORE_M=$(tmux_cmd list-sessions | wc -l | tr -d ' ')
if "$ROOT/bin/agent-new" --open "$TMP_ROOT/no-such" >/dev/null 2>"$ERR_FILE"; then
  fail '(m) rejects missing directory'
fi
assert_eq "agent-new: no such directory: $TMP_ROOT/no-such" "$(<"$ERR_FILE")" '(m) reports missing directory'
assert_eq "$BEFORE_M" "$(tmux_cmd list-sessions | wc -l | tr -d ' ')" '(m) creates no session'

# (n) exact session-name matching must not treat projector as proj.
tmux_cmd kill-session -t proj
mkdir -p "$TMP_ROOT/x/proj"
tmux_cmd new-session -d -s projector -c "$TMP_ROOT"
OPENED=$("$ROOT/bin/agent-new" --open "$TMP_ROOT/x/proj") || fail '(n) opens exact basename beside prefix match'
assert_eq proj "$OPENED" '(n) uses exact session-name check'

# (o)-(s) modal picker behavior.
# Detection is covered by (v); switching it off keeps every picker reload in
# these sections free of a full process-table scan.
tmux_cmd set-option -g @ap_detect_agents off
tmux_cmd set-option -g remain-on-exit on
for pane in "${ORDER_PANES[@]}" "$SHELL_PANE"; do
  run_state "$pane" clear
done
states=(blocked blocked done idle working)
now=$(date +%s)
for i in "${!ORDER_PANES[@]}"; do
  run_state "${ORDER_PANES[$i]}" set pi "${states[$i]}"
done
tmux_cmd set-option -pt "${ORDER_PANES[0]}" @ap_since $((now - 90))
tmux_cmd set-option -pt "${ORDER_PANES[1]}" @ap_since $((now - 10))
tmux_cmd set-option -pt "${ORDER_PANES[2]}" @ap_since $((now - 20))
tmux_cmd set-option -pt "${ORDER_PANES[3]}" @ap_since $((now - 30))
tmux_cmd set-option -pt "${ORDER_PANES[4]}" @ap_since $((now - 40))

INSTALL_ROOT="$TMP_ROOT/tmux agent-picker-install"
ln -s "$ROOT" "$INSTALL_ROOT"
"$INSTALL_ROOT/tmux-agent-picker.tmux"
# This harness has no attached tty client, so A7 uses its documented fallback:
# verify the client-qualified binding here and rely on human verification for
# pressing prefix+a and confirming only that client switches.
KEY=$(tmux_cmd list-keys -T prefix a)
[[ $KEY == *"'$INSTALL_ROOT/bin/agent-pick'"* && $KEY == *"--client"* ]] || fail '(q) binding uses configured picker root'
ok '(q) binding uses configured picker root'
[[ -n $(tmux_cmd show-options -gv @ap_fzf_colors) ]] || fail '(q) loads theme from configured picker root'
ok '(q) loads theme from configured picker root'
tmux_cmd source-file "$ROOT/tmux/tmux-agent-picker.tmux.conf"
for hook in pane-focus-in after-select-pane after-select-window client-session-changed; do
  count=$(tmux_cmd show-hooks -g "$hook" 2>/dev/null | grep -c 'bin/agent-state' || true)
  assert_eq 1 "$count" "(q) $hook hook is not duplicated"
  hook_text=$(tmux_cmd show-hooks -g "$hook")
  [[ $hook_text == *"$INSTALL_ROOT/bin/agent-state"* ]] || fail "(q) $hook hook uses configured picker root"
  ok "(q) $hook hook uses configured picker root"
done

# The private test server has no attached client, so select-pane does not
# fire focus hooks. Re-run the stored hook directly to verify the configured
# command handles the spaced install root and performs the state update.
run_state "${ORDER_PANES[2]}" set pi done
tmux_cmd set-hook -R -t "${ORDER_PANES[2]}" after-select-pane
for i in $(seq 1 100); do
  [[ $(pane_option "${ORDER_PANES[2]}" '#{@ap_state}') == idle ]] && break
  sleep 0.05
done
assert_eq idle "$(pane_option "${ORDER_PANES[2]}" '#{@ap_state}')" '(q) stored focus hook changes done to idle'

# The hook test consumed the done row; restore it so (o) can assert the tier order.
run_state "${ORDER_PANES[2]}" set pi done
tmux_cmd set-option -pt "${ORDER_PANES[2]}" @ap_since $((now - 20))

PICKER=$(tmux_cmd new-window -d -t ap-test: -n ap-picker "exec \"$INSTALL_ROOT/bin/agent-pick\"")
PICKER=$(tmux_cmd display-message -p -t ap-test:ap-picker '#{pane_id}')
wait_for "$PICKER" 'Enter go' || fail '(o) picker did not start'
SCREEN=$(tmux_cmd capture-pane -p -t "$PICKER")
[[ $SCREEN == *'Enter go  n new session'* ]] || fail '(o) shows normal footer with agent rows'
[[ $SCREEN =~ blocked[[:space:]]+pi && $SCREEN =~ done[[:space:]]+pi && $SCREEN =~ idle[[:space:]]+pi && $SCREEN =~ working[[:space:]]+pi ]] || {
  printf '%s\n' "$SCREEN" >&2
  fail '(o) shows ordered agent rows'
}
[[ $SCREEN =~ (blocked|done|idle|working)[[:space:]]+pi[[:space:]]+ap-test: ]] || fail '(o) keeps agent locations visible'
[[ $SCREEN =~ [0-9]+[smhd] ]] || fail '(o) keeps agent ages visible'
ORDER=$(printf '%s\n' "$SCREEN" | grep -E 'blocked[[:space:]]+pi|done[[:space:]]+pi|idle[[:space:]]+pi|working[[:space:]]+pi' | sed -E 's/.*(blocked|done|idle|working)[[:space:]]+pi.*/\1/' | paste -sd, -)
assert_eq 'blocked,blocked,working,done,idle' "$ORDER" '(o) preserves computed row order'
ok '(o) shows ordered agent rows'
[[ $SCREEN != *'type to filter'* ]] || fail '(o) hides input in normal mode'
ok '(o) hides input in normal mode'
# Widen the window so the footer is not clipped by the 50% preview pane.
tmux_cmd resize-window -t "$PICKER" -x 200 -y 30
wait_for "$PICKER" 'X kill session' || fail '(o) footer does not advertise both kill keys'
SCREEN=$(tmux_cmd capture-pane -p -t "$PICKER")
[[ $SCREEN == *'x kill'* ]] || fail '(o) footer advertises the kill key'
[[ $SCREEN == *'X kill session'* ]] || fail '(o) footer advertises the session kill key'
ok '(o) footer advertises the kill keys'

# (o2) x kills the pane under the cursor, not the whole session. The leftover
# plain sessions from earlier sections keep the list short enough to navigate.
tmux_cmd kill-session -t proj
tmux_cmd kill-session -t proj-2
tmux_cmd kill-session -t my_app
tmux_cmd kill-session -t projector
PAIR_PANE=$(tmux_cmd new-session -d -P -F '#{pane_id}' -s pair -c "$TMP_ROOT" 'exec sleep 3600')
PAIR_SIBLING=$(tmux_cmd new-window -d -P -F '#{pane_id}' -t pair: -n pair-second 'exec sleep 3600')
PLAIN_KILL=$(tmux_cmd new-session -d -P -F '#{pane_id}' -s plainkill -c "$TMP_ROOT" 'exec sleep 3600')
now_kill=$(date +%s)
run_state "$PAIR_PANE" set pi blocked
run_state "$PAIR_SIBLING" set pi blocked
tmux_cmd set-option -pt "$PAIR_PANE" @ap_since $((now_kill - 2))
tmux_cmd set-option -pt "$PAIR_SIBLING" @ap_since $((now_kill - 1))
ROWS=$(TMUX_PANE= "$ROOT/bin/agent-pick" --rows)
assert_eq agent "$(printf '%s\n' "$ROWS" | awk -F '\t' -v p="$PAIR_PANE" '$1 == p { print $2 }')" '(o2) marks an agent row'
assert_eq session "$(printf '%s\n' "$ROWS" | awk -F '\t' -v p="$PLAIN_KILL" '$1 == p { print $2 }')" '(o2) marks a session row'

KILLER=$(tmux_cmd new-window -d -P -F '#{pane_id}' -t ap-test: -n ap-killer "exec \"$INSTALL_ROOT/bin/agent-pick\"")
wait_for "$KILLER" 'Enter go' || fail '(o2) killer picker did not start'
FIRST_ROW=$(picker_rows "$KILLER" | head -n 1)
[[ $FIRST_ROW == *'pair:1.0'* ]] || {
  printf '%s\n' "$FIRST_ROW" >&2
  fail '(o2) newest blocked row sorts first'
}
tmux_cmd send-keys -t "$KILLER" x
wait_for "$KILLER" 'kill pane pair:1.0? [y/N]' || fail '(o2) x prompts for the pane'
ok '(o2) x prompts for the pane'
tmux_cmd send-keys -t "$KILLER" n
wait_for_normal "$KILLER" || fail '(o2) declining returns to the picker'
assert_eq 2 "$(tmux_cmd list-panes -s -t pair -F '#{pane_id}' | wc -l | tr -d ' ')" '(o2) declining keeps both panes'

tmux_cmd send-keys -t "$KILLER" x
wait_for "$KILLER" 'kill pane pair:1.0? [y/N]' || fail '(o2) x prompts again after declining'
tmux_cmd send-keys -t "$KILLER" y
for i in $(seq 1 100); do
  [[ -z $(tmux_cmd list-panes -s -t pair -F '#{pane_id}' | grep -x -- "$PAIR_SIBLING" || true) ]] && break
  sleep 0.05
done
assert_eq '' "$(tmux_cmd list-panes -s -t pair -F '#{pane_id}' | grep -x -- "$PAIR_SIBLING" || true)" '(o2) confirmation kills the selected pane'
assert_eq "$PAIR_PANE" "$(tmux_cmd list-panes -s -t pair -F '#{pane_id}')" '(o2) leaves the sibling pane alive'
[[ -n $(tmux_cmd list-sessions -F '#{session_name}' | grep -x -- pair || true) ]] || fail '(o2) leaves the session alive'
ok '(o2) leaves the session alive'
wait_for_normal "$KILLER" || fail '(o2) picker stays open after killing'
for i in $(seq 1 100); do
  SCREEN=$(tmux_cmd capture-pane -p -t "$KILLER")
  [[ $SCREEN != *'pair:1.0'* ]] && break
  sleep 0.05
done
[[ $SCREEN != *'pair:1.0'* ]] || {
  printf '%s\n' "$SCREEN" >&2
  fail '(o2) reload drops the killed pane row'
}
ok '(o2) reload drops the killed pane row'

# (o3) X kills the session under the cursor whatever the row kind is.
tmux_cmd send-keys -t "$KILLER" X
wait_for "$KILLER" 'kill session pair? [y/N]' || fail '(o3) X prompts for the session'
ok '(o3) X prompts for the session'
tmux_cmd send-keys -t "$KILLER" y
for i in $(seq 1 100); do
  [[ -z $(tmux_cmd list-sessions -F '#{session_name}' | grep -x -- pair || true) ]] && break
  sleep 0.05
done
assert_eq '' "$(tmux_cmd list-sessions -F '#{session_name}' | grep -x -- pair || true)" '(o3) X kills the session'
wait_for_normal "$KILLER" || fail '(o3) picker stays open after killing the session'
ok '(o3) picker stays open after killing the session'

# (o4) x on a session row kills that session instead of its active pane. The
# reload after a declined prompt picks up the plain session created above.
tmux_cmd send-keys -t "$KILLER" x
wait_for "$KILLER" 'kill pane ' || fail '(o4) x prompts before the reload'
tmux_cmd send-keys -t "$KILLER" n
wait_for_normal "$KILLER" || fail '(o4) declining returns to the picker'
tmux_cmd send-keys -t "$KILLER" -N 40 j
for i in $(seq 1 100); do
  FOCUSED=$(picker_focused_row "$KILLER")
  [[ $FOCUSED == *'session plainkill'* ]] && break
  sleep 0.05
done
[[ $FOCUSED == *'session plainkill'* ]] || {
  printf '%s\n' "$FOCUSED" >&2
  fail '(o4) moves the cursor to the session row'
}
tmux_cmd send-keys -t "$KILLER" x
wait_for "$KILLER" 'kill session plainkill? [y/N]' || fail '(o4) x kills the session on a session row'
ok '(o4) x kills the session on a session row'
tmux_cmd send-keys -t "$KILLER" y
for i in $(seq 1 100); do
  [[ -z $(tmux_cmd list-sessions -F '#{session_name}' | grep -x -- plainkill || true) ]] && break
  sleep 0.05
done
assert_eq '' "$(tmux_cmd list-sessions -F '#{session_name}' | grep -x -- plainkill || true)" '(o4) confirmation kills the session'
wait_for_normal "$KILLER" || fail '(o4) picker stays open after killing the session'

# (o5) a pane holding the picker is protected from a pane kill.
SELF_PANE=$(tmux_cmd new-window -d -P -F '#{pane_id}' -t ap-test: -n ap-self "exec \"$INSTALL_ROOT/bin/agent-pick\" --kill \"\$TMUX_PANE\" agent; exec sleep 3600")
wait_for "$SELF_PANE" 'refusing to kill the current pane' || fail '(o5) refuses to kill the current pane'
ok '(o5) refuses to kill the current pane'
tmux_cmd send-keys -t "$SELF_PANE" z
assert_eq "$SELF_PANE" "$(tmux_cmd list-panes -a -F '#{pane_id}' | grep -x -- "$SELF_PANE")" '(o5) keeps the current pane'

# (o6) the session running the picker is protected from a session kill.
FOCUSED=$(picker_focused_row "$KILLER")
[[ $FOCUSED == *'ap-test:'* ]] || {
  printf '%s\n' "$FOCUSED" >&2
  fail '(o6) cursor resets to an ap-test row after a reload'
}
tmux_cmd send-keys -t "$KILLER" X
wait_for "$KILLER" 'refusing to kill the current session' || fail '(o6) refuses to kill the current session'
ok '(o6) refuses to kill the current session'
tmux_cmd send-keys -t "$KILLER" z
wait_for_normal "$KILLER" || fail '(o6) returns to the picker after refusing'
[[ -n $(tmux_cmd list-sessions -F '#{session_name}' | grep -x -- ap-test || true) ]] || fail '(o6) keeps the current session'
ok '(o6) keeps the current session'
tmux_cmd send-keys -t "$KILLER" q
tmux_cmd set-option -gu @ap_detect_agents

tmux_cmd send-keys -t "$PICKER" /
wait_for "$PICKER" 'type to filter' || fail '(p) filter mode did not open'
tmux_cmd send-keys -t "$PICKER" n X x
wait_for "$PICKER" 'nXx' || fail '(p) query was not accepted'
ok '(p) lets n and x type while filtering'
tmux_cmd send-keys -t "$PICKER" Escape
wait_for_normal "$PICKER" || fail '(p) Esc did not leave filter mode'
SCREEN=$(tmux_cmd capture-pane -p -t "$PICKER")
if [[ $SCREEN == *'nX'* ]]; then
  printf '%s\n' "$SCREEN" >&2
  fail '(p) Esc clears filter query'
fi
ok '(p) Esc clears filter query'
ok '(p) Esc leaves filter mode'
tmux_cmd send-keys -t "$PICKER" Escape
for i in $(seq 1 100); do
  [[ $(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}') == 1 ]] && break
  sleep 0.05
done
assert_eq 1 "$(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}')" '(p) second Esc closes picker'

# Filter mode ranks by match quality, so an exact hit in the lowest tier
# outranks fuzzy hits above it. Normal mode keeps the computed order.
tmux_cmd new-session -d -s tira -c "$TMP_ROOT" 'exec sleep 3600'
PICKER=$(tmux_cmd new-window -d -P -F '#{pane_id}' -t ap-test: -n ap-picker-rank "exec \"$INSTALL_ROOT/bin/agent-pick\"")
wait_for_normal "$PICKER" || fail '(r) picker did not start'
tmux_cmd send-keys -t "$PICKER" /
wait_for "$PICKER" 'type to filter' || fail '(r) filter mode did not open'
tmux_cmd send-keys -t "$PICKER" t i r a
sleep 0.3
FIRST_ROW=$(tmux_cmd capture-pane -p -t "$PICKER" | grep -E '^ *(>|▌)? *(blocked|done|idle|working|session)[[:space:]]' | head -n 1)
[[ $FIRST_ROW =~ session[[:space:]]+tira ]] || { printf '%s\n' "$FIRST_ROW" >&2; fail '(r) filter ranks the exact match first'; }
ok '(r) filter ranks the exact match first'
tmux_cmd send-keys -t "$PICKER" Escape
wait_for_normal "$PICKER" || fail '(r) Esc did not leave filter mode'
tmux_cmd send-keys -t "$PICKER" Escape
tmux_cmd kill-session -t tira

# Typing a query restarts the cursor at the top of the list instead of keeping
# the row that happened to be focused before filtering.
PICKER=$(tmux_cmd new-window -d -P -F '#{pane_id}' -t ap-test: -n ap-picker-cursor "exec \"$INSTALL_ROOT/bin/agent-pick\"")
wait_for_normal "$PICKER" || fail '(u) cursor picker did not start'
tmux_cmd send-keys -t "$PICKER" j
sleep 0.2
tmux_cmd send-keys -t "$PICKER" j
sleep 0.3
assert_eq "$(picker_rows "$PICKER" | sed -n 3p)" "$(picker_focused_row "$PICKER")" '(u) j moves the cursor down the list'
tmux_cmd send-keys -t "$PICKER" /
wait_for "$PICKER" 'type to filter' || fail '(u) filter mode did not open'
tmux_cmd send-keys -t "$PICKER" p
sleep 0.3
assert_eq "$(picker_rows "$PICKER" | head -n 1)" "$(picker_focused_row "$PICKER")" '(u) typing resets the cursor to the first row'
tmux_cmd send-keys -t "$PICKER" Escape
tmux_cmd send-keys -t "$PICKER" Escape

# The preview follows the bottom of the pane, so the newest output is visible
# without scrolling to it first. The agent pane is taller than the preview
# window so the top and bottom markers cannot both fit.
PREVIEW_LOG="$TMP_ROOT/preview-lines"
{
  printf 'preview-top\n'
  for i in $(seq 1 76); do printf 'preview-filler-%02d\n' "$i"; done
  printf 'preview-bottom\n'
} >"$PREVIEW_LOG"
PREVIEW_PANE=$(tmux_cmd new-session -d -P -F '#{pane_id}' -x 100 -y 80 -s ap-preview-scroll -c "$TMP_ROOT" "cat '$PREVIEW_LOG'; exec sleep 3600")
run_state "$PREVIEW_PANE" set pi blocked
PICKER=$(tmux_cmd new-window -d -P -F '#{pane_id}' -t ap-test: -n ap-picker-preview "exec \"$INSTALL_ROOT/bin/agent-pick\"")
wait_for_normal "$PICKER" || fail '(u2) preview picker did not start'
sleep 0.5
PREVIEW_SCREEN=$(tmux_cmd capture-pane -p -t "$PICKER")
[[ $PREVIEW_SCREEN == *preview-bottom* ]] || {
  printf '%s\n' "$PREVIEW_SCREEN" >&2
  fail '(u2) preview shows the bottom of the pane'
}
ok '(u2) preview shows the bottom of the pane'
[[ $PREVIEW_SCREEN != *preview-top* ]] || fail '(u2) preview scrolled past the top of the pane'
tmux_cmd send-keys -t "$PICKER" Escape
run_state "$PREVIEW_PANE" clear

PICKER=$(tmux_cmd new-window -d -t ap-test: -n ap-picker-q "exec \"$INSTALL_ROOT/bin/agent-pick\"")
PICKER=$(tmux_cmd display-message -p -t ap-test:ap-picker-q '#{pane_id}')
wait_for "$PICKER" 'Enter go' || fail '(p) q picker did not start'
tmux_cmd send-keys -t "$PICKER" q
for i in $(seq 1 100); do
  [[ $(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}') == 1 ]] && break
  sleep 0.05
done
assert_eq 1 "$(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}')" '(p) q closes picker'

PICKER=$(tmux_cmd new-window -d -t ap-test: -n ap-picker2 "exec \"$INSTALL_ROOT/bin/agent-pick\"")
PICKER=$(tmux_cmd display-message -p -t ap-test:ap-picker2 '#{pane_id}')
wait_for "$PICKER" 'Enter go' || fail '(r) picker did not start'
tmux_cmd send-keys -t "$PICKER" n
wait_for "$PICKER" 'Enter new session' || fail '(r) directory picker did not open'
ok '(r) n opens directory picker'
tmux_cmd send-keys -t "$PICKER" Escape
wait_for "$PICKER" 'Enter go' || fail '(r) Esc did not return to agents'
ok '(r) Esc returns to agent picker'
tmux_cmd send-keys -t "$PICKER" n
wait_for "$PICKER" 'Enter new session' || fail '(s) directory picker did not reopen'
tmux_cmd send-keys -t "$PICKER" -l -- '/no/such/dir'
tmux_cmd send-keys -t "$PICKER" Enter
wait_for "$PICKER" 'no such directory' || fail '(s) invalid directory was not reported'
assert_eq 0 "$(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}')" '(s) invalid directory keeps picker alive'
ok '(s) invalid directory keeps picker alive'

# Selecting an existing directory from the new-session picker creates a second session.
PICKER_EXISTING_DIR="$TMP_ROOT/picker-existing"
mkdir -p "$PICKER_EXISTING_DIR"
OPENED=$("$ROOT/bin/agent-new" --open "$PICKER_EXISTING_DIR") || fail '(t) seeds an existing picker directory session'
assert_eq picker-existing "$OPENED" '(t) seeds the existing picker session'
PICKER=$(tmux_cmd new-window -d -P -F '#{pane_id}' -t ap-test: -n ap-picker-existing "exec \"$INSTALL_ROOT/bin/agent-pick\"")
wait_for_normal "$PICKER" || fail '(t) existing-directory picker did not start'
tmux_cmd send-keys -t "$PICKER" n
wait_for "$PICKER" 'Enter new session' || fail '(t) existing-directory picker did not open'
tmux_cmd send-keys -t "$PICKER" -l -- picker-existing
tmux_cmd send-keys -t "$PICKER" Enter
for i in $(seq 1 100); do
  [[ $(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}' 2>/dev/null || true) == 1 ]] && break
  sleep 0.05
done
assert_eq 1 "$(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}' 2>/dev/null || true)" '(t) opening an existing directory closes the picker'
assert_eq "$PICKER_EXISTING_DIR" "$(tmux_cmd display-message -p -t picker-existing-2 '#{session_path}')" '(t) creates a new session for an existing directory'

# Successful Enter must resolve the query and create the selected session.
ENTER_DIR="$TMP_ROOT/enter-dir"
mkdir -p "$ENTER_DIR"
PICKER=$(tmux_cmd new-window -d -t ap-test: -n ap-picker3 "exec \"$INSTALL_ROOT/bin/agent-pick\"")
PICKER=$(tmux_cmd display-message -p -t ap-test:ap-picker3 '#{pane_id}')
wait_for "$PICKER" 'Enter go' || fail '(r) success picker did not start'
tmux_cmd send-keys -t "$PICKER" n
wait_for "$PICKER" 'Enter new session' || fail '(r) success directory picker did not open'
tmux_cmd send-keys -t "$PICKER" -l -- "$ENTER_DIR"
tmux_cmd send-keys -t "$PICKER" Enter
for i in $(seq 1 100); do
  [[ $(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}') == 1 ]] && break
  sleep 0.05
done
assert_eq 1 "$(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}')" '(r) Enter closes after opening a directory'
assert_eq "$ENTER_DIR" "$(tmux_cmd display-message -p -t enter-dir '#{session_path}')" '(r) Enter creates the selected session'

# (v) agents without lifecycle hooks are detected from their process.
CLAUDE_LINK=$(agent_link claude)
CODEX_RUN="$TMP_ROOT/@openai/codex/bin/run.js"
mkdir -p "$(dirname "$CODEX_RUN")"
printf 'setTimeout(function () {}, 60000)\n' > "$CODEX_RUN"

# A native binary reports its own name, so a symlink is enough to prove it.
CLAUDE_PANE=$(tmux_cmd new-session -d -P -F '#{pane_id}' -s detect-claude -c "$TMP_ROOT" "exec $CLAUDE_LINK 100")
wait_for_command "$CLAUDE_PANE" claude || fail '(v) claude fixture did not start'
DETECTED=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list)
assert_eq 'idle claude -' \
  "$(printf '%s\n' "$DETECTED" | awk -v p="$CLAUDE_PANE" '$1 == p { print $2, $3, $5 }')" \
  '(v) detects a native agent binary'
assert_eq 0 "$(printf '%s\n' "$DETECTED" | grep -c 'session detect-claude' || true)" \
  '(v) detected agent suppresses the session row'
assert_match $'\tidle {2}claude {2}detect-claude:[0-9]+\.[0-9]+ +-' \
  "$(printf '%s\n' "$DETECTED" | grep -F "$CLAUDE_PANE" | head -n 1)" \
  '(v) detected rows use the agent display format'

# Node-based agents are pnpm shims: the name only appears in the command line.
CODEX_PANE=$(new_pane codex-detect "exec node \"$CODEX_RUN\"")
wait_for_command "$CODEX_PANE" node || fail '(v) codex fixture did not start'
DETECTED=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list)
assert_eq 'idle codex -' \
  "$(printf '%s\n' "$DETECTED" | awk -v p="$CODEX_PANE" '$1 == p { print $2, $3, $5 }')" \
  '(v) detects an agent named in the command line'

# A wrapper shell hides the agent in a child process.
CODEX_CHILD_PANE=$(new_pane codex-child "exec sh -c 'node \"$CODEX_RUN\" & wait'")
wait_for_command "$CODEX_CHILD_PANE" sh || fail '(v) codex child fixture did not start'
wait_for_child "$CODEX_CHILD_PANE" || fail '(v) codex child process did not start'
CODEX_WRAPPER="$TMP_ROOT/run-agent"
printf '#!/bin/sh\nnode "%s" & wait\n' "$CODEX_RUN" > "$CODEX_WRAPPER"
chmod +x "$CODEX_WRAPPER"
CODEX_DEPTH_PANE=$(new_pane codex-depth "exec $CODEX_WRAPPER")
# The wrapper is a shell script, so the pane command is the interpreter.
wait_for_command "$CODEX_DEPTH_PANE" sh || fail '(v) codex depth fixture did not start'
wait_for_child "$CODEX_DEPTH_PANE" || fail '(v) codex depth child process did not start'
DETECTED=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list)
assert_eq 'idle codex -' \
  "$(printf '%s\n' "$DETECTED" | awk -v p="$CODEX_CHILD_PANE" '$1 == p { print $2, $3, $5 }')" \
  '(v) detects an agent inside a shell wrapper'
assert_eq 'idle codex -' \
  "$(printf '%s\n' "$DETECTED" | awk -v p="$CODEX_DEPTH_PANE" '$1 == p { print $2, $3, $5 }')" \
  '(v) detects an agent in a child process'

NODE_PANE=$(new_pane node-plain "exec node -e 'setTimeout(function () {}, 60000)'")
wait_for_command "$NODE_PANE" node || fail '(v) plain node fixture did not start'
DETECTED=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list)
assert_eq '' "$(printf '%s\n' "$DETECTED" | awk -v p="$NODE_PANE" '$1 == p')" \
  '(v) ignores a plain node pane'

# Explicit state always wins, including a stale value nobody cleared.
run_state "$CLAUDE_PANE" set pi working
DETECTED=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list)
assert_eq 1 "$(printf '%s\n' "$DETECTED" | grep -c -F "$CLAUDE_PANE" || true)" \
  '(v) lists a pane with explicit state once'
assert_eq 'working pi' \
  "$(printf '%s\n' "$DETECTED" | awk -v p="$CLAUDE_PANE" '$1 == p { print $2, $3 }')" \
  '(v) explicit state wins over detection'

TMUX_PANE= "$ROOT/bin/agent-pick" --go "$CODEX_PANE"
assert_eq 1 "$(pane_option "$CODEX_PANE" '#{pane_active}')" '(v) --go targets a detected pane'
run_state "$CLAUDE_PANE" clear

# (v5) @ap_detect_agents replaces the default name list.
MYTOOL_LINK=$(agent_link mytool)
tmux_cmd set-option -g @ap_detect_agents 'mytool'
MYTOOL_PANE=$(new_pane mytool "exec $MYTOOL_LINK 100")
wait_for_command "$MYTOOL_PANE" mytool || fail '(v5) mytool fixture did not start'
OVERRIDE=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list)
assert_eq 'idle mytool -' \
  "$(printf '%s\n' "$OVERRIDE" | awk -v p="$MYTOOL_PANE" '$1 == p { print $2, $3, $5 }')" \
  '(v5) honours @ap_detect_agents'
assert_eq '' "$(printf '%s\n' "$OVERRIDE" | awk -v p="$CLAUDE_PANE" '$1 == p && $2 != "session" { print $2 }')" \
  '(v5) override replaces the default name list'
assert_eq 1 "$(printf '%s\n' "$OVERRIDE" | grep -c 'session detect-claude' || true)" \
  '(v5) an undetected agent pane falls back to its session row'
tmux_cmd set-option -gu @ap_detect_agents

# (v6) @ap_detect_agents 'off' disables detection and process inspection.
PS_SHIM_DIR="$TMP_ROOT/ps-shim"
PS_LOG="$TMP_ROOT/ps-calls.log"
REAL_PS=$(command -v ps)
mkdir -p "$PS_SHIM_DIR"
printf '#!/bin/sh\nprintf x >> "%s"\nexec "%s" "$@"\n' "$PS_LOG" "$REAL_PS" > "$PS_SHIM_DIR/ps"
chmod +x "$PS_SHIM_DIR/ps"
: > "$PS_LOG"
PATH="$PS_SHIM_DIR:$PATH" TMUX_PANE= "$ROOT/bin/agent-pick" --list >/dev/null
assert_eq x "$(head -c 1 "$PS_LOG")" '(v6) inspects processes when detection is enabled'
tmux_cmd set-option -g @ap_detect_agents 'off'
: > "$PS_LOG"
OFF_LIST=$(PATH="$PS_SHIM_DIR:$PATH" TMUX_PANE= "$ROOT/bin/agent-pick" --list)
assert_eq '' "$(head -c 1 "$PS_LOG")" '(v6) off skips process inspection'
assert_eq '' "$(printf '%s\n' "$OFF_LIST" | awk -v p="$CLAUDE_PANE" '$1 == p && $2 != "session" { print $2 }')" \
  '(v6) off disables detection'
assert_eq 1 "$(printf '%s\n' "$OFF_LIST" | grep -c 'session detect-claude' || true)" \
  '(v6) off falls back to the session row'
tmux_cmd set-option -gu @ap_detect_agents
assert_eq 'idle claude -' \
  "$(TMUX_PANE= "$ROOT/bin/agent-pick" --list | awk -v p="$CLAUDE_PANE" '$1 == p { print $2, $3, $5 }')" \
  '(v6) detection returns after unsetting the option'

# (v7) 'on' restores the default name list without unsetting the option.
tmux_cmd set-option -g @ap_detect_agents 'on'
: > "$PS_LOG"
ON_LIST=$(PATH="$PS_SHIM_DIR:$PATH" TMUX_PANE= "$ROOT/bin/agent-pick" --list)
assert_eq x "$(head -c 1 "$PS_LOG")" '(v7) on resumes process inspection'
assert_eq 'idle claude -' \
  "$(printf '%s\n' "$ON_LIST" | awk -v p="$CLAUDE_PANE" '$1 == p { print $2, $3, $5 }')" \
  '(v7) on restores the default name list'
tmux_cmd set-option -gu @ap_detect_agents

# (v8) a leading '+' appends to the built-in name list instead of replacing it.
tmux_cmd set-option -g @ap_detect_agents '+mytool'
ADDED_LIST=$(TMUX_PANE= "$ROOT/bin/agent-pick" --list)
assert_eq 'idle mytool -' \
  "$(printf '%s\n' "$ADDED_LIST" | awk -v p="$MYTOOL_PANE" '$1 == p { print $2, $3, $5 }')" \
  '(v8) additive list detects the added name'
assert_eq 'idle claude -' \
  "$(printf '%s\n' "$ADDED_LIST" | awk -v p="$CLAUDE_PANE" '$1 == p { print $2, $3, $5 }')" \
  '(v8) additive list keeps the default names'
tmux_cmd set-option -gu @ap_detect_agents

for pane in "$CLAUDE_PANE" "$CODEX_PANE" "$CODEX_CHILD_PANE" "$CODEX_DEPTH_PANE" "$NODE_PANE" "$MYTOOL_PANE"; do
  tmux_cmd kill-pane -t "$pane" 2>/dev/null || true
done

# (w) agent-hook maps hook verbs onto agent-state writes.
hook() {  # pane agent verb payload
  printf '%s' "$4" | TMUX_PANE=$1 TMUX_AGENT_PICKER_BIN="$ROOT/bin/agent-state" \
    "$ROOT/bin/agent-hook" "$2" "$3"
}

HOOK_PANE=$(new_pane hook)
ROOT_PAYLOAD='{"session_id":"s1","hook_event_name":"Stop"}'
out=$(hook "$HOOK_PANE" claude session "$ROOT_PAYLOAD")
assert_eq 0 "$?" '(w) session exits 0'
assert_eq '' "$out" '(w) session prints nothing'
assert_eq claude "$(pane_option "$HOOK_PANE" '#{@ap_agent}')" '(w) session stores agent'
assert_eq idle "$(pane_option "$HOOK_PANE" '#{@ap_state}')" '(w) session maps to idle'
for spec in 'prompt working' 'permission blocked' 'activity working' 'stop done' 'interrupt idle'; do
  set -- $spec
  out=$(hook "$HOOK_PANE" claude "$1" "$ROOT_PAYLOAD")
  assert_eq 0 "$?" "(w) $1 exits 0"
  assert_eq '' "$out" "(w) $1 prints nothing"
  assert_eq "$2" "$(pane_option "$HOOK_PANE" '#{@ap_state}')" "(w) $1 maps to $2"
done
out=$(hook "$HOOK_PANE" claude end "$ROOT_PAYLOAD")
assert_eq 0 "$?" '(w) end exits 0'
assert_eq '' "$out" '(w) end prints nothing'
assert_eq '' "$(pane_option "$HOOK_PANE" '#{@ap_agent}')" '(w) end removes agent'
assert_eq '' "$(pane_option "$HOOK_PANE" '#{@ap_state}')" '(w) end removes state'
assert_eq '' "$(pane_option "$HOOK_PANE" '#{@ap_since}')" '(w) end removes since'

hook "$HOOK_PANE" claude stop "$ROOT_PAYLOAD" >/dev/null
hook "$HOOK_PANE" claude activity "$ROOT_PAYLOAD" >/dev/null
assert_eq done "$(pane_option "$HOOK_PANE" '#{@ap_state}')" '(w) activity keeps done'
hook "$HOOK_PANE" claude permission "$ROOT_PAYLOAD" >/dev/null
hook "$HOOK_PANE" claude activity "$ROOT_PAYLOAD" >/dev/null
assert_eq working "$(pane_option "$HOOK_PANE" '#{@ap_state}')" '(w) activity resumes working after blocked'

hook "$HOOK_PANE" claude stop '{"session_id":"s1","agent_id":"a1"}' >/dev/null
assert_eq working "$(pane_option "$HOOK_PANE" '#{@ap_state}')" '(w) subagent stop is ignored'
hook "$HOOK_PANE" claude stop '{"session_id":"s1","agentId":"a1"}' >/dev/null
assert_eq working "$(pane_option "$HOOK_PANE" '#{@ap_state}')" '(w) camelCase subagent stop is ignored'

hook "$HOOK_PANE" agy stop '{"conversationId":"root-1","terminationReason":"USER_CANCELED"}' >/dev/null
assert_eq idle "$(pane_option "$HOOK_PANE" '#{@ap_state}')" '(w) agy user cancel maps to idle'
hook "$HOOK_PANE" agy stop '{"conversationId":"root-1","terminationReason":"NO_TOOL_CALL"}' >/dev/null
assert_eq done "$(pane_option "$HOOK_PANE" '#{@ap_state}')" '(w) agy normal stop maps to done'

hook "$HOOK_PANE" claude prompt "$ROOT_PAYLOAD" >/dev/null
BEFORE_NO_PANE=$(pane_option "$HOOK_PANE" '#{@ap_state}')
out=$(hook '' claude permission "$ROOT_PAYLOAD")
assert_eq 0 "$?" '(w) missing pane exits 0'
assert_eq '' "$out" '(w) missing pane prints nothing'
assert_eq "$BEFORE_NO_PANE" "$(pane_option "$HOOK_PANE" '#{@ap_state}')" '(w) missing pane changes nothing'
printf '{}' | env -u TMUX_PANE TMUX_AGENT_PICKER_BIN="$ROOT/bin/agent-state" \
  "$ROOT/bin/agent-hook" claude permission "$HOOK_PANE"
assert_eq blocked "$(pane_option "$HOOK_PANE" '#{@ap_state}')" '(w) explicit pane argument is honoured'
out=$(printf 'not json' | TMUX_PANE=$HOOK_PANE TMUX_AGENT_PICKER_BIN="$ROOT/bin/agent-state" \
  "$ROOT/bin/agent-hook" claude bogus)
assert_eq 0 "$?" '(w) unknown verb exits 0'
assert_eq '' "$out" '(w) unknown verb prints nothing'
assert_eq blocked "$(pane_option "$HOOK_PANE" '#{@ap_state}')" '(w) unknown verb changes nothing'
out=$(printf '{}' | TMUX_PANE=$HOOK_PANE TMUX_AGENT_PICKER_BIN=/nonexistent \
  "$ROOT/bin/agent-hook" claude session)
assert_eq 0 "$?" '(w) missing agent-state exits 0'
assert_eq '' "$out" '(w) missing agent-state prints nothing'

HOOK_RUNTIME="$TMP_ROOT/hook-runtime"
mkdir -p "$HOOK_RUNTIME"
HOOK_PIDS=()
for _ in $(seq 1 20); do
  ( printf '{}' | XDG_RUNTIME_DIR="$HOOK_RUNTIME" TMUX_PANE=$HOOK_PANE \
      TMUX_AGENT_PICKER_BIN="$ROOT/bin/agent-state" "$ROOT/bin/agent-hook" claude prompt ) &
  HOOK_PIDS+=("$!")
done
HOOK_FAILED=0
for pid in "${HOOK_PIDS[@]}"; do
  wait "$pid" || HOOK_FAILED=1
done
assert_eq 0 "$HOOK_FAILED" '(w) concurrent hooks all exit 0'
HOOK_LEFTOVER=''
for _ in $(seq 1 20); do
  HOOK_LEFTOVER=$(pgrep -f 'bin/agent-hook' || true)
  [[ -z $HOOK_LEFTOVER ]] && break
  sleep 0.05
done
assert_eq '' "$HOOK_LEFTOVER" '(w) concurrent hooks leave no process'
assert_eq '' "$(find "$HOOK_RUNTIME/tmux-agent-picker" -maxdepth 1 -name 'lock-*' 2>/dev/null || true)" \
  '(w) concurrent hooks release the lock'

run_state "$HOOK_PANE" clear
tmux_cmd kill-pane -t "$HOOK_PANE" 2>/dev/null || true

# (w2) the tmux-agent-picker dispatcher fronts the internal scripts.
DISPATCH_PANE=$(new_pane dispatcher)
out=$(printf '{}' | TMUX_PANE=$DISPATCH_PANE TMUX_AGENT_PICKER_BIN="$ROOT/bin/agent-state" \
  tmux-agent-picker hook claude session)
assert_eq 0 "$?" '(w2) dispatcher hook exits 0'
assert_eq '' "$out" '(w2) dispatcher hook prints nothing'
assert_eq claude "$(pane_option "$DISPATCH_PANE" '#{@ap_agent}')" '(w2) dispatcher hook stores agent'
assert_eq idle "$(pane_option "$DISPATCH_PANE" '#{@ap_state}')" '(w2) dispatcher hook writes state'
TMUX_PANE=$DISPATCH_PANE tmux-agent-picker state set claude done
assert_eq done "$(pane_option "$DISPATCH_PANE" '#{@ap_state}')" '(w2) dispatcher state runs agent-state'
tmux-agent-picker state seen "$DISPATCH_PANE"
assert_eq idle "$(pane_option "$DISPATCH_PANE" '#{@ap_state}')" '(w2) dispatcher state seen maps done to idle'
out=$(tmux-agent-picker bogus 2>&1) && fail '(w2) unknown subcommand exits non-zero'
[[ $out == *Usage* ]] || fail '(w2) unknown subcommand prints usage'
ok '(w2) dispatcher rejects unknown subcommands'
run_state "$DISPATCH_PANE" clear
tmux_cmd kill-pane -t "$DISPATCH_PANE" 2>/dev/null || true

# (x) Claude Code hook mapping and shipped settings block.
CLAUDE_PANE=$(new_pane claude-hook)
CLAUDE_PAYLOAD='{"session_id":"s1","transcript_path":"/tmp/t","cwd":"/tmp","hook_event_name":"Stop"}'
for spec in 'SessionStart session idle' 'UserPromptSubmit prompt working' \
  'PermissionRequest permission blocked' 'PostToolUse activity working' 'Stop stop done'; do
  set -- $spec
  out=$(hook "$CLAUDE_PANE" claude "$2" "$CLAUDE_PAYLOAD")
  assert_eq 0 "$?" "(x) $1 exits 0"
  assert_eq '' "$out" "(x) $1 prints nothing"
  assert_eq "$3" "$(pane_option "$CLAUDE_PANE" '#{@ap_state}')" "(x) $1 maps to $3"
done
hook "$CLAUDE_PANE" claude permission "$CLAUDE_PAYLOAD" >/dev/null
hook "$CLAUDE_PANE" claude stop "$CLAUDE_PAYLOAD" >/dev/null
assert_eq done "$(pane_option "$CLAUDE_PANE" '#{@ap_state}')" '(x) Stop after blocked yields done'
hook "$CLAUDE_PANE" claude prompt "$CLAUDE_PAYLOAD" >/dev/null
hook "$CLAUDE_PANE" claude stop '{"session_id":"s1","agent_id":"a1","hook_event_name":"Stop"}' >/dev/null
assert_eq working "$(pane_option "$CLAUDE_PANE" '#{@ap_state}')" '(x) subagent Stop leaves the state untouched'
hook "$CLAUDE_PANE" claude end "$CLAUDE_PAYLOAD" >/dev/null
assert_eq '' "$(pane_option "$CLAUDE_PANE" '#{@ap_agent}')" '(x) SessionEnd removes agent'
assert_eq '' "$(pane_option "$CLAUDE_PANE" '#{@ap_state}')" '(x) SessionEnd removes state'
assert_eq '' "$(pane_option "$CLAUDE_PANE" '#{@ap_since}')" '(x) SessionEnd removes since'

printf '%s' "$CLAUDE_PAYLOAD" | TMUX_PANE=$CLAUDE_PANE \
  TMUX_AGENT_PICKER_BIN=$ROOT/bin/agent-state bash -c 'tmux-agent-picker hook claude prompt'
assert_eq working "$(pane_option "$CLAUDE_PANE" '#{@ap_state}')" '(x) shipped command form runs'

CLAUDE_SETTINGS="$ROOT/agents/claude/settings.hooks.json"
[[ -f $CLAUDE_SETTINGS ]] || fail '(x) agents/claude/settings.hooks.json exists'
json_valid "$CLAUDE_SETTINGS" || fail '(x) agents/claude/settings.hooks.json is valid JSON'
ok '(x) agents/claude/settings.hooks.json is valid JSON'
for spec in 'SessionStart session' 'UserPromptSubmit prompt' 'PermissionRequest permission' \
  'PostToolUse activity' 'Stop stop' 'StopFailure stop' 'SessionEnd end'; do
  set -- $spec
  grep -q "\"$1\"" "$CLAUDE_SETTINGS" || fail "(x) settings declares $1"
  grep -qF "tmux-agent-picker hook claude $2" "$CLAUDE_SETTINGS" || fail "(x) settings maps $1 to $2"
done
ok '(x) settings declares every mapped event'
! grep -qF 'TMUX_AGENT_PICKER_ROOT' "$CLAUDE_SETTINGS" || \
  fail '(x) settings needs no plugin root'
ok '(x) settings needs no plugin root'
! grep -q 'bin/agent-state' "$CLAUDE_SETTINGS" || fail '(x) settings never calls agent-state directly'
ok '(x) settings never calls agent-state directly'

run_state "$CLAUDE_PANE" clear
tmux_cmd kill-pane -t "$CLAUDE_PANE" 2>/dev/null || true

# (y) Codex CLI hook mapping and shipped hook file.
CODEX_PANE=$(new_pane codex-hook)
CODEX_PAYLOAD='{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp","hook_event_name":"Stop","model":"gpt-5","permission_mode":"default"}'
for spec in 'SessionStart session idle' 'UserPromptSubmit prompt working' \
  'PermissionRequest permission blocked' 'PostToolUse activity working' 'Stop stop done'; do
  set -- $spec
  out=$(hook "$CODEX_PANE" codex "$2" "$CODEX_PAYLOAD")
  assert_eq 0 "$?" "(y) $1 exits 0"
  assert_eq '' "$out" "(y) $1 prints nothing"
  assert_eq codex "$(pane_option "$CODEX_PANE" '#{@ap_agent}')" "(y) $1 stores codex"
  assert_eq "$3" "$(pane_option "$CODEX_PANE" '#{@ap_state}')" "(y) $1 maps to $3"
done
hook "$CODEX_PANE" codex prompt "$CODEX_PAYLOAD" >/dev/null
hook "$CODEX_PANE" codex interrupt "$CODEX_PAYLOAD" >/dev/null
assert_eq idle "$(pane_option "$CODEX_PANE" '#{@ap_state}')" '(y) Interrupt after working yields idle'
hook "$CODEX_PANE" codex end "$CODEX_PAYLOAD" >/dev/null
assert_eq '' "$(pane_option "$CODEX_PANE" '#{@ap_agent}')" '(y) SessionEnd removes agent'
assert_eq '' "$(pane_option "$CODEX_PANE" '#{@ap_state}')" '(y) SessionEnd removes state'
assert_eq '' "$(pane_option "$CODEX_PANE" '#{@ap_since}')" '(y) SessionEnd removes since'
hook "$CODEX_PANE" codex stop '{"session_id":"s1","turn_id":"t1","hook_event_name":"Stop"}' >/dev/null
assert_eq done "$(pane_option "$CODEX_PANE" '#{@ap_state}')" '(y) Stop with turn_id and no agent_id sets done'

printf '%s' "$CODEX_PAYLOAD" | TMUX_PANE=$CODEX_PANE \
  TMUX_AGENT_PICKER_BIN=$ROOT/bin/agent-state bash -c 'tmux-agent-picker hook codex prompt'
assert_eq working "$(pane_option "$CODEX_PANE" '#{@ap_state}')" '(y) shipped command form runs'

CODEX_HOOKS="$ROOT/agents/codex/hooks.json"
[[ -f $CODEX_HOOKS ]] || fail '(y) agents/codex/hooks.json exists'
json_valid "$CODEX_HOOKS" || fail '(y) agents/codex/hooks.json is valid JSON'
ok '(y) agents/codex/hooks.json is valid JSON'
if command -v jq >/dev/null 2>&1; then
  assert_eq 'Interrupt PermissionRequest PostToolUse SessionEnd SessionStart Stop UserPromptSubmit' \
    "$(jq -r '.hooks | keys | join(" ")' "$CODEX_HOOKS")" '(y) hook file declares exactly the mapped events'
  assert_eq 3 "$(jq -r '.hooks.SessionEnd[0].hooks[0].timeout' "$CODEX_HOOKS")" \
    '(y) SessionEnd uses the 3-second ceiling'
  assert_eq 3 "$(jq -r '.hooks.Interrupt[0].hooks[0].timeout' "$CODEX_HOOKS")" \
    '(y) Interrupt uses the 3-second ceiling'
  assert_eq 0 \
    "$(jq '[.hooks | to_entries[] | .key as $e | .value[] | .hooks[] | select($e != "SessionEnd" and $e != "Interrupt" and .timeout != 5)] | length' "$CODEX_HOOKS")" \
    '(y) other handlers use a 5-second timeout'
fi
for spec in 'SessionStart session' 'UserPromptSubmit prompt' 'PermissionRequest permission' \
  'PostToolUse activity' 'Stop stop' 'Interrupt interrupt' 'SessionEnd end'; do
  set -- $spec
  grep -q "\"$1\"" "$CODEX_HOOKS" || fail "(y) hooks declare $1"
  grep -qF "tmux-agent-picker hook codex $2" "$CODEX_HOOKS" || fail "(y) hooks map $1 to $2"
done
ok '(y) hooks declare every mapped event'
! grep -q 'bin/agent-state' "$CODEX_HOOKS" || fail '(y) hooks never call agent-state directly'
ok '(y) hooks never call agent-state directly'

run_state "$CODEX_PANE" clear
tmux_cmd kill-pane -t "$CODEX_PANE" 2>/dev/null || true

# (z) GitHub Copilot CLI hook mapping and shipped hook file.
COPILOT_PANE=$(new_pane copilot-hook)
COPILOT_PAYLOAD='{"sessionId":"s1","timestamp":1762500000000,"cwd":"/tmp"}'
COPILOT_STOP='{"sessionId":"s1","timestamp":1,"cwd":"/tmp","stopReason":"end_turn","stop_hook_active":false,"transcriptPath":"/tmp/t"}'
COPILOT_END='{"sessionId":"s1","timestamp":1,"cwd":"/tmp","reason":"complete"}'
for spec in 'sessionStart session idle' 'userPromptSubmitted prompt working' \
  'permissionRequest permission blocked' 'postToolUse activity working' \
  'postToolUseFailure activity working' 'agentStop stop done' 'errorOccurred stop done'; do
  set -- $spec
  payload=$COPILOT_PAYLOAD
  case "$1" in
    agentStop) payload=$COPILOT_STOP ;;
  esac
  out=$(hook "$COPILOT_PANE" copilot "$2" "$payload")
  assert_eq 0 "$?" "(z) $1 exits 0"
  assert_eq '' "$out" "(z) $1 prints nothing"
  assert_eq copilot "$(pane_option "$COPILOT_PANE" '#{@ap_agent}')" "(z) $1 stores copilot"
  assert_eq "$3" "$(pane_option "$COPILOT_PANE" '#{@ap_state}')" "(z) $1 maps to $3"
done
for reason in user_exit abort; do
  hook "$COPILOT_PANE" copilot prompt "$COPILOT_PAYLOAD" >/dev/null
  hook "$COPILOT_PANE" copilot end "{\"sessionId\":\"s1\",\"timestamp\":1,\"cwd\":\"/tmp\",\"reason\":\"$reason\"}" >/dev/null
  assert_eq '' "$(pane_option "$COPILOT_PANE" '#{@ap_state}')" "(z) sessionEnd $reason clears state"
done
hook "$COPILOT_PANE" copilot permission "$COPILOT_PAYLOAD" >/dev/null
hook "$COPILOT_PANE" copilot stop "$COPILOT_STOP" >/dev/null
assert_eq done "$(pane_option "$COPILOT_PANE" '#{@ap_state}')" '(z) agentStop after blocked yields done'

printf '%s' "$COPILOT_PAYLOAD" | TMUX_PANE=$COPILOT_PANE \
  TMUX_AGENT_PICKER_BIN=$ROOT/bin/agent-state bash -c 'tmux-agent-picker hook copilot prompt'
assert_eq working "$(pane_option "$COPILOT_PANE" '#{@ap_state}')" '(z) shipped command form runs'

COPILOT_HOOKS="$ROOT/agents/copilot/hooks.json"
[[ -f $COPILOT_HOOKS ]] || fail '(z) agents/copilot/hooks.json exists'
json_valid "$COPILOT_HOOKS" || fail '(z) agents/copilot/hooks.json is valid JSON'
ok '(z) agents/copilot/hooks.json is valid JSON'
if command -v jq >/dev/null 2>&1; then
  assert_eq 1 "$(jq -r '.version' "$COPILOT_HOOKS")" '(z) hook file declares version 1'
  assert_eq 'agentStop errorOccurred permissionRequest postToolUse postToolUseFailure sessionEnd sessionStart userPromptSubmitted' \
    "$(jq -r '.hooks | keys | join(" ")' "$COPILOT_HOOKS")" '(z) hook file declares exactly the mapped events'
  assert_eq 3 "$(jq -r '.hooks.sessionEnd[0].timeoutSec' "$COPILOT_HOOKS")" \
    '(z) sessionEnd uses a 3-second timeout'
  assert_eq 0 \
    "$(jq '[.hooks | to_entries[] | .key as $e | .value[] | select($e != "sessionEnd" and .timeoutSec != 5)] | length' "$COPILOT_HOOKS")" \
    '(z) other handlers use a 5-second timeout'
fi
for spec in 'sessionStart session' 'userPromptSubmitted prompt' 'permissionRequest permission' \
  'postToolUse activity' 'postToolUseFailure activity' 'agentStop stop' 'errorOccurred stop' \
  'sessionEnd end'; do
  set -- $spec
  grep -q "\"$1\"" "$COPILOT_HOOKS" || fail "(z) hooks declare $1"
  grep -qF "tmux-agent-picker hook copilot $2" "$COPILOT_HOOKS" || fail "(z) hooks map $1 to $2"
done
ok '(z) hooks declare every mapped event'
! grep -q 'bin/agent-state' "$COPILOT_HOOKS" || fail '(z) hooks never call agent-state directly'
ok '(z) hooks never call agent-state directly'

run_state "$COPILOT_PANE" clear
tmux_cmd kill-pane -t "$COPILOT_PANE" 2>/dev/null || true

# (ag) agy plugin mapping, conversation gate, and manifests.
AGY_RUNTIME="$TMP_ROOT/agy-runtime"
mkdir -p "$AGY_RUNTIME"
agy_hook() {  # pane payload verb
  printf '%s' "$2" | XDG_RUNTIME_DIR="$AGY_RUNTIME" TMUX_PANE=$1 \
    TMUX_AGENT_PICKER_BIN="$ROOT/bin/agent-state" "$ROOT/agents/agy/hook" "$3"
}
AGY_PANE=$(new_pane agy-hook)
AGY_PAYLOAD='{"conversationId":"root-1"}'
out=$(agy_hook "$AGY_PANE" "$AGY_PAYLOAD" session)
assert_eq 0 "$?" '(ag) session exits 0'
assert_eq '{}' "$out" '(ag) session prints exactly {}'
assert_eq agy "$(pane_option "$AGY_PANE" '#{@ap_agent}')" '(ag) session stores agy'
assert_eq idle "$(pane_option "$AGY_PANE" '#{@ap_state}')" '(ag) session maps to idle'
for spec in 'prompt working {}' 'permission blocked {"decision":"allow"}' 'activity working {}'; do
  set -- $spec
  out=$(agy_hook "$AGY_PANE" "$AGY_PAYLOAD" "$1")
  assert_eq 0 "$?" "(ag) $1 exits 0"
  assert_eq "$3" "$out" "(ag) $1 prints expected response"
  assert_eq "$2" "$(pane_option "$AGY_PANE" '#{@ap_state}')" "(ag) $1 maps to $2"
done
out=$(agy_hook "$AGY_PANE" '{"conversationId":"root-1","terminationReason":"NO_TOOL_CALL"}' stop)
assert_eq '{}' "$out" '(ag) stop prints exactly {}'
assert_eq done "$(pane_option "$AGY_PANE" '#{@ap_state}')" '(ag) normal stop maps to done'
agy_hook "$AGY_PANE" '{"conversationId":"root-1","terminationReason":"USER_CANCELED"}' stop >/dev/null
assert_eq idle "$(pane_option "$AGY_PANE" '#{@ap_state}')" '(ag) user cancel maps to idle'

agy_hook "$AGY_PANE" "$AGY_PAYLOAD" prompt >/dev/null
agy_hook "$AGY_PANE" '{"conversationId":"sub-9","terminationReason":"NO_TOOL_CALL"}' stop >/dev/null
assert_eq working "$(pane_option "$AGY_PANE" '#{@ap_state}')" '(ag) subagent stop is ignored'
AGY_FRESH_PANE=$(new_pane agy-fresh)
agy_hook "$AGY_FRESH_PANE" '{"terminationReason":"NO_TOOL_CALL"}' stop >/dev/null
assert_eq done "$(pane_option "$AGY_FRESH_PANE" '#{@ap_state}')" '(ag) stop without an id applies when none is stored'

for verb in session prompt permission activity stop interrupt end; do
  expected='{}'
  [[ $verb == permission ]] && expected='{"decision":"allow"}'
  out=$(agy_hook "$AGY_FRESH_PANE" 'not json' "$verb")
  assert_eq 0 "$?" "(ag) $verb exits 0 on unparsable stdin"
  assert_eq "$expected" "$out" "(ag) $verb prints expected json on unparsable stdin"
done
out=$(printf '{}' | XDG_RUNTIME_DIR="$AGY_RUNTIME" TMUX_PANE=$AGY_PANE \
  TMUX_AGENT_PICKER_BIN=/nonexistent "$ROOT/agents/agy/hook" session)
assert_eq 0 "$?" '(ag) missing agent-state exits 0'
assert_eq '{}' "$out" '(ag) missing agent-state prints exactly {}'

out=$(XDG_RUNTIME_DIR="$AGY_RUNTIME" TMUX_PANE='' "$ROOT/agents/agy/hook" permission)
assert_eq 0 "$?" '(ag) missing pane permission exits 0'
assert_eq '{"decision":"allow"}' "$out" '(ag) missing pane permission prints allow decision'

# agy loads the plugin through a symlinked directory, so the shim must reach the
# dispatcher instead of deriving a checkout path from BASH_SOURCE.
AGY_PLUGIN_LINK="$TMP_ROOT/agy-plugins"
mkdir -p "$AGY_PLUGIN_LINK"
ln -sfn "$ROOT/agents/agy" "$AGY_PLUGIN_LINK/tmux-agent-picker"
out=$(printf '{"conversationId":"root-1"}' | XDG_RUNTIME_DIR="$AGY_RUNTIME" TMUX_PANE=$AGY_PANE \
  TMUX_AGENT_PICKER_BIN="$ROOT/bin/agent-state" "$AGY_PLUGIN_LINK/tmux-agent-picker/hook" permission)
assert_eq '{"decision":"allow"}' "$out" '(ag) symlinked plugin hook prints allow decision'
assert_eq blocked "$(pane_option "$AGY_PANE" '#{@ap_state}')" \
  '(ag) symlinked plugin hook reports state'

AGY_PLUGIN="$ROOT/agents/agy/plugin.json"
AGY_HOOKS="$ROOT/agents/agy/hooks.json"
[[ -f $AGY_PLUGIN ]] || fail '(ag) agents/agy/plugin.json exists'
[[ -f $AGY_HOOKS ]] || fail '(ag) agents/agy/hooks.json exists'
json_valid "$AGY_PLUGIN" || fail '(ag) agents/agy/plugin.json is valid JSON'
json_valid "$AGY_HOOKS" || fail '(ag) agents/agy/hooks.json is valid JSON'
ok '(ag) plugin manifests are valid JSON'
if command -v jq >/dev/null 2>&1; then
  assert_eq 'PostToolUse PreInvocation PreToolUse SessionStart Stop' \
    "$(jq -r '.["tmux-agent-picker"] | keys | join(" ")' "$AGY_HOOKS")" \
    '(ag) hooks declare exactly the mapped events'
fi
for spec in 'SessionStart session' 'PreInvocation prompt' 'PreToolUse permission' \
  'PostToolUse activity' 'Stop stop'; do
  set -- $spec
  grep -q "\"$1\"" "$AGY_HOOKS" || fail "(ag) hooks declare $1"
  grep -qF '${PLUGIN_ROOT}/hook '"$2" "$AGY_HOOKS" || fail "(ag) hooks map $1 to $2"
done
ok '(ag) hooks declare every mapped event'
if command -v agy >/dev/null 2>&1; then
  AGY_VALIDATE=$(HOME="$TMP_ROOT/agy-home" agy plugin validate "$ROOT/agents/agy" 2>&1 || true)
  [[ $AGY_VALIDATE != *[Ee]rror* ]] || {
    printf '%s\n' "$AGY_VALIDATE" >&2
    fail '(ag) agy plugin validate reports no errors'
  }
  ok '(ag) agy plugin validate reports no errors'
else
  ok '(ag) agy not installed, skipping plugin validation'
fi

run_state "$AGY_PANE" clear
run_state "$AGY_FRESH_PANE" clear
tmux_cmd kill-pane -t "$AGY_PANE" 2>/dev/null || true
tmux_cmd kill-pane -t "$AGY_FRESH_PANE" 2>/dev/null || true

# (ai) agent-install installs, refreshes, reports, and removes file-based agents.
INSTALL_HOME="$TMP_ROOT/install-home"
installer() {  # home, then agent-install args
  local home=$1; shift
  HOME="$home" CLAUDE_CONFIG_DIR="$home/claude" \
    CODEX_HOME="$home/codex" COPILOT_HOME="$home/copilot" \
    "$ROOT/bin/agent-install" "$@"
}
find_installables() { find "$1" \( -type f -o -type l \) 2>/dev/null | sort; }
backup_count() { find "$1" -maxdepth 1 -name "$2" 2>/dev/null | wc -l | tr -d ' '; }

installer "$INSTALL_HOME" pi copilot agy --yes >"$TMP_ROOT/install-out" 2>&1
assert_eq 0 "$?" '(ai) install pi copilot agy exits 0'
assert_eq "$ROOT/agents/pi/agent-state.ts" \
  "$(readlink "$INSTALL_HOME/.pi/agent/extensions/agent-state.ts")" \
  '(ai) pi extension link points at the checkout'
assert_eq "$ROOT/agents/agy" \
  "$(readlink "$INSTALL_HOME/.gemini/config/plugins/tmux-agent-picker")" \
  '(ai) agy plugin link points at the checkout'
assert_eq "$ROOT/bin/tmux-agent-picker" \
  "$(readlink "$INSTALL_HOME/.local/bin/tmux-agent-picker")" \
  '(ai) install links the dispatcher onto PATH'
COPILOT_INSTALLED="$INSTALL_HOME/copilot/hooks/tmux-agent-picker.json"
[[ -f $COPILOT_INSTALLED ]] || fail '(ai) copilot hooks file is written'
json_valid "$COPILOT_INSTALLED" || fail '(ai) copilot hooks file is valid JSON'
if command -v jq >/dev/null 2>&1; then
  assert_eq 1 "$(jq -r '.version' "$COPILOT_INSTALLED")" '(ai) copilot hooks keep version 1'
  assert_eq 'agentStop errorOccurred permissionRequest postToolUse postToolUseFailure sessionEnd sessionStart userPromptSubmitted' \
    "$(jq -r '.hooks | keys | join(" ")' "$COPILOT_INSTALLED")" \
    '(ai) copilot hooks declare exactly the eight events'
  assert_eq 8 \
    "$(jq '[.hooks[][] | select(.bash | contains("tmux-agent-picker hook copilot "))] | length' \
      "$COPILOT_INSTALLED")" \
    '(ai) copilot handlers call the tmux-agent-picker dispatcher'
fi
[[ $(wc -l <"$COPILOT_INSTALLED" | tr -d ' ') -gt 8 ]] || \
  fail '(ai) copilot hooks file is pretty printed'
ok '(ai) copilot hooks file is pretty printed'

before_sum=$(cksum "$COPILOT_INSTALLED")
before_baks=$(backup_count "$COPILOT_INSTALLED" 'tmux-agent-picker.json.bak.*')
installer "$INSTALL_HOME" pi copilot agy --yes >"$TMP_ROOT/install-out2" 2>&1
assert_eq 0 "$?" '(ai) refresh exits 0'
grep -q unchanged "$TMP_ROOT/install-out2" || fail '(ai) refresh reports unchanged'
assert_eq "$before_sum" "$(cksum "$COPILOT_INSTALLED")" '(ai) refresh leaves copilot hooks unchanged'
assert_eq "$before_baks" \
  "$(backup_count "$COPILOT_INSTALLED" 'tmux-agent-picker.json.bak.*')" \
  '(ai) refresh creates no backup'

status=$(installer "$INSTALL_HOME" --status pi copilot agy 2>&1)
printf '%s\n' "$status" | grep -Eq '^pi[[:space:]].*installed' || fail '(ai) status reports pi installed'
printf '%s\n' "$status" | grep -Eq '^copilot[[:space:]].*installed' || fail '(ai) status reports copilot installed'
printf '%s\n' "$status" | grep -Eq '^agy[[:space:]].*installed' || fail '(ai) status reports agy installed'
ok '(ai) status reports every installed agent'

UNMANAGED_HOME="$TMP_ROOT/install-unmanaged"
mkdir -p "$UNMANAGED_HOME/.pi/agent/extensions"
printf 'stale\n' >"$UNMANAGED_HOME/.pi/agent/extensions/agent-state.ts"
status=$(installer "$UNMANAGED_HOME" --status pi 2>&1)
printf '%s\n' "$status" | grep -Eq '^pi[[:space:]].*not installed' || \
  fail '(ai) status reports an unmanaged target as not installed'
! printf '%s\n' "$status" | grep -q conflict || fail '(ai) status no longer reports conflict'
ok '(ai) status reports an unmanaged target as not installed'

DRY_HOME="$TMP_ROOT/install-dry"
mkdir -p "$DRY_HOME"
dry_out=$(installer "$DRY_HOME" pi copilot agy --dry-run 2>&1)
assert_eq 0 "$?" '(ai) dry run exits 0'
[[ $dry_out == *'would install'* ]] || fail '(ai) dry run reports would install'
assert_eq '' "$(find_installables "$DRY_HOME")" '(ai) dry run writes nothing'

# --link puts the dispatcher on PATH without writing any agent config.
LINK_HOME="$TMP_ROOT/install-link"
mkdir -p "$LINK_HOME"
installer "$LINK_HOME" --link >"$TMP_ROOT/link-out" 2>&1
assert_eq 0 "$?" '(ai) --link exits 0'
assert_eq "$ROOT/bin/tmux-agent-picker" \
  "$(readlink "$LINK_HOME/.local/bin/tmux-agent-picker")" \
  '(ai) --link creates the dispatcher link'
assert_eq '' "$(find "$LINK_HOME" -mindepth 2 -not -path "$LINK_HOME/.local/*" 2>/dev/null)" \
  '(ai) --link writes no agent config'
installer "$LINK_HOME" --link >"$TMP_ROOT/link-out2" 2>&1
grep -q 'unchanged cli' "$TMP_ROOT/link-out2" || fail '(ai) --link is idempotent'
ok '(ai) --link is idempotent'
HOME="$LINK_HOME" "$ROOT/bin/tmux-agent-picker" link >/dev/null 2>&1
assert_eq 0 "$?" '(ai) dispatcher link subcommand exits 0'
# The link is what PATH resolves, so the dispatcher must find the checkout through it.
HOME="$LINK_HOME" "$LINK_HOME/.local/bin/tmux-agent-picker" status >"$TMP_ROOT/link-status" 2>&1
assert_eq 0 "$?" '(ai) dispatcher runs through its PATH link'
grep -q '^cli' "$TMP_ROOT/link-status" || fail '(ai) linked dispatcher reports the cli row'
ok '(ai) linked dispatcher reports the cli row'
installer "$LINK_HOME" --link pi >/dev/null 2>&1
[[ $? -ne 0 ]] || fail '(ai) --link refuses agent names'
ok '(ai) --link refuses agent names'
LINK_DRY_HOME="$TMP_ROOT/install-link-dry"
mkdir -p "$LINK_DRY_HOME"
installer "$LINK_DRY_HOME" --link --dry-run >/dev/null 2>&1
assert_eq '' "$(find_installables "$LINK_DRY_HOME")" '(ai) --link dry run writes nothing'

installer "$INSTALL_HOME" --uninstall pi copilot agy --yes >"$TMP_ROOT/uninstall-out" 2>&1
assert_eq 0 "$?" '(ai) uninstall exits 0'
[[ ! -e $INSTALL_HOME/.pi/agent/extensions/agent-state && ! -L $INSTALL_HOME/.pi/agent/extensions/agent-state ]] || \
  fail '(ai) uninstall removes the pi link'
[[ ! -e $INSTALL_HOME/.gemini/config/plugins/tmux-agent-picker && ! -L $INSTALL_HOME/.gemini/config/plugins/tmux-agent-picker ]] || \
  fail '(ai) uninstall removes the agy link'
[[ ! -f $COPILOT_INSTALLED ]] || fail '(ai) uninstall removes the copilot hooks file'
[[ ! -e $INSTALL_HOME/.local/bin/tmux-agent-picker && ! -L $INSTALL_HOME/.local/bin/tmux-agent-picker ]] || \
  fail '(ai) uninstall removes the dispatcher link'
ok '(ai) uninstall removes every installed target'
status=$(installer "$INSTALL_HOME" --status pi copilot agy 2>&1)
printf '%s\n' "$status" | grep -Eq '^pi[[:space:]].*missing' || fail '(ai) status reports pi missing'
printf '%s\n' "$status" | grep -Eq '^copilot[[:space:]].*missing' || fail '(ai) status reports copilot missing'
printf '%s\n' "$status" | grep -Eq '^agy[[:space:]].*missing' || fail '(ai) status reports agy missing'
ok '(ai) status reports every removed agent as missing'

USAGE_HOME="$TMP_ROOT/install-usage"
mkdir -p "$USAGE_HOME"
for args in 'bogus' '' '--all pi'; do
  # shellcheck disable=SC2086  # Word splitting builds the argument list on purpose.
  installer "$USAGE_HOME" $args >/dev/null 2>&1
  [[ $? -ne 0 ]] || fail "(ai) usage error for: $args"
done
ok '(ai) usage errors exit non-zero'
assert_eq '' "$(find_installables "$USAGE_HOME")" '(ai) usage errors install nothing'

# (aj) agent-install merges Claude and Codex hooks without losing user config.
MERGE_HOME="$TMP_ROOT/merge-home"
mkdir -p "$MERGE_HOME/claude" "$MERGE_HOME/codex"
CLAUDE_FILE="$MERGE_HOME/claude/settings.json"
CODEX_FILE="$MERGE_HOME/codex/hooks.json"
cat >"$CLAUDE_FILE" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "echo existing-session", "timeout": 5 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "echo existing-stop", "timeout": 5 } ] }
    ]
  }
}
JSON
cat >"$CODEX_FILE" <<'JSON'
{"description":"my hooks","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo existing-stop","timeout":5}]}]}}
JSON

marker_groups() {  # file event marker
  jq --arg ev "$2" --arg marker "$3" \
    '[.hooks[$ev][]? | select([.hooks[]? | .command // ""] | any(contains($marker)))] | length' "$1"
}
managed_command() {  # file event marker
  jq -r --arg ev "$2" --arg marker "$3" \
    'first(.hooks[$ev][]? | select([.hooks[]? | .command // ""] | any(contains($marker))) | .hooks[0].command) // empty' "$1"
}
managed_timeout() {  # file event marker
  jq -r --arg ev "$2" --arg marker "$3" \
    'first(.hooks[$ev][]? | select([.hooks[]? | .command // ""] | any(contains($marker))) | .hooks[0].timeout) // empty' "$1"
}
canonical() { jq -S -c . "$1"; }
MERGE_EVENTS_CLAUDE='SessionStart UserPromptSubmit PermissionRequest PostToolUse Stop StopFailure SessionEnd'
MERGE_EVENTS_CODEX='SessionStart UserPromptSubmit PermissionRequest PostToolUse Stop Interrupt SessionEnd'

if command -v jq >/dev/null 2>&1; then
installer "$MERGE_HOME" claude codex --yes >"$TMP_ROOT/merge-out" 2>&1
assert_eq 0 "$?" '(aj) merge install exits 0'
assert_eq 1 "$(backup_count "$MERGE_HOME/claude" 'settings.json.bak.*')" \
  '(aj) claude settings are backed up'
[[ $(wc -l <"$CLAUDE_FILE" | tr -d ' ') -gt 10 ]] || fail '(aj) claude settings are pretty printed'
[[ $(wc -l <"$CODEX_FILE" | tr -d ' ') -gt 10 ]] || fail '(aj) codex hooks are pretty printed'
ok '(aj) merged JSON is pretty printed for humans'
assert_eq 1 "$(backup_count "$MERGE_HOME/codex" 'hooks.json.bak.*')" \
  '(aj) codex hooks are backed up'

assert_eq opus "$(jq -r '.model' "$CLAUDE_FILE")" '(aj) claude keeps unrelated top-level keys'
assert_eq 1 "$(jq '[.hooks.SessionStart[].hooks[].command | select(contains("echo existing-session"))] | length' "$CLAUDE_FILE")" \
  '(aj) claude keeps the existing SessionStart group'
assert_eq 1 "$(jq '[.hooks.Stop[].hooks[].command | select(contains("echo existing-stop"))] | length' "$CLAUDE_FILE")" \
  '(aj) claude keeps the existing Stop group'
for ev in $MERGE_EVENTS_CLAUDE; do
  assert_eq 1 "$(marker_groups "$CLAUDE_FILE" "$ev" 'tmux-agent-picker hook claude ')" \
    "(aj) claude $ev has exactly one managed group"
done
assert_match 'tmux-agent-picker hook claude end' \
  "$(managed_command "$CLAUDE_FILE" SessionEnd 'tmux-agent-picker hook claude ')" \
  '(aj) claude SessionEnd maps to end'
! grep -qF "$ROOT" "$CLAUDE_FILE" || fail '(aj) claude commands carry no checkout path'
! grep -qF 'TMUX_AGENT_PICKER_ROOT' "$CLAUDE_FILE" || \
  fail '(aj) claude commands need no plugin root'
ok '(aj) claude hooks carry no checkout path'

# Entries written before the dispatcher rename are still recognised.
LEGACY_HOME="$TMP_ROOT/legacy-home"
mkdir -p "$LEGACY_HOME/claude"
LEGACY_FILE="$LEGACY_HOME/claude/settings.json"
cat >"$LEGACY_FILE" <<'JSON'
{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"\"${TMUX_AGENT_PICKER_ROOT:-/old}/bin/agent-hook\" claude end","timeout":5}]}]}}
JSON
installer "$LEGACY_HOME" claude --yes >"$TMP_ROOT/legacy-out" 2>&1
assert_eq 0 "$?" '(aj) legacy install exits 0'
assert_eq 0 \
  "$(jq '[.hooks.SessionEnd[].hooks[].command | select(contains("agent-hook\" claude "))] | length' "$LEGACY_FILE")" \
  '(aj) legacy claude entries are replaced'
assert_eq 1 "$(marker_groups "$LEGACY_FILE" SessionEnd 'tmux-agent-picker hook claude ')" \
  '(aj) legacy claude entries become dispatcher entries'

assert_eq 'my hooks' "$(jq -r '.description' "$CODEX_FILE")" '(aj) codex keeps its description'
assert_eq 1 "$(jq '[.hooks.Stop[].hooks[].command | select(contains("echo existing-stop"))] | length' "$CODEX_FILE")" \
  '(aj) codex keeps the existing Stop group'
for ev in $MERGE_EVENTS_CODEX; do
  assert_eq 1 "$(marker_groups "$CODEX_FILE" "$ev" 'tmux-agent-picker hook codex ')" \
    "(aj) codex $ev has exactly one managed group"
done
for ev in Interrupt SessionEnd; do
  assert_eq 3 "$(managed_timeout "$CODEX_FILE" "$ev" 'tmux-agent-picker hook codex ')" \
    "(aj) codex $ev uses a 3 second timeout"
done
for ev in SessionStart UserPromptSubmit PermissionRequest PostToolUse Stop; do
  assert_eq 5 "$(managed_timeout "$CODEX_FILE" "$ev" 'tmux-agent-picker hook codex ')" \
    "(aj) codex $ev uses a 5 second timeout"
done
! grep -qF "$ROOT" "$CODEX_FILE" || fail '(aj) codex commands carry no checkout path'
ok '(aj) codex hooks carry no checkout path'

claude_sum=$(canonical "$CLAUDE_FILE")
codex_sum=$(canonical "$CODEX_FILE")
claude_baks=$(backup_count "$MERGE_HOME/claude" 'settings.json.bak.*')
codex_baks=$(backup_count "$MERGE_HOME/codex" 'hooks.json.bak.*')
installer "$MERGE_HOME" claude codex --yes >"$TMP_ROOT/merge-out2" 2>&1
assert_eq 0 "$?" '(aj) merge refresh exits 0'
grep -q 'unchanged claude' "$TMP_ROOT/merge-out2" || fail '(aj) refresh reports claude unchanged'
grep -q 'unchanged codex' "$TMP_ROOT/merge-out2" || fail '(aj) refresh reports codex unchanged'
assert_eq "$claude_sum" "$(canonical "$CLAUDE_FILE")" '(aj) claude refresh changes nothing'
assert_eq "$codex_sum" "$(canonical "$CODEX_FILE")" '(aj) codex refresh changes nothing'
assert_eq "$claude_baks" "$(backup_count "$MERGE_HOME/claude" 'settings.json.bak.*')" \
  '(aj) claude refresh adds no backup'
assert_eq "$codex_baks" "$(backup_count "$MERGE_HOME/codex" 'hooks.json.bak.*')" \
  '(aj) codex refresh adds no backup'

status=$(installer "$MERGE_HOME" --status claude codex 2>&1)
printf '%s\n' "$status" | grep -Eq '^claude[[:space:]].*installed' || fail '(aj) status reports claude installed'
printf '%s\n' "$status" | grep -Eq '^codex[[:space:]].*installed' || fail '(aj) status reports codex installed'
ok '(aj) status reports merged agents installed'

installer "$MERGE_HOME" --uninstall claude codex --yes >"$TMP_ROOT/merge-out3" 2>&1
assert_eq 0 "$?" '(aj) merge uninstall exits 0'
assert_eq opus "$(jq -r '.model' "$CLAUDE_FILE")" '(aj) uninstall keeps claude top-level keys'
assert_eq 1 "$(jq '[.hooks.SessionStart[].hooks[].command | select(contains("echo existing-session"))] | length' "$CLAUDE_FILE")" \
  '(aj) uninstall keeps the existing claude SessionStart group'
assert_eq 1 "$(jq '[.hooks.Stop[].hooks[].command | select(contains("echo existing-stop"))] | length' "$CLAUDE_FILE")" \
  '(aj) uninstall keeps the existing claude Stop group'
! grep -qF 'tmux-agent-picker hook claude ' "$CLAUDE_FILE" || fail '(aj) uninstall removes claude markers'
! grep -qF 'agent-hook" claude ' "$CLAUDE_FILE" || fail '(aj) uninstall removes legacy claude markers'
[[ -f $CODEX_FILE ]] || fail '(aj) uninstall keeps the codex file with user hooks'
assert_eq 'my hooks' "$(jq -r '.description' "$CODEX_FILE")" '(aj) uninstall keeps the codex description'
assert_eq 1 "$(jq '[.hooks.Stop[].hooks[].command | select(contains("echo existing-stop"))] | length' "$CODEX_FILE")" \
  '(aj) uninstall keeps the existing codex Stop group'
! grep -qF 'tmux-agent-picker hook codex ' "$CODEX_FILE" || fail '(aj) uninstall removes codex markers'
! grep -qF 'agent-hook" codex ' "$CODEX_FILE" || fail '(aj) uninstall removes legacy codex markers'
ok '(aj) selective uninstall preserves user hooks'

CODEX_ONLY_HOME="$TMP_ROOT/codex-only-home"
installer "$CODEX_ONLY_HOME" codex --yes >/dev/null 2>&1
assert_eq 0 "$?" '(aj) clean codex install exits 0'
[[ -f "$CODEX_ONLY_HOME/codex/hooks.json" ]] || fail '(aj) clean codex install writes hooks.json'
installer "$CODEX_ONLY_HOME" --uninstall codex --yes >/dev/null 2>&1
assert_eq 0 "$?" '(aj) clean codex uninstall exits 0'
[[ ! -f "$CODEX_ONLY_HOME/codex/hooks.json" ]] || \
  fail '(aj) clean codex uninstall removes the file it created'
ok '(aj) codex uninstall deletes a file this checkout created'

claude_sum=$(canonical "$CLAUDE_FILE")
codex_sum=$(canonical "$CODEX_FILE")
claude_baks=$(backup_count "$MERGE_HOME/claude" 'settings.json.bak.*')
codex_baks=$(backup_count "$MERGE_HOME/codex" 'hooks.json.bak.*')
installer "$MERGE_HOME" claude codex --dry-run >"$TMP_ROOT/merge-dry" 2>&1
assert_eq 0 "$?" '(aj) merge dry run exits 0'
assert_eq "$claude_sum" "$(canonical "$CLAUDE_FILE")" '(aj) claude dry run changes nothing'
assert_eq "$codex_sum" "$(canonical "$CODEX_FILE")" '(aj) codex dry run changes nothing'
assert_eq "$claude_baks" "$(backup_count "$MERGE_HOME/claude" 'settings.json.bak.*')" \
  '(aj) claude dry run adds no backup'
assert_eq "$codex_baks" "$(backup_count "$MERGE_HOME/codex" 'hooks.json.bak.*')" \
  '(aj) codex dry run adds no backup'

printf '{not json\n' >"$CLAUDE_FILE"
claude_baks=$(backup_count "$MERGE_HOME/claude" 'settings.json.bak.*')
installer "$MERGE_HOME" claude --yes >/dev/null 2>&1
assert_eq 2 "$?" '(aj) unparseable claude settings exit 2'
assert_eq '{not json' "$(cat "$CLAUDE_FILE")" '(aj) unparseable claude settings are untouched'
assert_eq "$claude_baks" "$(backup_count "$MERGE_HOME/claude" 'settings.json.bak.*')" \
  '(aj) unparseable claude settings create no backup'
ok '(aj) invalid JSON is left untouched without a backup'
else
  ok '(aj) jq not installed, skipping merge tests'
fi

# The empty list keeps the new-session key reachable.
for pane in "${ORDER_PANES[@]}"; do
  run_state "$pane" clear
done
PICKER=$(tmux_cmd new-window -d -t ap-test: -n ap-empty "exec \"$INSTALL_ROOT/bin/agent-pick\"")
PICKER=$(tmux_cmd display-message -p -t ap-test:ap-empty '#{pane_id}')
wait_for "$PICKER" 'no agents' || fail '(o) empty list shows its footer'
ok '(o) empty list shows its footer'
tmux_cmd send-keys -t "$PICKER" Escape
for i in $(seq 1 100); do
  [[ $(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}') == 1 ]] && break
  sleep 0.05
done
assert_eq 1 "$(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}')" '(o) empty picker closes normally'

printf 'all tests passed\n'

