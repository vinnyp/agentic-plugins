#!/usr/bin/env bash
set -uo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
TMP=$(set -eu; scratch=$(mktemp -d "${TMPDIR:-/tmp}/repo-state-cli-test.XXXXXX"); [ -n "$scratch" ]; printf '%s\n' "$scratch")
[ -n "$TMP" ] || exit 1
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL="$TMP/global" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n name = Fixture\n email = fixture@example.invalid\n' > "$GIT_CONFIG_GLOBAL"
# shellcheck source=agent-dispatch/bin/lib/repo-state.sh
. "$BIN/lib/repo-state.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
rc_is() {
  local want=$1 rc=0
  shift
  "$@" || rc=$?
  [ "$rc" = "$want" ] || { echo "expected $want, got $rc: $*" >&2; exit 1; }
}
fixture() {
  R=$(mktemp -d "$TMP/${1:-repo}.XXXXXX")
  [ -n "$R" ] || exit 1
  git -C "$R" init -q -b main
  git -C "$R" init -q --bare "$R.git"
  git -C "$R" remote add origin "$R.git"
  git -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial --allow-empty
  git -C "$R" push -q origin main
}
# Standalone CLI bound, fail-closed verdicts and atomic output publication.
# Existing cases above stay intact. Every case runs under its own outer bound,
# in both timer modes (coreutils timeout, and the process-group watchdog).
# ---------------------------------------------------------------------------
BCASE_TIMER=$(command -v timeout || command -v gtimeout || true)
if [ -z "$BCASE_TIMER" ]; then
  echo 'SKIP standalone bound cases: no timeout/gtimeout for the outer bound'
else
RUN_ID="rsb$$x$RANDOM"
RUN_PID_FILE="$TMP/run-pids"
REAL_GIT=$(command -v git)
: > "$RUN_PID_FILE"
SHIMS="$TMP/shims"
SLOW="$TMP/slow-shims"
NOTIMER="$TMP/no-timer-shim"
mkdir "$SHIMS" "$SLOW" "$NOTIMER"
# Tagged git: argv[0] is "tagged-<id>" so a survivor is found by tag, never by name.
cat > "$SHIMS/git" <<'SHIM'
#!/usr/bin/env bash
echo $$ >> "$RUN_PID_FILE"
exec -a "tagged-$RUN_ID" "$REAL_GIT" "$@"
SHIM
cat > "$SHIMS/sleep" <<'SHIM'
#!/usr/bin/env bash
echo "$$ tagged-sleep-$RUN_ID" >> "$RUN_PID_FILE"
exec -a "tagged-sleep-$RUN_ID" /bin/sleep "$@"
SHIM
# Slow git: the matched subcommands sleep, under the tag, whatever git does with a FIFO.
cat > "$SLOW/git" <<'SHIM'
#!/usr/bin/env bash
echo $$ >> "$RUN_PID_FILE"
sub='' flag=''
for arg in "$@"; do
  case "$arg" in
    rev-parse|cat-file|rev-list) sub=$arg ;;
    --git-common-dir|--absolute-git-dir|--show-toplevel) flag=$arg ;;
  esac
done
case "$sub" in
  cat-file|rev-list) exec -a "tagged-$RUN_ID" /bin/sleep 30 ;;
  rev-parse) [ -z "$flag" ] || exec -a "tagged-$RUN_ID" /bin/sleep 30 ;;
esac
exec -a "tagged-$RUN_ID" "$REAL_GIT" "$@"
SHIM
# A timer that claims success without running anything.
printf '#!/bin/sh\nexit 0\n' > "$NOTIMER/timeout"
chmod +x "$SHIMS/git" "$SHIMS/sleep" "$SLOW/git" "$NOTIMER/timeout"
export RUN_ID RUN_PID_FILE REAL_GIT SHIMS SLOW NOTIMER BIN TMP BCASE_TIMER

setup_mode() {
  # Hide only timeout discovery; the CLI under test is not modified.
  if [ "${CASE_MODE:-}" = watchdog ]; then
    command() {
      case "$*" in '-v timeout'|'-v gtimeout') return 1 ;; esac
      builtin command "$@"
    }
    export -f command
  fi
  : > "$RUN_PID_FILE"
  TMPDIR=$(mktemp -d "$TMP/timers.XXXXXX")
  export TMPDIR
}
cli() { PATH="$SHIMS:$PATH" "$BIN/repo-state-check" "$@"; }
slow_cli() { PATH="$SLOW:$SHIMS:$PATH" "$BIN/repo-state-check" "$@"; }
outdir() { mktemp -d "$TMP/out-$RUN_ID.XXXXXX"; }
# Poll for tagged processes that are still alive (zombies do not count).
survivors() {
  local deadline=$((SECONDS + ${1:-2})) pid alive state
  while :; do
    alive=''
    while read -r pid _tag; do
      [ -n "$pid" ] || continue
      state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
      case "$state" in ''|Z*) continue ;; esac
      if ps -p "$pid" -o command= 2>/dev/null | grep -qF "$RUN_ID"; then alive="$alive $pid"; fi
    done < "$RUN_PID_FILE"
    [ -z "$alive" ] && return 0
    if [ "$SECONDS" -ge "$deadline" ]; then
      for pid in $alive; do ps -p "$pid" -o pid=,ppid=,pgid=,stat=,command= >&2; done
      fail "tagged processes survived:$alive"
    fi
    /bin/sleep 0.2
  done
}
no_state_dir() {
  ! compgen -G "$1/.repo-state.*" >/dev/null || fail "stray .repo-state.* beside $1"
  ! compgen -G "$1/.repo-state-out.*" >/dev/null || fail 'stray output temporary file'
}
no_bound_dir() {
  ! compgen -G "$TMPDIR/repo-state-bound.*" >/dev/null || fail 'stray bound directory'
  ! compgen -G "$TMPDIR/repo-state-cli.*" >/dev/null || fail 'stray CLI directory'
  ! compgen -G "$TMPDIR/.repo-state-compare.*" >/dev/null || fail 'stray compare directory'
  ! compgen -G "$TMPDIR/repo-state-changes.*" >/dev/null || fail 'stray changes file' 
}
first_line() { local l=''; IFS= read -r l < "$1" || true; printf '%s' "${l%%$'\t'*}"; }
moved_ref_fixture() {
  local tree commit
  tree=$("$REAL_GIT" -C "$R" rev-parse 'HEAD^{tree}')
  commit=$("$REAL_GIT" -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree -p HEAD -m moved "$tree")
  "$REAL_GIT" -C "$R" update-ref refs/heads/moved "$commit"
  MOVED=$commit
}


# Probe real Git in a separate scratch fixture before claiming a blocking control.
# Exits 0 when git blocks, 1 when it does not, 2 for a fixture or setup error.
real_git_blocks() (
  set -eEu
  trap 'echo "real-git probe for $1: setup error" >&2; exit 2' ERR
  local case_name=$1 kind=$2 rc=0 obj target
  fixture probe
  target=$R
  case "$kind" in
    loose-object)
      moved_ref_fixture
      obj="$R/.git/objects/${MOVED:0:2}/${MOVED:2}"
      [ -f "$obj" ]
      rm "$obj"; mkfifo "$obj"
      "$BCASE_TIMER" -k 1 3 "$REAL_GIT" -C "$R" rev-list "$MOVED" >/dev/null 2>&1 || rc=$?
      ;;
    *)
      if [ "$kind" = linked-alternates ]; then
        target="$R-linked"
        "$REAL_GIT" -C "$R" worktree add -q -b linked "$target"
      fi
      mkfifo "$R/.git/objects/info/alternates"
      "$BCASE_TIMER" -k 1 3 "$REAL_GIT" -C "$target" rev-parse --absolute-git-dir >/dev/null 2>&1 || rc=$?
      ;;
  esac
  if [ "$rc" != 124 ] && [ "$rc" != 137 ]; then
    printf 'SKIP %s: this git does not block on %s (probe rc %s)\n' "$case_name" "$kind FIFO" "$rc"
    exit 1
  fi
  printf 'REAL GIT %s: blocks on %s\n' "$case_name" "$kind FIFO"
)
# Run the probe; a git that does not block skips the calling case (status 77),
# and a probe that itself failed is a test failure, never a skip.
need_real_git_block() {
  local rc
  # Not an `||` list: bash would switch errexit off inside the probe and hide its setup errors.
  set +e
  real_git_blocks "$1" "$2"
  rc=$?
  set -e
  case "$rc" in
    0) return 0 ;;
    1) exit 77 ;;
    *) fail "real-git probe for $1 failed (status $rc)" ;;
  esac
}

case_1_snapshot_alternates_fifo() (
  set -eu; setup_mode
  [ "${SKIP_PROBE:-}" = 1 ] || need_real_git_block case_1_snapshot_alternates_fifo alternates
  local d rc=0
  fixture; d=$(outdir)
  mkfifo "$R/.git/objects/info/alternates"
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail "expected 3, got $rc"
  [ "$(first_line "$d/file")" = unreadable ] || fail 'stale or partial snapshot left readable'
  grep -q $'^unsafe\t.*objects/info/alternates' "$d/file" || fail 'unsafe line missing'
  grep -q 'repo-state-check: snapshot timed out; special files found in git metadata:.*objects/info/alternates' "$d/err" || fail 'message (a) missing'
  survivors; no_state_dir "$d"; no_bound_dir
  if [ "$CASE_MODE" = watchdog ]; then
    grep -q tagged-sleep- "$RUN_PID_FILE" || fail 'watchdog never started'
  fi
)
case_2_snapshot_slow_git() (
  set -eu; setup_mode
  local d rc=0
  fixture; d=$(outdir)
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail "expected 3, got $rc"
  [ "$(first_line "$d/file")" = unreadable ] || fail 'file not unreadable'
  ! grep -q '^unsafe' "$d/file" || fail 'unexpected unsafe line'
  grep -Fq "repo-state-check: snapshot timed out; no special file found in $R/.git; cause unknown (if the repo is large, raise DISPATCH_SNAPSHOT_TIMEOUT_SECS and the Bash tool timeout)" "$d/err" || fail 'message (b) missing'
  survivors; no_state_dir "$d"; no_bound_dir
)
compare_pair() {
  local d=$1
  cli snapshot "$R" "$d/before"
  moved_ref_fixture
  cli snapshot "$R" "$d/after"
}
case_3_compare_loose_object_fifo() (
  set -eu; setup_mode
  need_real_git_block case_3_compare_loose_object_fifo loose-object
  local d rc=0 obj
  fixture; d=$(outdir)
  compare_pair "$d"
  obj="$R/.git/objects/${MOVED:0:2}/${MOVED:2}"
  [ -f "$obj" ] || fail 'fixture commit is not a loose object'
  rm -f "$obj"; mkfifo "$obj"
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 cli compare "$d/before" "$d/after" > "$d/out" 2> "$d/err" || rc=$?
  [ "$rc" = 2 ] || fail "expected 2, got $rc"
  [ "$(cat "$d/out")" = 'state: compare timed out' ] || fail 'compare output is not exactly the timeout line'
  ! grep -q nonregular "$d/out" || fail 'unexpected nonregular line'
  survivors; no_state_dir "$d"; no_bound_dir
)
case_4_compare_slow_git() (
  set -eu; setup_mode
  local d rc=0
  fixture; d=$(outdir)
  compare_pair "$d"
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli compare "$d/before" "$d/after" > "$d/out" 2> "$d/err" || rc=$?
  [ "$rc" = 2 ] || fail "expected 2, got $rc"
  [ "$(cat "$d/out")" = 'state: compare timed out' ] || fail 'compare output is not exactly the timeout line'
  survivors; no_state_dir "$d"; no_bound_dir
)
case_5_clean_repo() (
  set -eu; setup_mode
  local d started
  fixture; d=$(outdir)
  started=$SECONDS
  cli snapshot "$R" "$d/cli"
  [ $((SECONDS - started)) -lt 10 ] || fail 'clean snapshot too slow'
  repo_state_snapshot "$R" "$d/direct"
  [ "$(cut -f1 "$d/cli" | tr '\n' ' ')" = "$(cut -f1 "$d/direct" | tr '\n' ' ')" ] || fail 'line kinds or order differ from the library snapshot'
  "$REAL_GIT" -C "$R" config 'url.https://u:p@example.invalid/.insteadOf' x
  "$REAL_GIT" -C "$R" config remote.origin.pushurl 'https://user:secret@example.invalid/repo'
  cli snapshot "$R" "$d/one"
  cli snapshot "$R" "$d/two"
  rc_is 0 cli compare "$d/one" "$d/two"
  survivors; no_state_dir "$d"; no_bound_dir
)
case_6_limit_helper() (
  set -eu
  local value caller default actual
  for value in 0 00 abc '' 86401 999999 18446744073709551676; do
    for default in 60 120; do
      caller='repo-state-check'; [ "$default" = 60 ] || caller=dispatch-worker
      actual=$(DISPATCH_SNAPSHOT_TIMEOUT_SECS="$value" repo_state_snapshot_limit "$caller" "$default" 2> "$TMP/limit.err")
      [ "$actual" = "$default" ] || fail "limit '$value' gave '$actual', wanted $default"
      [ "$(cat "$TMP/limit.err")" = "$caller: invalid DISPATCH_SNAPSHOT_TIMEOUT_SECS; using $default" ] || fail "warning for '$value'"
    done
  done
  [ "$(DISPATCH_SNAPSHOT_TIMEOUT_SECS=08 repo_state_snapshot_limit repo-state-check 60)" = 8 ] || fail '08'
  [ "$(DISPATCH_SNAPSHOT_TIMEOUT_SECS=010 repo_state_snapshot_limit repo-state-check 60)" = 10 ] || fail '010'
  [ "$(DISPATCH_SNAPSHOT_TIMEOUT_SECS=86400 repo_state_snapshot_limit repo-state-check 60 2>&1)" = 86400 ] || fail '86400'
  [ "$(unset DISPATCH_SNAPSHOT_TIMEOUT_SECS; repo_state_snapshot_limit dispatch-worker 120 2>&1)" = 120 ] || fail 'unset'
)
case_7_linked_worktree() (
  set -eu; setup_mode
  need_real_git_block case_7_linked_worktree linked-alternates
  local d rc=0 wt
  fixture; d=$(outdir)
  wt="$R-linked"
  "$REAL_GIT" -C "$R" worktree add -q -b linked "$wt"
  mkfifo "$R/.git/objects/info/alternates"
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 cli snapshot "$wt" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail "expected 3, got $rc"
  [ "$(first_line "$d/file")" = unreadable ] || fail 'file not unreadable'
  ! grep -q '^unsafe' "$d/file" || fail 'unexpected unsafe line'
  grep -Fq 'repo-state-check: snapshot timed out; pre-sweep skipped (.git is not a directory); cause unknown' "$d/err" || fail 'message (c) missing'
  survivors; no_state_dir "$d"; no_bound_dir
)
case_8_external_kill() (
  set -eu; setup_mode
  local d pid rc=0
  fixture; d=$(outdir)
  cli snapshot "$R" "$d/file"
  [ "$(first_line "$d/file")" = repo ] || fail 'valid file missing'
  env PATH="$SLOW:$SHIMS:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=3 "$BIN/repo-state-check" snapshot "$R" "$d/file" 2> /dev/null &
  pid=$!
  /bin/sleep 1
  ps -p "$pid" -o command= | grep -qF "$RUN_ID" || fail 'untagged CLI'
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(first_line "$d/file")" = unreadable ] || fail 'killed CLI left a stale snapshot readable'
  survivors 9   # limit 3 + 5 kill grace + 1
  # SIGKILL cannot run cleanup; these temporary paths belong only to this case.
  local orphan
  for orphan in "$TMPDIR"/repo-state-bound.* "$TMPDIR"/repo-state-cli.* "$d"/.repo-state-out.*; do
    [ ! -e "$orphan" ] || rm -rf "$orphan"
  done
  no_bound_dir
  no_state_dir "$d"
  cli snapshot "$R" "$d/file"
  [ "$(first_line "$d/file")" = repo ] || fail 'valid file missing (second)'
  cli snapshot relative "$d/file" 2> /dev/null || rc=$?
  [ "$rc" = 3 ] || fail "relative repo expected 3, got $rc"
  [ "$(first_line "$d/file")" = unreadable ] || fail 'relative repo left a stale snapshot'
  no_state_dir "$d"; no_bound_dir
)
case_9_healthy_special_file() (
  set -eu; setup_mode
  local d rc=0
  fixture; d=$(outdir)
  mkfifo "$R/.git/FETCH_HEAD" "$R/.git/escape"$'\033'
  cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 0 ] || fail "expected 0, got $rc"
  grep -q 'repo-state-check: baseline contains special files:.*FETCH_HEAD' "$d/err" || fail 'baseline warning missing'
  [ "$(first_line "$d/file")" = repo ] || fail 'not a snapshot'
  ! LC_ALL=C grep -q $'\033' "$d/err" || fail 'raw escape in stderr'
  grep -Fq '\x1b' "$d/err" || fail 'escaped filename missing' 
  survivors; no_state_dir "$d"; no_bound_dir
)
case_10_worker_bound() (
  set -eu; setup_mode
  local d script sentinel=sentinel-$RUN_ID mode
  fixture; d=$(outdir)
  mkfifo "$R/.git/objects/info/alternates"
  sed -n '/^review_state_snapshot_bounded() {$/,/^}$/p; /^review_state_compare_bounded() {$/,/^}$/p; /^review_launch_failure() {$/,/^}$/p' "$BIN/dispatch-worker" > "$d/worker.sh"
  # A hostile worker compare: a git read that never returns.
  cat >> "$d/worker.sh" <<'WORKER'
review_state_compare_memory() { git -C "$REVIEW_GIT_DIR" cat-file -p HEAD; }
WORKER
  script="$d/run.sh"
  cat > "$script" <<'RUN'
set -u
. "$BIN/lib/repo-state.sh"
. "$2"
REVIEW_GIT_DIR="$3/.git" REVIEW_GIT_COMMON_DIR="$3/.git"
REVIEW_RUNTIME_LAUNCHED=1 REVIEW_BEFORE=x REVIEW_CURRENT=x
REPO_STATE_SALT=test
[ -p "$4/snap" ] || mkfifo "$4/snap"
[ -p "$4/changes" ] || mkfifo "$4/changes"
export DISPATCH_SNAPSHOT_TIMEOUT_SECS=1
case "$1" in
  snapshot) rc=0; review_state_snapshot_bounded "$3" "$4/snap" || rc=$?
            [ "${REPO_STATE_BOUND_OUT%%$'\n'*}" = unreadable ] && [ -p "$4/snap" ] ;;
  compare) rc=0; review_state_compare_bounded || rc=$?
           [ "$rc" = 2 ] && [[ "$REPO_STATE_BOUND_OUT" = *'drift check could not complete'* ]] && [ -p "$4/changes" ] ;;
  flags-off) set +m; before=$-; DISPATCH_SNAPSHOT_TIMEOUT_SECS=5 review_state_snapshot_bounded "$3" "$4/ok"; [ "$-" = "$before" ] ;;
  flags-on) set -m; before=$-; DISPATCH_SNAPSHOT_TIMEOUT_SECS=5 review_state_snapshot_bounded "$3" "$4/ok"; [ "$-" = "$before" ] ;;
esac
RUN
  export BIN
  export REPO_STATE_TMP="$d/nonexistent/redirect"
  # Hostile snapshot and compare, under the slow git.
  for mode in snapshot compare; do
    PATH="$SLOW:$SHIMS:$PATH" bash "$script" "$mode" "$d/worker.sh" "$R" "$d" || fail "worker $mode did not fail closed"
    survivors
  done
  # The caller's shell flags survive the bounded call, monitor mode off and on.
  rm "$R/.git/objects/info/alternates"
  for mode in flags-off flags-on; do
    PATH="$SHIMS:$PATH" bash "$script" "$mode" "$d/worker.sh" "$R" "$d" || fail "shell flags changed ($mode)"
  done
  # Private state never reaches argv.
  cat > "$d/argv.sh" <<'RUN'
set -u
. "$BIN/lib/repo-state.sh"
. "$1"
REVIEW_GIT_DIR="$2/.git" REVIEW_GIT_COMMON_DIR="$2/.git"
REVIEW_RUNTIME_LAUNCHED=1
REPO_STATE_SALT=$SENTINEL
DISPATCH_SNAPSHOT_TIMEOUT_SECS=3
review_state_snapshot_bounded "$2" "$3/argv-snap" || true
RUN
  SENTINEL=$sentinel PATH="$SLOW:$SHIMS:$PATH" bash "$d/argv.sh" "$d/worker.sh" "$R" "$d" &
  local bg=$!
  /bin/sleep 1
  ! ps -ww -axo command= | grep -F -- "$sentinel" | grep -vqF 'grep' || fail 'private state visible in process argv'
  wait "$bg" 2>/dev/null || true
  survivors 9; no_bound_dir
)
case_11_cli_invalid_limit() (
  set -eu; setup_mode
  local d started rc=0 value
  fixture; d=$(outdir)
  started=$SECONDS
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=abc cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 0 ] || fail "expected 0, got $rc"
  [ "$(cat "$d/err")" = 'repo-state-check: invalid DISPATCH_SNAPSHOT_TIMEOUT_SECS; using 60' ] || fail 'warning text'
  [ $((SECONDS - started)) -lt 10 ] || fail 'too slow'
  started=$SECONDS
  cp "$d/file" "$d/copy"
  for value in abc 0; do
    rc=0
    env DISPATCH_SNAPSHOT_TIMEOUT_SECS="$value" PATH="$SHIMS:$PATH" "$BIN/repo-state-check" compare "$d/file" "$d/copy" > "$d/out" 2> "$d/err" || rc=$?
    [ "$rc" = 0 ] || fail "compare limit $value gave $rc"
    [ ! -s "$d/out" ] || fail 'clean compare produced output'
    grep -Fxq 'repo-state-check: invalid DISPATCH_SNAPSHOT_TIMEOUT_SECS; using 60' "$d/err" || fail 'compare warning text'
  done
  [ $((SECONDS - started)) -lt 10 ] || fail 'compare too slow'
  survivors; no_state_dir "$d"; no_bound_dir
)
case_12_unevaluated_child() (
  set -eu; setup_mode
  local d ro rc=0 fwd_value
  early_exit() { exit 0; }
  rc_is 125 repo_state_run_bounded 5 early_exit
  returns_seven() { return 7; }
  rc_is 7 repo_state_run_bounded 5 returns_seven
  # A read-only TMPDIR parent makes mktemp -d fail: setup failure, never "warn".
  ro=$(mktemp -d "$TMP/ro.XXXXXX"); chmod 555 "$ro"
  if [ ! -w "$ro" ]; then
    TMPDIR=$ro rc_is 125 repo_state_run_bounded 5 returns_seven
  else
    echo 'SKIP read-only TMPDIR: directory remains writable'
  fi
  chmod 755 "$ro"
  # REPO_STATE_TMP reaches the bounded child. It is not exported, so only the
  # lib's own forwarding can deliver it.
  forward_tmp() { printf '%s\n' "$REPO_STATE_TMP" > "$1"; }
  d=$(outdir)
  unset REPO_STATE_TMP
  REPO_STATE_TMP="$d/forwarded-value"
  repo_state_run_bounded 5 forward_tmp "$d/seen"
  fwd_value=$(cat "$d/seen")
  [ "$fwd_value" = "$d/forwarded-value" ] || fail "temporary directory not forwarded ('$fwd_value')"
  unset REPO_STATE_TMP
  survivors; no_state_dir "$d"; no_bound_dir
)
case_12b_timer_claims_success() (
  set -eu; setup_mode
  local d rc=0
  [ "${CASE_MODE:-}" = timeout ] || exit 0
  fixture; d=$(outdir)
  cli snapshot "$R" "$d/before"
  moved_ref_fixture
  cli snapshot "$R" "$d/after"
  cli snapshot "$R" "$d/file"
  PATH="$NOTIMER:$PATH" "$BIN/repo-state-check" snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail "snapshot expected 3, got $rc"
  [ "$(first_line "$d/file")" = unreadable ] || fail 'unevaluated snapshot left readable'
  rc=0
  PATH="$NOTIMER:$PATH" "$BIN/repo-state-check" compare "$d/before" "$d/after" > "$d/out" 2> "$d/err" || rc=$?
  [ "$rc" = 2 ] || fail "compare expected 2, got $rc"
  [ "$(wc -l < "$d/out" | tr -d ' ')" = 1 ] || fail 'compare output is not one line'
  [ "$(grep -Ec '^state: compare could not complete \(.+\)$' "$d/out")" = 1 ] || fail 'compare output text'
  no_bound_dir
)
case_13_hostile_output_path() (
  set -eu; setup_mode
  local d rc=0
  fixture; d=$(outdir)
  mkfifo "$d/fifo"
  cli snapshot "$R" "$d/fifo"
  [ -f "$d/fifo" ] && [ ! -L "$d/fifo" ] || fail 'FIFO output not replaced'
  [ "$(first_line "$d/fifo")" = repo ] || fail 'FIFO output is not a snapshot'
  mkfifo "$d/fifo2"
  cli snapshot relative "$d/fifo2" 2> /dev/null || rc=$?
  [ "$rc" = 3 ] || fail "relative repo expected 3, got $rc"
  [ -f "$d/fifo2" ] && [ ! -L "$d/fifo2" ] || fail 'rejected FIFO output not replaced'
  [ "$(cat "$d/fifo2")" = unreadable ] || fail 'pre-mark missing'
  mkdir "$d/dir"
  rc=0; cli snapshot "$R" "$d/dir" 2> /dev/null || rc=$?
  [ "$rc" = 3 ] || fail "directory output expected 3, got $rc"
  [ -z "$(ls -A "$d/dir")" ] || fail 'a file was written into the output directory'
  printf sentinel > "$d/sentinel"
  ln -s "$d/sentinel" "$d/link"
  cli snapshot "$R" "$d/link"
  [ "$(cat "$d/sentinel")" = sentinel ] || fail 'symlink target modified'
  [ -f "$d/link" ] && [ ! -L "$d/link" ] || fail 'symlink output not replaced'
  survivors; no_state_dir "$d"; no_bound_dir
)

case_completion_integrity() (
  set -eu; setup_mode
  local d
  d=$(outdir)
  forge_completion() {
    local private
    for private in "$TMPDIR"/repo-state-bound.*; do break; done
    printf 'done 0\n' > "$private/done"
    ps -p "$$" -o command= | grep -qF "$RUN_ID" || return 8
    kill -TERM "$$"
  }
  rc_is 125 repo_state_run_bounded 5 forge_completion "$RUN_ID"
  mismatched_completion() {
    local private
    for private in "$TMPDIR"/repo-state-bound.*; do
      printf 'done 0\n' > "$private/done"
    done
    exit 7
  }
  rc_is 125 repo_state_run_bounded 5 mismatched_completion
  no_script() {
    local private
    for private in "$TMPDIR"/repo-state-bound.*; do
      [ ! -e "$private/run" ] || return 9
    done
  }
  rc_is 0 repo_state_run_bounded 5 no_script
  signal_exit() { exit 137; }
  if [ "$CASE_MODE" = watchdog ]; then
    rc_is 125 repo_state_run_bounded 5 signal_exit
  fi
  symlink_token() {
    local private
    for private in "$TMPDIR"/repo-state-bound.*; do
      printf 'done 0\n' > "$1"
      ln -s "$1" "$private/done"
    done
  }
  rc_is 0 repo_state_run_bounded 5 symlink_token "$d/token"
  no_bound_dir
)
case_cli_signals() (
  set -eu; setup_mode
  local d sig pid rc started
  fixture; d=$(outdir)
  for sig in TERM INT; do
    rc=0
    PATH="$SLOW:$SHIMS:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=20 \
      perl -e '$SIG{INT}=$SIG{TERM}=$SIG{HUP}="DEFAULT"; exec @ARGV' \
      "$BIN/repo-state-check" snapshot "$R" "$d/file" 2> "$d/err" &
    pid=$!
    /bin/sleep 1
    started=$SECONDS
    ps -p "$pid" -o command= | grep -qF "$RUN_ID" || fail 'untagged CLI'
    kill -"$sig" "$pid"
    wait "$pid" || rc=$?
    case "$sig:$rc" in TERM:143|INT:130) ;; *) fail "signal $sig returned $rc" ;; esac
    [ $((SECONDS - started)) -le 2 ] || fail 'signal handling deferred'
    [ "$(first_line "$d/file")" = unreadable ] || fail 'signal left readable output'
    survivors
    no_state_dir "$d"; no_bound_dir
  done
)
case_symlink_path() (
  set -eu; setup_mode
  local d
  fixture; d=$(outdir)
  mkfifo "$R/.git/FETCH_HEAD"
  ln -s "$R" "$d/repo"
  cli snapshot "$d/repo" "$d/file" 2> "$d/err"
  [ "$(grep -c '^unsafe' "$d/file")" = 1 ] || fail 'duplicate unsafe path'
  no_bound_dir
)
case_failed_sweep() (
  set -eu; setup_mode
  local d rc=0
  fixture; d=$(outdir)
  mkdir "$R/.git/inaccessible"; chmod 000 "$R/.git/inaccessible"
  # A failing find shim also makes this deterministic under privileged accounts.
  mkdir "$d/bin"
  command -v find > "$d/real-find"
  cat > "$d/bin/find" <<'FIND'
#!/usr/bin/env bash
"$REAL_FIND" "$@"
exit 1
FIND
  chmod +x "$d/bin/find"
  mkfifo "$R/.git/objects/info/alternates"
  REAL_FIND=$(cat "$d/real-find") PATH="$d/bin:$SLOW:$SHIMS:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 \
    "$BIN/repo-state-check" snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  chmod 700 "$R/.git/inaccessible"
  [ "$rc" = 3 ] || fail 'failed sweep did not fail closed'
  grep -Fxq "repo-state-check: snapshot timed out; pre-sweep failed; special files found so far: $R/.git/objects/info/alternates; cause unknown" "$d/err" || { cat "$d/err" >&2; fail 'failed sweep message missing'; }
  grep -q '^unsafe' "$d/file" || fail 'partial sweep discarded'
  ! grep -q 'pre-sweep skipped' "$d/err" || fail 'failed sweep reported skipped'
  survivors; no_bound_dir
  # With nothing found, the plain message stays.
  rm "$R/.git/objects/info/alternates"
  rc=0
  REAL_FIND=$(cat "$d/real-find") PATH="$d/bin:$SLOW:$SHIMS:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 \
    "$BIN/repo-state-check" snapshot "$R" "$d/file2" 2> "$d/err2" || rc=$?
  [ "$rc" = 3 ] || fail 'failed sweep (none found) did not fail closed'
  grep -Fxq 'repo-state-check: snapshot timed out; pre-sweep failed; cause unknown' "$d/err2" || { cat "$d/err2" >&2; fail 'plain failed sweep message missing'; }
  survivors; no_bound_dir
)
case_compare_storage() (
  set -eu; setup_mode
  local d
  fixture; d=$(outdir)
  cli snapshot "$R" "$d/before"
  cp "$d/before" "$d/after"
  # Reject creation itself, including directories removed before compare returns.
  mktemp() { fail 'compare created temporary storage'; }
  rc_is 0 repo_state_compare "$d/before" "$d/after" "$d/changes"
  unset -f mktemp
  [ ! -s "$d/changes" ] || fail 'self compare produced changes'
  no_bound_dir
)
case_cli_forged_completion() (
  set -eu; setup_mode
  local d rc=0
  [ "$CASE_MODE" = timeout ] || exit 0
  fixture; d=$(outdir)
  compare_pair "$d"
  mkdir "$d/bin"
  cat > "$d/bin/timeout" <<'TIMER'
#!/usr/bin/env bash
shift 3
# Both processes inherit this timer's isolated group, created by the runner.
"$@" &
child=$!
/bin/sleep 0.5
for private in "$TMPDIR"/repo-state-bound.*; do
  printf 'done 0\n' > "$private/done"
done
# The group includes the tagged slow Git started for this invocation.
ps -ax -o command= | grep -qF "tagged-$RUN_ID" || exit 8
kill -TERM -- "-$$"
wait "$child"
TIMER
  chmod +x "$d/bin/timeout"
  PATH="$d/bin:$SLOW:$SHIMS:$PATH" "$BIN/repo-state-check" compare "$d/before" "$d/after" > "$d/out" 2> "$d/err" || rc=$?
  [ "$rc" = 2 ] || fail 'forged compare was accepted'
  [ "$(grep -Ec '^state: compare could not complete \(.+\)$' "$d/out")" = 1 ] || fail 'unevaluated compare lacks its state line'
  survivors; no_bound_dir
)
export -f case_compare_storage case_cli_forged_completion

case_premark_rename_failure() (
  set -eu; setup_mode
  local d rc=0
  fixture; d=$(outdir)
  mkdir "$d/bin"
  printf '#!/bin/sh\nexit 1\n' > "$d/bin/mv"
  chmod +x "$d/bin/mv"
  # The pre-mark is by rename only: when it cannot be made, nothing is written
  # through a symlink or opened at the output path.
  printf sentinel > "$d/sentinel"
  ln -s "$d/sentinel" "$d/link"
  PATH="$d/bin:$SHIMS:$PATH" "$BIN/repo-state-check" snapshot "$R" "$d/link" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail 'failed rename was accepted'
  [ "$(cat "$d/sentinel")" = sentinel ] || fail 'failed pre-mark wrote through a symlink'
  # A regular file sharing its inode with another path is never opened for writing.
  ln "$d/sentinel" "$d/hard"
  rc=0
  PATH="$d/bin:$SHIMS:$PATH" "$BIN/repo-state-check" snapshot "$R" "$d/hard" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail 'failed rename on a regular file was accepted'
  [ "$(cat "$d/sentinel")" = sentinel ] || fail 'failed pre-mark wrote through a hard link'
  no_state_dir "$d"; no_bound_dir
)
export -f case_premark_rename_failure

case_watchdog_repeated() (
  set -eu
  [ "$CASE_MODE" = watchdog ] || exit 0
  need_real_git_block case_watchdog_repeated alternates
  local i j n ncpu pid burners=()
  ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
  n=$((ncpu - 2)); [ "$n" -ge 1 ] || n=1
  reap_burners() {
    local pid
    for pid in ${burners[@]+"${burners[@]}"}; do wait "$pid" 2>/dev/null || true; done
    burners=()
  }
  # Every burner runs under its own deadline, and only those pids are signalled or waited on.
  trap reap_burners EXIT
  for ((i=0; i<12; i++)); do
    for ((j=0; j<n; j++)); do
      "$BCASE_TIMER" -k 1 12 bash -c 'while :; do :; done' &
      burners[${#burners[@]}]=$!
    done
    SKIP_PROBE=1 case_1_snapshot_alternates_fifo
    # Stop only the burners this iteration started; their timers still bound them.
    for pid in "${burners[@]}"; do kill "$pid" 2>/dev/null || true; done
    reap_burners
  done
)
# A stale cancel variable in the environment must never be acted on.
case_stale_bound_env() (
  set -eu; setup_mode
  local d pid rc=0
  d=$(outdir); mkdir "$d/sentinel-dir"
  # A sleep the test starts, in its own process group.
  set -m
  bash -c 'exec -a "tagged-sleep-$RUN_ID" /bin/sleep 60' &
  pid=$!
  set +m
  echo "$pid tagged-sleep-$RUN_ID" >> "$RUN_PID_FILE"
  REPO_STATE_BOUND_PID=$pid REPO_STATE_BOUND_WATCHDOG=$pid REPO_STATE_BOUND_PRIVATE="$d/sentinel-dir" \
    "$BIN/repo-state-check" --help > /dev/null || rc=$?
  [ "$rc" = 0 ] || { kill "$pid" 2>/dev/null || true; fail "--help exited $rc"; }
  [ -d "$d/sentinel-dir" ] || { kill "$pid" 2>/dev/null || true; fail 'stale private variable removed a directory'; }
  kill -0 "$pid" 2>/dev/null || fail 'stale pid variable killed a process group'
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  survivors; no_bound_dir
)

# A helper that dies mid-compare must never read as a verdict.
case_compare_helper_failure() (
  set -eu; setup_mode
  local d rc=0 real_awk
  fixture; d=$(outdir)
  cli snapshot "$R" "$d/before"
  printf '#!/bin/sh\nexit 0\n' > "$R/.git/hooks/pre-commit"
  chmod +x "$R/.git/hooks/pre-commit"
  cli snapshot "$R" "$d/after"
  rc_is 2 cli compare "$d/before" "$d/after" > "$d/baseline-out"
  real_awk=$(command -v awk)
  mkdir "$d/bin"
  cat > "$d/bin/awk" <<'AWK'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in *hasold*|*nmax*) kill -KILL $$ ;; esac
done
exec "$REAL_AWK" "$@"
AWK
  chmod +x "$d/bin/awk"
  REAL_AWK=$real_awk PATH="$d/bin:$SHIMS:$PATH" "$BIN/repo-state-check" compare "$d/before" "$d/after" > "$d/out" 2> "$d/err" || rc=$?
  case "$rc" in 2|3) ;; *) fail "a dying helper gave compare status $rc" ;; esac
  grep -Eq '^state: ' "$d/out" || fail 'a dying helper left no state line'
  survivors; no_bound_dir
)

# A FIFO renamed over the output temporary must not hang the CLI.
case_fifo_over_temp() (
  set -eu; setup_mode
  local d rc=0
  fixture; d=$(outdir)
  mkdir "$d/bin"
  cat > "$d/bin/git" <<'SHIM'
#!/usr/bin/env bash
echo $$ >> "$RUN_PID_FILE"
case " $* " in
  *' worktree list '*)
    for t in "$OUTDIR"/.repo-state-out.*; do
      [ -f "$t" ] || continue
      rm -f "$t"; mkfifo "$t"
    done ;;
esac
exec -a "tagged-$RUN_ID" "$REAL_GIT" "$@"
SHIM
  chmod +x "$d/bin/git"
  OUTDIR=$d PATH="$d/bin:$SHIMS:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=20 \
    "$BCASE_TIMER" -k 1 15 "$BIN/repo-state-check" snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 0 ] || fail "temporary planting changed snapshot status $rc"
  [ "$(first_line "$d/file")" = repo ] || fail 'temporary planting changed snapshot output'
  survivors; no_state_dir "$d"; no_bound_dir
)

# A symlinked .git is never followed by the pre-sweep; a symlinked repo path still is.
case_symlinked_gitdir() (
  set -eu; setup_mode
  local d rc=0
  fixture; d=$(outdir)
  mv "$R/.git" "$d/realgit"
  ln -s "$d/realgit" "$R/.git"
  mkfifo "$d/realgit/FETCH_HEAD"
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail "expected 3, got $rc"
  ! grep -q '^unsafe' "$d/file" || fail 'a symlinked .git was followed'
  grep -Fq 'pre-sweep skipped (.git is not a directory)' "$d/err" || fail 'skip message missing'
  survivors; no_state_dir "$d"; no_bound_dir
)

# The watchdog decides from the child, not from a file the child can plant.
case_planted_token() (
  set -eu; setup_mode
  local rc=0
  [ "$CASE_MODE" = watchdog ] || exit 0
  plant_and_wait() {
    local private
    for private in "$TMPDIR"/repo-state-bound.*; do printf 'done 0\n' > "$private/done"; done
    /bin/sleep 8
  }
  repo_state_run_bounded 1 plant_and_wait || rc=$?
  [ "$rc" = 124 ] || fail "a planted token disarmed the watchdog (status $rc)"
  no_bound_dir
)

# A trapped signal in the caller must not end the wait early.
case_trapped_signal_wait() (
  set -eu; setup_mode
  local d rc=0 self
  d=$(outdir)
  self=${BASHPID:-$(exec sh -c 'echo "$PPID"')}
  trap ':' USR1
  slow_ok() { /bin/sleep 3; }
  ( /bin/sleep 1; kill -USR1 "$self" 2>/dev/null || true ) &
  repo_state_run_bounded 20 slow_ok || rc=$?
  wait 2>/dev/null || true
  [ "$rc" = 0 ] || fail "a trapped signal ended the wait early (status $rc)"
  no_bound_dir
)

# The generated script is one group, so it is parsed whole before anything runs.
case_script_grouped() (
  set -eu; setup_mode
  local d rc=0
  d=$(outdir); mkdir "$d/bin"
  cat > "$d/bin/bash" <<'SHIM'
#!/bin/sh
script=$1; shift
cat "$script" > "$SCRIPT_COPY"
exec "$REAL_BASH" "$SCRIPT_COPY" "$@"
SHIM
  chmod +x "$d/bin/bash"
  ok_op() { :; }
  REAL_BASH=$(command -v bash) SCRIPT_COPY="$d/script" PATH="$d/bin:$PATH" repo_state_run_bounded 5 ok_op || rc=$?
  [ "$rc" = 0 ] || fail "grouped script failed ($rc)"
  [ "$(head -n 1 "$d/script")" = '{' ] || fail 'script does not open a group'
  [ "$(tail -n 1 "$d/script")" = '}' ] || fail 'script does not close its group'
  bash -n "$d/script" || fail 'script does not parse'
  no_bound_dir
)

# Deterministic copies of the real-git FIFO cases: the slow-git shim stands in for git.
case_slow_alternates_fifo() (
  set -eu; setup_mode
  local d rc=0
  fixture; d=$(outdir)
  mkfifo "$R/.git/objects/info/alternates"
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail "expected 3, got $rc"
  [ "$(first_line "$d/file")" = unreadable ] || fail 'file not unreadable'
  grep -q $'^unsafe\t.*objects/info/alternates' "$d/file" || fail 'unsafe line missing'
  grep -q 'repo-state-check: snapshot timed out; special files found in git metadata:.*objects/info/alternates' "$d/err" || fail 'message (a) missing'
  survivors; no_state_dir "$d"; no_bound_dir
)
case_slow_linked_worktree() (
  set -eu; setup_mode
  local d rc=0 wt
  fixture; d=$(outdir)
  wt="$R-linked"
  "$REAL_GIT" -C "$R" worktree add -q -b linked "$wt"
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli snapshot "$wt" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail "expected 3, got $rc"
  [ "$(first_line "$d/file")" = unreadable ] || fail 'file not unreadable'
  ! grep -q '^unsafe' "$d/file" || fail 'unexpected unsafe line'
  grep -Fq 'repo-state-check: snapshot timed out; pre-sweep skipped (.git is not a directory); cause unknown' "$d/err" || fail 'message (c) missing'
  survivors; no_state_dir "$d"; no_bound_dir
)
case_slow_watchdog_ran() (
  set -eu; setup_mode
  local d rc=0
  [ "$CASE_MODE" = watchdog ] || exit 0
  fixture; d=$(outdir)
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail "expected 3, got $rc"
  grep -q ' tagged-sleep-' "$RUN_PID_FILE" || fail 'watchdog never started'
  survivors; no_bound_dir
)
export -f case_stale_bound_env case_compare_helper_failure case_fifo_over_temp case_symlinked_gitdir
export -f case_planted_token case_trapped_signal_wait case_script_grouped
export -f case_slow_alternates_fifo case_slow_linked_worktree case_slow_watchdog_ran
export -f case_completion_integrity case_cli_signals case_symlink_path case_failed_sweep case_watchdog_repeated

export -f real_git_blocks need_real_git_block fixture fail rc_is setup_mode cli slow_cli outdir survivors no_state_dir no_bound_dir first_line moved_ref_fixture compare_pair
export -f case_1_snapshot_alternates_fifo case_2_snapshot_slow_git case_3_compare_loose_object_fifo case_4_compare_slow_git
export -f case_5_clean_repo case_6_limit_helper case_7_linked_worktree case_8_external_kill case_9_healthy_special_file
export -f case_10_worker_bound case_11_cli_invalid_limit case_12_unevaluated_child case_12b_timer_claims_success case_13_hostile_output_path
export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM

run_bcase() {
  local fn=$1 bound=$2 mode=$3 rc=0
  CASE_MODE=$mode "$BCASE_TIMER" -k 1 "$bound" bash -c '. "$BIN/lib/repo-state.sh"; "$@"' _ "$fn" || rc=$?
  case "$rc" in
    0) echo "$fn ($mode) PASS" ;;
    77) echo "$fn ($mode) SKIPPED" ;;
    *) fail "$fn ($mode) failed or exceeded its ${bound}s bound (rc=$rc)" ;;
  esac
}
# One timer mode per run, so the runner can run both modes in parallel:
# test-repo-state-cli-watchdog.sh runs this file with REPO_STATE_CLI_MODES=watchdog.
case "${REPO_STATE_CLI_MODES:-timeout}" in
  timeout|watchdog|"timeout watchdog") ;;
  *) fail "unknown REPO_STATE_CLI_MODES: ${REPO_STATE_CLI_MODES}" ;;
esac
for bcase_mode in ${REPO_STATE_CLI_MODES:-timeout}; do
  run_bcase case_completion_integrity 20 "$bcase_mode"
  run_bcase case_compare_storage 20 "$bcase_mode"
  run_bcase case_premark_rename_failure 20 "$bcase_mode"
  run_bcase case_cli_forged_completion 20 "$bcase_mode"
  run_bcase case_cli_signals 65 "$bcase_mode"
  run_bcase case_symlink_path 20 "$bcase_mode"
  run_bcase case_failed_sweep 20 "$bcase_mode"
  run_bcase case_stale_bound_env 40 "$bcase_mode"
  run_bcase case_compare_helper_failure 40 "$bcase_mode"
  run_bcase case_fifo_over_temp 40 "$bcase_mode"
  run_bcase case_symlinked_gitdir 40 "$bcase_mode"
  run_bcase case_planted_token 40 "$bcase_mode"
  run_bcase case_trapped_signal_wait 40 "$bcase_mode"
  run_bcase case_script_grouped 40 "$bcase_mode"
  run_bcase case_slow_alternates_fifo 40 "$bcase_mode"
  run_bcase case_slow_linked_worktree 40 "$bcase_mode"
  run_bcase case_slow_watchdog_ran 40 "$bcase_mode"
  run_bcase case_watchdog_repeated 180 "$bcase_mode"
  run_bcase case_1_snapshot_alternates_fifo 40 "$bcase_mode"
  run_bcase case_2_snapshot_slow_git 40 "$bcase_mode"
  run_bcase case_3_compare_loose_object_fifo 40 "$bcase_mode"
  run_bcase case_4_compare_slow_git 40 "$bcase_mode"
  run_bcase case_5_clean_repo 60 "$bcase_mode"
  run_bcase case_6_limit_helper 40 "$bcase_mode"
  run_bcase case_7_linked_worktree 40 "$bcase_mode"
  run_bcase case_8_external_kill 60 "$bcase_mode"
  run_bcase case_9_healthy_special_file 40 "$bcase_mode"
  run_bcase case_10_worker_bound 90 "$bcase_mode"
  run_bcase case_11_cli_invalid_limit 40 "$bcase_mode"
  run_bcase case_12_unevaluated_child 40 "$bcase_mode"
  run_bcase case_12b_timer_claims_success 40 "$bcase_mode"
  run_bcase case_13_hostile_output_path 40 "$bcase_mode"
done
fi
echo 'repo-state CLI tests passed'
