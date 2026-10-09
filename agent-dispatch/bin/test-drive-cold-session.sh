#!/usr/bin/env bash
# Exercise the cold-session driver against real tmux and disposable agent stubs.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$SELF_DIR/drive-cold-session.sh"
if ! command -v tmux >/dev/null 2>&1; then
  if [[ "${CI:-}" == "true" ]]; then echo 'FAIL: tmux not installed' >&2; exit 1; fi
  echo 'SKIP: tmux not installed'
  exit 0
fi

TMP="$(mktemp -d)"
TMUX_TMPDIR="$(mktemp -d)"
export TMUX_TMPDIR
unset TMUX
trap 'tmux kill-server 2>/dev/null || true; rm -rf "$TMP" "$TMUX_TMPDIR"' EXIT
mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"
printf 'the prompt\n' > "$TMP/prompt"
export MARK="$TMP/marker"
export DCS_INTERVAL=1 DCS_STABLE=2 DCS_BOOT_MAX=6 DCS_SETTLE_MAX=10

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_rc() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" -eq "$expected" ]] || fail "$label: rc $actual, expected $expected; stderr: $(cat "$TMP/err")"
}
run_case() {
  local agent="$1" sess="$2"; shift 2
  env -u TMUX TMUX_TMPDIR="$TMUX_TMPDIR" "$DRIVER" "$agent" "$TMP" "$TMP/prompt" "$sess" "$@" > "$TMP/out" 2> "$TMP/err"
  rc=$?
}
stop_session() { tmux kill-session -t "=$1" 2>/dev/null || true; }
write_alt() {
  local lines="$1"
  cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '\033[?1049h\033[H\033[2J> '
read -r _
printf '\033[H\033[2J'
for i in $(seq -w 1 "$LINES_TO_PRINT"); do printf 'REPLY-%s\r\n' "$i"; done
printf END-OF-REPLY
sleep 300
STUB
  chmod +x "$TMP/bin/claude"
  export LINES_TO_PRINT="$lines"
}
write_codex_interstitial() {
  local title="$1"
  cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n1. Cancel\n2. Run without daemon this time\n' "$TITLE"
read -r _
touch "$MARK"
STUB
  chmod +x "$TMP/bin/codex"
  export TITLE="$title"
}

write_alt 60
DCS_KILL=0 run_case claude dcs_alt60
assert_rc 0 "$rc" '60-line alternate screen'
[[ "$(grep -c '^REPLY-' "$TMP/out")" -eq 60 ]] || fail '60-line reply was cut'
grep -q 'REPLY-01' "$TMP/out" || fail 'missing first reply row'
grep -q 'END-OF-REPLY' "$TMP/out" || fail 'missing reply end'
[[ "$(tmux display -p -t '=dcs_alt60:' '#{pane_width}x#{pane_height}')" == '200x200' ]] || fail 'default pane size'
stop_session dcs_alt60
echo 'PASS: alternate screen and default pane size'

write_alt 10
DCS_KILL=0 DCS_COLS=120 DCS_ROWS=50 run_case claude dcs_size
assert_rc 0 "$rc" 'custom pane size'
[[ "$(tmux display -p -t '=dcs_size:' '#{pane_width}x#{pane_height}')" == '120x50' ]] || fail 'custom pane size'
stop_session dcs_size
echo 'PASS: custom pane size'

for title in 'Background server has incompatible feature settings' 'Cannot use the background server'; do
  write_codex_interstitial "$title"
  sess="dcs_daemon_${title%% *}"
  run_case codex "$sess"
  assert_rc 4 "$rc" "$title"
  grep -qi 'daemon-settings boot interstitial' "$TMP/err" || fail 'daemon screen unnamed'
  tmux has-session -t "=$sess" || fail 'interstitial session not left up'
  [[ ! -e "$MARK" ]] || fail 'daemon interstitial received input'
  stop_session "$sess"
done
echo 'PASS: daemon interstitial titles'

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'Update available\n1. Update now\n2. Skip\n'
read -r _
touch "$MARK"
STUB
chmod +x "$TMP/bin/codex"
run_case codex dcs_update
assert_rc 4 "$rc" 'update screen'
grep -qi 'update boot interstitial' "$TMP/err" || fail 'update screen unnamed'
[[ ! -e "$MARK" ]] || fail 'update interstitial received input'
stop_session dcs_update
echo 'PASS: update interstitial'

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '> '
read -r l
printf 'CODEX-GOT: %s\n' "$l"
sleep 300
STUB
chmod +x "$TMP/bin/codex"
run_case codex dcs_codex_ok
assert_rc 0 "$rc" 'codex happy path'
grep -q 'CODEX-GOT: the prompt' "$TMP/out" || fail 'codex did not receive prompt'
stop_session dcs_codex_ok
echo 'PASS: codex happy path'

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '> '
read -r _
exit 7
STUB
chmod +x "$TMP/bin/claude"
run_case claude dcs_dead
assert_rc 5 "$rc" 'agent exit'
grep -q 'agent exited (status 7)' "$TMP/err" || fail 'missing dead-agent status'
stop_session dcs_dead
echo 'PASS: dead agent'

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '> '
read -r _
i=0
while :; do printf 'COUNTER %s\n' "$i"; i=$((i + 1)); sleep 1; done
STUB
chmod +x "$TMP/bin/claude"
DCS_SETTLE_MAX=4 run_case claude dcs_timeout
assert_rc 3 "$rc" 'settle timeout'
[[ -s "$TMP/out" ]] || fail 'timeout did not print partial transcript'
stop_session dcs_timeout
echo 'PASS: settle timeout'

write_alt 80
DCS_ROWS=30 run_case claude dcs_overflow
assert_rc 6 "$rc" 'overflow'
grep -q 'WARNING.*DCS_ROWS=30' "$TMP/err" || fail 'missing overflow warning'
stop_session dcs_overflow
echo 'PASS: possible overflow'

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
chmod +x "$TMP/bin/claude"
tmux new-session -d -s dcs_exact4 'sleep 300'
run_case claude dcs_exact
[[ "$rc" -ne 0 ]] || fail 'exact-target case falsely succeeded'
[[ -z "$(tmux capture-pane -p -t '=dcs_exact4:')" ]] || fail 'decoy pane received input'
stop_session dcs_exact
stop_session dcs_exact4
echo 'PASS: exact tmux targets'

for var in DCS_COLS DCS_ROWS; do
  env "$var=0" "$DRIVER" claude "$TMP" "$TMP/prompt" "dcs_invalid_$var" > "$TMP/out" 2> "$TMP/err"
  assert_rc 2 "$?" "invalid $var"
done
echo 'PASS: invalid pane dimensions'
