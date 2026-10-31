#!/usr/bin/env bash
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib/test-dispatch-worker-lib.sh"
REAL_PERL=$(command -v perl)
base_path=$PATH
printf 'First brief line.\nReview the diff.\nFinal brief line.\n' > "$BRIEF"
export SIGNAL_TAG="signal-$$-$RANDOM"
mkdir "$TMP/helper-path"
IFS=: read -r -a path_dirs <<< "$PATH"
for directory in "${path_dirs[@]}"; do
  for executable in "$directory"/*; do
    [ -x "$executable" ] && [ ! -d "$executable" ] || continue
    name=${executable##*/}
    case "$name" in timeout|gtimeout) continue ;; esac
    [ -e "$TMP/helper-path/$name" ] || ln -s "$executable" "$TMP/helper-path/$name"
  done
done
cat > "$TMP/agent" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  models) printf '%s\tModel\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"; exit 0 ;;
  agent) [ "${SIGNAL_ROSTER_HANG:-0}" != 1 ] || exec sleep 30; printf '%s\n' peer-code-reviewer; exit 0 ;;
esac
cat > "$SIGNAL_INPUT"
echo $$ > "$SIGNAL_PID"
if [ "${SIGNAL_DESCENDANT:-0}" = 1 ]; then
  trap 'exit 0' TERM
  bash -c 'trap "" TERM INT HUP; echo $$ > "$SIGNAL_DESC_PID"; while :; do sleep .05; done' &
  while [ ! -s "$SIGNAL_DESC_PID" ]; do sleep .02; done
fi
[ "$SIGNAL_IGNORE" != 1 ] || trap '' TERM
[ "${SIGNAL_DRAIN:-0}" != 1 ] || trap 'sleep .3; : > "$SIGNAL_DRAINED"; exit 0' TERM
: > "$SIGNAL_READY"
while :; do sleep .05; done
STUB
chmod +x "$TMP/agent"
for runtime in codex agy; do
  printf '#!/bin/bash\nexec -a "$SIGNAL_TAG" bash "%s" "$@"\n' "$TMP/agent" > "$TMP/bin/$runtime"
  chmod +x "$TMP/bin/$runtime"
done
cat > "$TMP/signal-guard" <<'PERL'
use strict;
use POSIX qw(:sys_wait_h setsid);
use Time::HiRes qw(time sleep);
my $pid = fork(); die $! unless defined $pid;
if (!$pid) {
    setsid();
    $SIG{INT}=$SIG{TERM}=$SIG{HUP}='DEFAULT';
    exec @ARGV; POSIX::_exit(125);
}
my $end = time() + 12;
my $sent = 0;
while (1) {
    if (waitpid($pid, WNOHANG) == $pid) {
        exit(WIFSIGNALED($?) ? 128 + WTERMSIG($?) : WEXITSTATUS($?));
    }
    if (!$sent && $ENV{SIGNAL_NAME} ne 'NONE' && -f $ENV{SIGNAL_READY}) {
        kill $ENV{SIGNAL_NAME}, ($ENV{SIGNAL_SCOPE} eq 'group' ? -$pid : $pid);
        $sent = 1;
        $end = time() + 6;
    }
    if (time() > $end) {
        kill 'KILL', -$pid;
        if (open my $fh, '<', $ENV{SIGNAL_PID}) { my $agent=<$fh>; kill 'KILL', $agent; }
        if ($ENV{SIGNAL_DESC_PID} && open my $fh, '<', $ENV{SIGNAL_DESC_PID}) { my $desc=<$fh>; kill 'KILL', $desc; }
        waitpid($pid, 0); exit 125;
    }
    sleep .02;
}
PERL
for timer_mode in GNU helper; do
  export PATH=$base_path
  if [ "$timer_mode" = GNU ] && ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    echo 'SKIP: GNU timer not installed'
    continue
  fi
  if [ "$timer_mode" = helper ]; then export PATH="$TMP/helper-path"; fi
  export PATH
  for scenario in codex:INT:group:0 agy:INT:group:0 agy:TERM:pid:0 agy:INT:group:1 agy:HUP:group:0; do
    IFS=: read -r runtime SIGNAL_NAME SIGNAL_SCOPE SIGNAL_IGNORE <<< "$scenario"
    export SIGNAL_NAME SIGNAL_SCOPE SIGNAL_IGNORE
    export SIGNAL_READY="$TMP/ready" SIGNAL_INPUT="$TMP/input" SIGNAL_PID="$TMP/agent-pid"
    rm -f "$SIGNAL_READY" "$SIGNAL_INPUT" "$SIGNAL_PID"
    rc=0
    TIMEOUT=60 KILL_AFTER=1 "$REAL_PERL" "$TMP/signal-guard" "$DW" --runtime "$runtime" --brief "$BRIEF" > "$TMP/out" 2> "$TMP/err" || rc=$?
    expected=130; [ "$SIGNAL_NAME" = INT ] || expected=143
    [ "$rc" = "$expected" ] || { cat "$TMP/err"; fail "$timer_mode $scenario status $rc"; }
    "$REAL_PERL" -e 'local $/; open my $b, "<", $ARGV[0] or die $!; my $brief=<$b>; open my $i, "<", $ARGV[1] or die $!; exit(index(<$i>, $brief) < 0)' "$BRIEF" "$SIGNAL_INPUT" || fail 'brief stdin lost' 
    pid=$(cat "$SIGNAL_PID")
    tries=0
    while kill -0 "$pid" 2>/dev/null; do
      tries=$((tries + 1)); [ "$tries" -lt 50 ] || { fail 'agent survived'; break; }
      sleep .02
    done
    echo "$timer_mode $scenario PASS"
  done
  for runtime in codex agy; do
    for SIGNAL_NAME in NONE INT; do
      export SIGNAL_NAME SIGNAL_SCOPE=group SIGNAL_IGNORE=0 SIGNAL_DESCENDANT=1
      export SIGNAL_DESC_PID="$TMP/desc-pid"
      rm -f "$SIGNAL_READY" "$SIGNAL_DESC_PID"
      rc=0
      started=$SECONDS
      TIMEOUT=2 KILL_AFTER=1 "$REAL_PERL" "$TMP/signal-guard" "$DW" --runtime "$runtime" --brief "$BRIEF" > "$TMP/out" 2> "$TMP/err" || rc=$?
      expected=124; [ "$SIGNAL_NAME" != INT ] || expected=130
      [ "$rc" = "$expected" ] && [ "$((SECONDS - started))" -lt 7 ] || fail "$timer_mode $runtime descendant $SIGNAL_NAME rc=$rc"
      pid=$(cat "$SIGNAL_DESC_PID")
      state=$(ps -o stat= -p "$pid" 2>/dev/null || :)
      case "$state" in ''|*Z*) ;; *) kill -KILL "$pid" 2>/dev/null || :; fail 'descendant survived' ;; esac
    done
  done
  unset SIGNAL_DESCENDANT
  export SIGNAL_NAME=TERM SIGNAL_SCOPE=pid SIGNAL_IGNORE=0 SIGNAL_DRAIN=1 SIGNAL_DRAINED="$TMP/drained"
  rm -f "$SIGNAL_READY" "$SIGNAL_DRAINED"
  rc=0
  TIMEOUT=60 KILL_AFTER=5 "$REAL_PERL" "$TMP/signal-guard" "$DW" --runtime agy --brief "$BRIEF" > "$TMP/out" 2> "$TMP/err" || rc=$?
  [ "$rc" = 143 ] || fail "$timer_mode signal drain status $rc"
  [ -f "$SIGNAL_DRAINED" ] || fail "$timer_mode signal drain missing"
  unset SIGNAL_DRAIN
  echo "$timer_mode signal drain PASS"
  if [ "$timer_mode" = helper ]; then
    started=$SECONDS
    rc=0
    SIGNAL_ROSTER_HANG=1 "$DW" --runtime agy --agent peer-code-reviewer --brief "$BRIEF" > "$TMP/out" 2> "$TMP/err" || rc=$?
    [ "$rc" = 2 ] && [ "$((SECONDS - started))" -le 7 ] || fail "roster probe rc=$rc"
    grep -q 'roster\|persona' "$TMP/err" || fail 'roster refusal missing'
  fi
done
# Normal returns preserve status and the caller's signal handlers.
for normal_path in "$base_path" "$TMP/helper-path"; do
(
  set -e
  export PATH="$normal_path"
  . "$SELF_DIR/lib/timeout-bin.sh"
  eval "$(sed -n '/^run_with_timeout() {$/,/^}$/p' "$DW")"
  export TIMEOUT=3 KILL_AFTER=1
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  before=$(trap -p INT TERM HUP)
  rc=0
  run_with_timeout bash -c 'exit 7' || rc=$?
  [ "$rc" = 7 ]
  [ "$(trap -p INT TERM HUP)" = "$before" ]
  run_with_timeout true
) || exit 1
done

[ "$FAILS" = 0 ]
