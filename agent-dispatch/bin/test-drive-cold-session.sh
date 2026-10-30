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

TMP="$(mktemp -d /tmp/dcs.XXXX)"
echo "tmux: $(tmux -V)"
TMUX_TMPDIR="$(mktemp -d /tmp/dcs.XXXX)"
export TMUX_TMPDIR HOME="$TMP" XDG_CONFIG_HOME="$TMP/config"
unset TMUX
trap 'tmux kill-server 2>/dev/null || true; rm -rf "$TMP" "$TMUX_TMPDIR"' EXIT
mkdir -p "$TMP/bin" "$XDG_CONFIG_HOME"
export PATH="$TMP/bin:$PATH"
printf 'the prompt\n' > "$TMP/prompt"
export MARK="$TMP/marker"
export DCS_INTERVAL=1 DCS_STABLE=2 DCS_BOOT_MAX=6 DCS_SETTLE_MAX=10

fail() {
  echo "FAIL: $*" >&2
  # Surface the driver's stderr so a CI-only failure is diagnosable from the log.
  if [[ -s "$TMP/err" ]]; then echo '--- driver stderr ---' >&2; cat "$TMP/err" >&2; fi
  exit 1
}
assert_rc() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" -eq "$expected" ]] || fail "$label: rc $actual, expected $expected; stderr: $(cat "$TMP/err")"
}
run_case() {
  local agent="$1" sess="$2"; shift 2
  # One marker file is shared by every case; clear it so a stub torn down by an
  # earlier case cannot leave a stale "received input" mark for this one.
  rm -f "$MARK"
  env -u TMUX TMUX_TMPDIR="$TMUX_TMPDIR" "$DRIVER" "$agent" "$TMP" "$TMP/prompt" "$sess" "$@" > "$TMP/out" 2> "$TMP/err"
  rc=$?
}
stop_session() { tmux kill-session -t "=$1" 2>/dev/null || true; }
write_inline() {
  local lines="$1"
  cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "${CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN:-}" != "1" ]]; then printf '\033[?1049h'; fi
printf '> '
read -r _
for i in $(seq -w 1 "$LINES_TO_PRINT"); do printf 'REPLY-%s\n' "$i"; done
printf 'END-OF-REPLY\n'
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
if read -r _; then touch "$MARK"; fi
STUB
  chmod +x "$TMP/bin/codex"
  export TITLE="$title"
}

write_inline 300
DCS_KILL=0 run_case claude dcs_inline300
assert_rc 0 "$rc" '300-line inline screen'
[[ "$(grep -c '^REPLY-' "$TMP/out")" -eq 300 ]] || fail '300-line reply was cut'
grep -q 'REPLY-001' "$TMP/out" || fail 'missing first reply row'
grep -q 'END-OF-REPLY' "$TMP/out" || fail 'missing reply end'
[[ "$(tmux display -p -t '=dcs_inline300:' '#{pane_width}x#{pane_height}')" == '200x200' ]] || fail 'default pane size'
agent_pane="$(tmux display -p -t '=dcs_inline300:' '#{pane_id}')"
[[ "$(tmux display -p -t "$agent_pane" '#{history_limit}')" == '50000' ]] || fail 'agent pane history limit'
stop_session dcs_inline300
echo 'PASS: 300-line inline transcript and default pane size'

write_inline 2500
tmux new-session -d -s dcs_hook_host cat
# Record the history limit when tmux creates the agent window, before a later
# set-option could mask the pane's original limit in show-option output.
tmux set-hook -g after-new-window 'if-shell -F "#{==:#{history_limit},50000}" "set-environment -g DCS_CREATED_LIMIT 50000" "set-environment -g DCS_CREATED_LIMIT other"'
DCS_KILL=1 run_case claude dcs_inline2500
assert_rc 0 "$rc" '2500-line inline screen'
[[ "$(tmux show-environment -g DCS_CREATED_LIMIT 2>/dev/null)" == 'DCS_CREATED_LIMIT=50000' ]] || fail 'agent pane was created before history-limit was raised'
[[ "$(grep -c '^REPLY-' "$TMP/out")" -eq 2500 ]] || fail '2500-line reply was cut'
grep -q '^REPLY-0001$' "$TMP/out" || fail 'missing first long-reply row'
grep -q '^REPLY-2500$' "$TMP/out" || fail 'missing last long-reply row'
grep -q '^END-OF-REPLY$' "$TMP/out" || fail 'missing long-reply end'
! tmux has-session -t '=dcs_inline2500' 2>/dev/null || fail 'long-reply session leaked'
tmux set-hook -gu after-new-window
stop_session dcs_hook_host
echo 'PASS: 2500-line inline transcript'

write_inline 10
DCS_KILL=0 DCS_COLS=120 DCS_ROWS=50 run_case claude dcs_size
assert_rc 0 "$rc" 'custom pane size'
[[ "$(tmux display -p -t '=dcs_size:' '#{pane_width}x#{pane_height}')" == '120x50' ]] || fail 'custom pane size'
stop_session dcs_size
echo 'PASS: custom pane size'

# Give the new session a larger inherited value before the driver reads it.
tmux new-session -d -s dcs_high_limit_host cat || fail 'history-limit host session'
tmux set-option -g history-limit 60000 || fail 'set global history limit'
write_inline 10
run_case claude dcs_high_limit
assert_rc 0 "$rc" 'larger session history limit'
agent_pane="$(tmux display -p -t '=dcs_high_limit:' '#{pane_id}')"
[[ "$(tmux display -p -t "$agent_pane" '#{history_limit}')" == '60000' ]] || fail 'larger agent pane history limit was lowered'
stop_session dcs_high_limit
tmux set-option -gu history-limit || fail 'restore global history limit'
stop_session dcs_high_limit_host
echo 'PASS: larger session history limit preserved'

for title in 'Is this a project you created or one you trust?' 'Do you trust the files in this folder?'; do
  cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$TITLE"
if read -r _; then touch "$MARK"; fi
exit 1
STUB
  chmod +x "$TMP/bin/claude"
  export TITLE="$title"
  sess="dcs_claude_trust_${title%% *}"
  DCS_KILL=1 run_case claude "$sess"
  assert_rc 4 "$rc" "$title"
  grep -qi 'trust the folder or run Claude once interactively' "$TMP/err" || fail 'missing Claude trust guidance'
  [[ ! -e "$MARK" ]] || fail 'Claude trust interstitial received input'
  ! tmux has-session -t "=$sess" 2>/dev/null || fail 'Claude trust session leaked'
done
echo 'PASS: Claude folder-trust interstitials'

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'WARNING: Claude Code running in Bypass Permissions mode\n1. Exit\n2. Continue\n'
if read -r _; then touch "$MARK"; fi
STUB
chmod +x "$TMP/bin/claude"
DCS_KILL=1 run_case claude dcs_claude_bypass
assert_rc 4 "$rc" 'Claude bypass-permissions warning'
grep -q 'accept it once interactively' "$TMP/err" || fail 'missing bypass-permissions guidance'
[[ ! -e "$MARK" ]] || fail 'Claude bypass-permissions warning received input'
! tmux has-session -t '=dcs_claude_bypass' 2>/dev/null || fail 'Claude bypass-permissions session leaked'
echo 'PASS: Claude bypass-permissions warning'

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '\033[?1049h\033[H\033[2JHEADER\033[50;1HFOOTER\033[25;1H> '
read -r _
printf '\033[25;1HONE-LINE-REPLY'
sleep 300
STUB
chmod +x "$TMP/bin/claude"
DCS_ROWS=50 run_case claude dcs_alternate
assert_rc 6 "$rc" 'alternate screen'
grep -q 'transcript completeness cannot be verified: agent is in alternate-screen mode' "$TMP/err" || fail 'missing alternate-screen warning'
stop_session dcs_alternate
echo 'PASS: alternate-screen transcript unverified'

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'HEADER\n> '
read -r _
printf 'SHORT-REPLY\n'
printf '\033[50;1HFOOTER'
sleep 300
STUB
chmod +x "$TMP/bin/claude"
DCS_ROWS=50 run_case claude dcs_header_footer
assert_rc 0 "$rc" 'inline header and footer'
grep -q 'SHORT-REPLY' "$TMP/out" || fail 'inline short reply absent'
stop_session dcs_header_footer
echo 'PASS: inline header and footer'

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
if read -r _; then touch "$MARK"; fi
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
printf 'Update available! See https://example.invalid/install for installation options.\n> '
read -r l
printf 'BANNER-GOT: %s\n' "$l"
sleep 300
STUB
chmod +x "$TMP/bin/codex"
run_case codex dcs_banner
assert_rc 0 "$rc" 'banner-only update notice'
grep -q 'BANNER-GOT: the prompt' "$TMP/out" || fail 'banner-only agent did not receive prompt'
stop_session dcs_banner
echo 'PASS: update banner ignored'

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'Choose a model\n1. Use existing model\n2. Try new model\n'
if read -r _; then touch "$MARK"; fi
STUB
chmod +x "$TMP/bin/codex"
run_case codex dcs_model_offer
assert_rc 4 "$rc" 'model offer'
grep -q 'model-offer boot interstitial' "$TMP/err" || fail 'model offer unnamed'
[[ ! -e "$MARK" ]] || fail 'model offer received input'
stop_session dcs_model_offer
echo 'PASS: model-offer interstitial'

for title in 'Trust this folder?' 'Trust and continue' 'Do you trust the contents of this directory'; do
  cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$TITLE"
if read -r _; then touch "$MARK"; fi
STUB
  chmod +x "$TMP/bin/codex"
  export TITLE="$title"
  sess="dcs_codex_trust_${title%% *}"
  DCS_KILL=1 run_case codex "$sess"
  assert_rc 4 "$rc" "$title"
  grep -q 'folder-trust boot interstitial' "$TMP/err" || fail 'codex folder-trust screen unnamed'
  [[ ! -e "$MARK" ]] || fail 'codex folder-trust interstitial received input'
  ! tmux has-session -t "=$sess" 2>/dev/null || fail 'codex folder-trust session leaked'
done
echo 'PASS: codex folder-trust interstitials'

cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
[[ " $* " == *' --no-alt-screen '* ]] || exit 8
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
exit 7
STUB
chmod +x "$TMP/bin/claude"
for _ in 1 2 3; do
  DCS_KILL=1 run_case claude dcs_dead
  assert_rc 5 "$rc" 'agent exit'
  grep -q 'agent exited (status 7) before replying' "$TMP/err" || fail 'missing dead-agent status'
  ! tmux has-session -t '=dcs_dead' 2>/dev/null || fail 'dead session leaked'
  ! grep -qi 'duplicate session' "$TMP/err" || fail 'duplicate session error'
done
echo 'PASS: dead agent cleanup across repeated names'

tmux new-session -d -s dcs_foreign 'sleep 300'
DCS_KILL=1 run_case claude dcs_foreign
[[ "$rc" -ne 0 ]] || fail 'duplicate session unexpectedly launched'
tmux has-session -t '=dcs_foreign' || fail 'cleanup killed a session it did not create'
stop_session dcs_foreign
echo 'PASS: duplicate name preserves foreign session'

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '> '
read -r _
printf 'FINAL-REPLY\n'
exit 7
STUB
chmod +x "$TMP/bin/claude"
run_case claude dcs_exit_after_reply
assert_rc 5 "$rc" 'exit after reply'
grep -q 'FINAL-REPLY' "$TMP/out" || fail 'post-reply exit lost transcript'
grep -q 'agent exited after the prompt was submitted (status 7)' "$TMP/err" || fail 'post-submit exit status missing'
! tmux has-session -t '=dcs_exit_after_reply' 2>/dev/null || fail 'post-reply dead session leaked'
echo 'PASS: post-reply exit transcript and cleanup'

write_inline 10
DCS_KILL=0 DCS_TEST_FAIL_LAUNCH=1 run_case claude dcs_launch_failure
assert_rc 1 "$rc" 'mid-launch failure'
! tmux ls -F '#S' 2>/dev/null | grep -qx 'dcs_launch_failure' || fail 'mid-launch failure leaked session'
echo 'PASS: mid-launch failure cleanup'

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

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
i=0
while :; do printf 'BOOT-COUNTER %s\n' "$i"; i=$((i + 1)); sleep 1; done
STUB
chmod +x "$TMP/bin/claude"
DCS_BOOT_MAX=4 DCS_KILL=1 run_case claude dcs_boot_timeout
assert_rc 3 "$rc" 'boot-settle timeout'
grep -q 'BOOT-COUNTER' "$TMP/out" || fail 'boot timeout did not print screen'
echo 'PASS: boot timeout prints screen'

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '> '
tmux kill-session -t "=$(tmux display-message -p -t "$TMUX_PANE" '#S')"
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
