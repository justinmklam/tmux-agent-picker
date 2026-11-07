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
[[ $SCREEN == *'x kill'* ]] || fail '(o) footer advertises the kill key'
ok '(o) footer advertises the kill key'

# (o2) x kills the session under the cursor only after y/N confirmation.
DOOMED_PANE=$(tmux_cmd new-session -d -P -F '#{pane_id}' -s doomed -c "$TMP_ROOT" 'exec sleep 3600')
run_state "$DOOMED_PANE" set pi blocked
tmux_cmd set-option -pt "$DOOMED_PANE" @ap_since "$(date +%s)"
KILLER=$(tmux_cmd new-window -d -P -F '#{pane_id}' -t ap-test: -n ap-killer "exec \"$INSTALL_ROOT/bin/agent-pick\"")
wait_for "$KILLER" 'Enter go' || fail '(o2) killer picker did not start'
FIRST_ROW=$(tmux_cmd capture-pane -p -t "$KILLER" | grep -E 'blocked[[:space:]]+pi|session[[:space:]]' | head -n 1)
[[ $FIRST_ROW == *doomed* ]] || {
  printf '%s\n' "$FIRST_ROW" >&2
  fail '(o2) newest blocked row sorts first'
}
tmux_cmd send-keys -t "$KILLER" x
wait_for "$KILLER" 'kill session doomed? [y/N]' || fail '(o2) x prompts before killing'
ok '(o2) x prompts before killing'
tmux_cmd send-keys -t "$KILLER" n
wait_for_normal "$KILLER" || fail '(o2) declining returns to the picker'
[[ -n $(tmux_cmd list-sessions -F '#{session_name}' | grep -x -- doomed || true) ]] || fail '(o2) declining keeps the session'
ok '(o2) declining keeps the session'

tmux_cmd send-keys -t "$KILLER" x
wait_for "$KILLER" 'kill session doomed? [y/N]' || fail '(o2) x prompts again after declining'
tmux_cmd send-keys -t "$KILLER" y
for i in $(seq 1 100); do
  [[ -z $(tmux_cmd list-sessions -F '#{session_name}' | grep -x -- doomed || true) ]] && break
  sleep 0.05
done
assert_eq '' "$(tmux_cmd list-sessions -F '#{session_name}' | grep -x -- doomed || true)" '(o2) confirmation kills the session'
wait_for_normal "$KILLER" || fail '(o2) picker stays open after killing'
for i in $(seq 1 100); do
  SCREEN=$(tmux_cmd capture-pane -p -t "$KILLER")
  [[ $SCREEN != *doomed* ]] && break
  sleep 0.05
done
[[ $SCREEN != *doomed* ]] || {
  printf '%s\n' "$SCREEN" >&2
  fail '(o2) reload drops the killed session row'
}
ok '(o2) reload drops the killed session row'

# (o3) the session running the picker is protected from the kill key.
tmux_cmd send-keys -t "$KILLER" x
wait_for "$KILLER" 'refusing to kill the current session' || fail '(o3) refuses to kill the current session'
ok '(o3) refuses to kill the current session'
tmux_cmd send-keys -t "$KILLER" z
wait_for_normal "$KILLER" || fail '(o3) returns to the picker after refusing'
[[ -n $(tmux_cmd list-sessions -F '#{session_name}' | grep -x -- ap-test || true) ]] || fail '(o3) keeps the current session'
ok '(o3) keeps the current session'
tmux_cmd send-keys -t "$KILLER" q

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

for pane in "$CLAUDE_PANE" "$CODEX_PANE" "$CODEX_CHILD_PANE" "$CODEX_DEPTH_PANE" "$NODE_PANE" "$MYTOOL_PANE"; do
  tmux_cmd kill-pane -t "$pane" 2>/dev/null || true
done

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

