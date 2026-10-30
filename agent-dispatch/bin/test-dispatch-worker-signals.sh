#!/usr/bin/env bash
SELF_DIR=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
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
  agent) printf '%s\n' peer-code-reviewer; exit 0 ;;
esac
cat > "$SIGNAL_INPUT"
echo $$ > "$SIGNAL_PID"
[ "$SIGNAL_IGNORE" != 1 ] || trap '' TERM
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
    if (!$sent && -f $ENV{SIGNAL_READY}) {
        kill $ENV{SIGNAL_NAME}, ($ENV{SIGNAL_SCOPE} eq 'group' ? -$pid : $pid);
        $sent = 1;
        $end = time() + 6;
    }
    if (time() > $end) {
        kill 'KILL', -$pid;
        if (open my $fh, '<', $ENV{SIGNAL_PID}) { my $agent=<$fh>; kill 'KILL', $agent; }
        waitpid($pid, 0); exit 125;
    }
    sleep .02;
}
PERL
for timer_mode in GNU helper; do
  PATH=$base_path
  if [ "$timer_mode" = GNU ] && ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    echo 'SKIP: GNU timer not installed'
    continue
  fi
  if [ "$timer_mode" = helper ]; then PATH="$TMP/helper-path"; fi
  export PATH
  for scenario in codex:INT:group:0 agy:INT:group:0 agy:TERM:pid:0 agy:INT:group:1; do
    IFS=: read -r runtime SIGNAL_NAME SIGNAL_SCOPE SIGNAL_IGNORE <<< "$scenario"
    export SIGNAL_NAME SIGNAL_SCOPE SIGNAL_IGNORE
    export SIGNAL_READY="$TMP/ready" SIGNAL_INPUT="$TMP/input" SIGNAL_PID="$TMP/agent-pid"
    rm -f "$SIGNAL_READY" "$SIGNAL_INPUT" "$SIGNAL_PID"
    rc=0
    TIMEOUT=60 KILL_AFTER=1 "$REAL_PERL" "$TMP/signal-guard" "$DW" --runtime "$runtime" --brief "$BRIEF" > "$TMP/out" 2> "$TMP/err" || rc=$?
    expected=130; [ "$SIGNAL_NAME" != TERM ] || expected=143
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
done
# Normal returns preserve status and the caller's signal handlers.
for normal_path in "$base_path" "$TMP/helper-path"; do
(
  set -e
  export PATH="$normal_path"
  . "$SELF_DIR/lib/timeout-bin.sh"
  eval "$(sed -n '/^run_with_timeout() {$/,/^}$/p' "$DW")"
  TIMEOUT=3 KILL_AFTER=1
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
