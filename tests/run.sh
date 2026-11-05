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

# A dedicated server started from an explicit command gives every test pane a stable shell context.
tmux -L "$SERVER" -f /dev/null new-session -d -s ap-test -c "$TMP_ROOT" 'exec sleep 3600'
SERVER_INFO=$(tmux_cmd display-message -p '#{socket_path},#{pid},0')
export TMUX=$SERVER_INFO

new_pane() {
  local name=$1 command=${2:-'exec sleep 3600'}
  tmux_cmd new-window -d -n "$name" "$command"
  tmux_cmd display-message -p -t "ap-test:$name" '#{pane_id}'
}

pane_option() {
  tmux_cmd display-message -p -t "$1" "$2"
}

run_state() {
  TMUX_PANE=$1 "$ROOT/bin/agent-state" "${@:2}"
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
assert_match $'blocked codex[[:space:]]' "$LIST" '(a) lists another agent'
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
EXPECTED=$(printf '%s,' "${ORDER_PANES[1]}" "${ORDER_PANES[0]}" "${ORDER_PANES[2]}" "${ORDER_PANES[3]}" "${ORDER_PANES[4]}" | sed 's/,$//')
assert_eq "$EXPECTED" "$ORDER" '(g) orders state tiers and newest first'

# (h) bare shells are stale and hidden.
SHELL_PANE=$(new_pane shell 'exec sh')
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

tmux_cmd source-file "$ROOT/tmux/tmux-agent-picker.tmux.conf"
# This harness has no attached tty client, so A7 uses its documented fallback:
# verify the client-qualified binding here and rely on human verification for
# pressing prefix+a and confirming only that client switches.
KEY=$(tmux_cmd list-keys -T prefix a)
assert_match 'display-popup.*agent-pick --client' "$KEY" '(q) binds popup to the pressing client'
tmux_cmd source-file "$ROOT/tmux/tmux-agent-picker.tmux.conf"
for hook in pane-focus-in after-select-pane after-select-window client-session-changed; do
  count=$(tmux_cmd show-hooks -g "$hook" 2>/dev/null | grep -c 'agent-state seen' || true)
  assert_eq 1 "$count" "(q) $hook hook is not duplicated"
done

PICKER=$(tmux_cmd new-window -d -t ap-test: -n ap-picker "exec $ROOT/bin/agent-pick")
PICKER=$(tmux_cmd display-message -p -t ap-test:ap-picker '#{pane_id}')
wait_for "$PICKER" 'Enter go' || fail '(o) picker did not start'
SCREEN=$(tmux_cmd capture-pane -p -t "$PICKER")
[[ $SCREEN == *'blocked pi'* && $SCREEN == *'done pi'* && $SCREEN == *'idle pi'* && $SCREEN == *'working pi'* ]] || fail '(o) shows ordered agent rows'
ORDER=$(printf '%s\n' "$SCREEN" | grep -E 'blocked pi|done pi|idle pi|working pi' | sed -E 's/.*(blocked|done|idle|working) pi.*/\1/' | paste -sd, -)
assert_eq 'blocked,blocked,done,idle,working' "$ORDER" '(o) preserves computed row order'
ok '(o) shows ordered agent rows'
[[ $SCREEN != *'type to filter'* ]] || fail '(o) hides input in normal mode'
ok '(o) hides input in normal mode'
ROWS_BEFORE=$(printf '%s\n' "$SCREEN" | grep -E 'blocked pi|done pi|idle pi|working pi' || true)
tmux_cmd send-keys -t "$PICKER" x
sleep 0.2
ROWS_AFTER=$(tmux_cmd capture-pane -p -t "$PICKER" | grep -E 'blocked pi|done pi|idle pi|working pi' || true)
for state in blocked done idle working; do
  before_count=$(printf '%s\n' "$ROWS_BEFORE" | grep -c "$state pi" || true)
  after_count=$(printf '%s\n' "$ROWS_AFTER" | grep -c "$state pi" || true)
  assert_eq "$before_count" "$after_count" "(o) keeps $state rows after unbound key"
done

tmux_cmd send-keys -t "$PICKER" /
wait_for "$PICKER" 'type to filter' || fail '(p) filter mode did not open'
tmux_cmd send-keys -t "$PICKER" n X
wait_for "$PICKER" 'nX' || fail '(p) query was not accepted'
ok '(p) lets n type while filtering'
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

PICKER=$(tmux_cmd new-window -d -t ap-test: -n ap-picker2 "exec $ROOT/bin/agent-pick")
PICKER=$(tmux_cmd display-message -p -t ap-test:ap-picker2 '#{pane_id}')
wait_for "$PICKER" 'Enter go' || fail '(r) picker did not start'
tmux_cmd send-keys -t "$PICKER" n
wait_for "$PICKER" 'Enter open/switch' || fail '(r) directory picker did not open'
ok '(r) n opens directory picker'
tmux_cmd send-keys -t "$PICKER" Escape
wait_for "$PICKER" 'Enter go' || fail '(r) Esc did not return to agents'
ok '(r) Esc returns to agent picker'
tmux_cmd send-keys -t "$PICKER" n
wait_for "$PICKER" 'Enter open/switch' || fail '(s) directory picker did not reopen'
tmux_cmd send-keys -t "$PICKER" -l -- '/no/such/dir'
tmux_cmd send-keys -t "$PICKER" Enter
wait_for "$PICKER" 'no such directory' || fail '(s) invalid directory was not reported'
assert_eq 0 "$(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}')" '(s) invalid directory keeps picker alive'
ok '(s) invalid directory keeps picker alive'

# Successful Enter must resolve the query and create the selected session.
ENTER_DIR="$TMP_ROOT/enter-dir"
mkdir -p "$ENTER_DIR"
PICKER=$(tmux_cmd new-window -d -t ap-test: -n ap-picker3 "exec $ROOT/bin/agent-pick")
PICKER=$(tmux_cmd display-message -p -t ap-test:ap-picker3 '#{pane_id}')
wait_for "$PICKER" 'Enter go' || fail '(r) success picker did not start'
tmux_cmd send-keys -t "$PICKER" n
wait_for "$PICKER" 'Enter open/switch' || fail '(r) success directory picker did not open'
tmux_cmd send-keys -t "$PICKER" -l -- "$ENTER_DIR"
tmux_cmd send-keys -t "$PICKER" Enter
for i in $(seq 1 100); do
  [[ $(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}') == 1 ]] && break
  sleep 0.05
done
assert_eq 1 "$(tmux_cmd display-message -p -t "$PICKER" '#{pane_dead}')" '(r) Enter closes after opening a directory'
assert_eq "$ENTER_DIR" "$(tmux_cmd display-message -p -t enter-dir '#{session_path}')" '(r) Enter creates the selected session'

# The empty list keeps the new-session key reachable.
for pane in "${ORDER_PANES[@]}"; do
  run_state "$pane" clear
done
PICKER=$(tmux_cmd new-window -d -t ap-test: -n ap-empty "exec $ROOT/bin/agent-pick")
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

