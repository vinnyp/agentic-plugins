#!/usr/bin/env bash
set -eu
SELF_DIR=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
. "$SELF_DIR/lib/test-env-reset.sh"
reset_dispatch_env
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/portable-timeout.XXXXXX")
[ -n "$TASK_TMP" ] || exit 1
RUN_ID="pt-$$-$RANDOM"
export RUN_ID TASK_TMP
cleanup() {
  if [ -f "$TASK_TMP/pids" ]; then
    while IFS= read -r pid; do
      if ps -p "$pid" -o command= 2>/dev/null | grep -Fq "tagged-$RUN_ID"; then
        kill -KILL "$pid" 2>/dev/null || :
      fi
    done < "$TASK_TMP/pids"
  fi
  rm -rf "$TASK_TMP"
}
trap cleanup EXIT
. "$SELF_DIR/lib/timeout-bin.sh"
HELPER=$_DISPATCH_TIMEOUT_HELPER
PERL=$(command -v perl)
BASH_BIN=$BASH
export BASH_BIN
# Independent outer guard, including for a timer that never forwards signals.
cat > "$TASK_TMP/guard" <<'PERL'
use strict;
use POSIX qw(:sys_wait_h setpgid);
use Time::HiRes qw(time sleep);
my $pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) { setpgid(0, 0); exec @ARGV; POSIX::_exit(125); }
my $end = time() + 7;
my $sent = 0;
while (1) {
    if (waitpid($pid, WNOHANG) == $pid) {
        exit(WIFSIGNALED($?) ? 128 + WTERMSIG($?) : WEXITSTATUS($?));
    }
    if ($ENV{SEND_SIGNAL} && !$sent && -f "$ENV{TASK_TMP}/ready") {
        kill $ENV{SEND_SIGNAL}, $pid;
        $sent = 1;
    }
    if (time() >= $end) {
        kill 'KILL', $pid;
        kill 'KILL', -$pid;
        waitpid($pid, 0);
        exit 125;
    }
    sleep(0.02);
}
PERL
cat > "$TASK_TMP/descendant" <<'BASH'
echo $$ >> "$TASK_TMP/pids"
if [ "$1" = reach ]; then
  trap 'printf reached > "$TASK_TMP/reached"; exit 0' TERM INT HUP
else
  trap '' TERM
fi
: > "$TASK_TMP/desc-ready"
while :; do sleep 0.05; done
BASH
cat > "$TASK_TMP/fixture" <<'BASH'
echo $$ >> "$TASK_TMP/pids"
mode=$1
case "$mode" in
  catch) trap 'exit 0' TERM ;;
  five) trap 'exit 5' TERM ;;
  ignore|tree) trap '' TERM ;;
  reach)
    trap 'while [ ! -f "$TASK_TMP/reached" ]; do sleep 0.02; done; wait; exit 0' TERM INT HUP ;;
esac
if [ "$mode" = tree ] || [ "$mode" = reach ] || [ "$mode" = detach ]; then
  perl -MPOSIX -e '
    $SIG{INT} = $SIG{QUIT} = "DEFAULT";
    POSIX::setsid() if $ARGV[0] eq "detach";
    shift @ARGV;
    exec @ARGV;
  ' "$mode" "$BASH_BIN" -c '
    exec -a "tagged-$RUN_ID" "$BASH_BIN" -c ". \"\$TASK_TMP/descendant\"" -- "$1"
  ' -- "$mode" &
  while [ ! -f "$TASK_TMP/desc-ready" ]; do sleep 0.02; done
fi
[ "$mode" != detach ] || exit 0
: > "$TASK_TMP/ready"
while :; do sleep 0.05; done
BASH
fixture=("$BASH_BIN" -c 'exec -a "tagged-$RUN_ID" "$BASH_BIN" -c ". \"\$TASK_TMP/fixture\"" -- "$@"' --)
check() {
  local name=$1 expected=$2 rc=0
  shift 2
  rm -f "$TASK_TMP/ready" "$TASK_TMP/desc-ready" "$TASK_TMP/reached"
  "$PERL" "$TASK_TMP/guard" "$@" > "$TASK_TMP/out" 2> "$TASK_TMP/err" || rc=$?
  if [ "$rc" != "$expected" ]; then
    cat "$TASK_TMP/err" >&2
    echo "$name ($label) FAIL: expected $expected, got $rc" >&2
    exit 1
  fi
  echo "$name ($label) PASS"
}
assert_gone() {
  local pid tries=0
  while IFS= read -r pid; do
    tries=0
    while ps -p "$pid" -o command= 2>/dev/null | grep -Fq "tagged-$RUN_ID"; do
      tries=$((tries + 1))
      [ "$tries" -lt 50 ] || { echo 'FAIL: tagged descendant survived'; exit 1; }
      sleep 0.02
    done
  done < "$TASK_TMP/pids"
}
conformance() {
  local timer=$1 signal
  check exit-zero 0 "$timer" 3 "$BASH_BIN" -c 'exit 0'
  check exit-seven 7 "$timer" 3 "$BASH_BIN" -c 'exit 7'
  check expiry 124 "$timer" .2 "${fixture[@]}" catch
  check grace-exit-zero 124 "$timer" -k 1 .2 "${fixture[@]}" catch
  check kill-stage 137 "$timer" -k .2 .2 "${fixture[@]}" ignore
  SEND_SIGNAL=TERM check forwarded-kill 137 "$timer" -k .2 3 "${fixture[@]}" ignore
  SEND_SIGNAL=TERM check forwarded-five 5 "$timer" 3 "${fixture[@]}" five
  SEND_SIGNAL=TERM check forwarded-death 143 "$timer" 3 "${fixture[@]}" plain
  check not-executable 126 "$timer" 3 "$TASK_TMP/not-executable"
  check not-found 127 "$timer" 3 "$TASK_TMP/absent"
  check bad-duration 125 "$timer" bogus true
  check unknown-option 125 "$timer" --bogus 3 true
  check missing-command 125 "$timer" 3
  check missing-grace 125 "$timer" -k
  check negative-duration 125 "$timer" -1 true
  check bad-suffix 125 "$timer" 1ms true
  SEND_SIGNAL=TERM check zero-forwarding 5 "$timer" 0 "${fixture[@]}" five
  check zero-limit 7 "$timer" 0 "$BASH_BIN" -c 'exit 7'
  check zero-kill 124 "$timer" -k 0 .2 "${fixture[@]}" catch
  check seconds 0 "$timer" 3s true
  check hours 0 "$timer" 1h true
  check days 0 "$timer" 1d true
  check minutes 0 "$timer" .05m true
  check decimal 124 "$timer" .15s "${fixture[@]}" catch
  check argv 0 "$timer" 3 "$BASH_BIN" -c '[ "$#" = 3 ] && [ "$1" = "a b" ] && [ -z "$2" ] && [ "$3" = '\'';$() *'\'' ]' -- 'a b' '' ';$() *'
  check no-arguments 0 "$timer" 3 true
  printf 'input value\n' > "$TASK_TMP/input"
  check stdin 0 "$timer" 3 "$BASH_BIN" -c 'IFS= read -r x; [ "$x" = "input value" ]' < "$TASK_TMP/input"
  : > "$TASK_TMP/pids"
  check descendant-kill 137 "$timer" -k .2 .3 "${fixture[@]}" tree
  assert_gone
  for signal in TERM INT HUP; do
    SEND_SIGNAL=$signal check "descendant-$signal" 0 "$timer" 3 "${fixture[@]}" reach
  done
  if [ "$timer" = "$HELPER" ]; then
    SEND_SIGNAL=INT check ignored-entry 130 "$PERL" -e '$SIG{INT}="IGNORE"; exec @ARGV' "$timer" 3 "${fixture[@]}" plain
  fi
  : > "$TASK_TMP/pids"
  check detached-return 0 "$timer" 3 "${fixture[@]}" detach
  local pid
  pid=$(tail -1 "$TASK_TMP/pids")
  ps -p "$pid" -o command= | grep -Fq "tagged-$RUN_ID"
  kill -KILL "$pid"
  assert_gone
}
: > "$TASK_TMP/not-executable"
label=helper
conformance "$HELPER"
oracle=
for candidate in timeout gtimeout; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" --version 2>/dev/null | grep -q 'GNU coreutils'; then
    oracle=$(command -v "$candidate"); break
  fi
done
if [ -n "$oracle" ]; then label=GNU; conformance "$oracle"; else echo 'SKIP oracle leg: no GNU timeout'; fi

mkdir "$TASK_TMP/path"
ln -s "$PERL" "$TASK_TMP/path/perl"
for name in timeout gtimeout; do
  printf '#!/bin/bash\nexit 0\n' > "$TASK_TMP/path/$name"
  chmod +x "$TASK_TMP/path/$name"
done
(
  set -euo pipefail
  export PATH="$TASK_TMP/path"
  [ -z "$(. "$SELF_DIR/lib/timeout-bin.sh")" ]
  . "$SELF_DIR/lib/timeout-bin.sh"
  [ "$(dispatch_timeout_bin)" = timeout ]
  /bin/rm "$TASK_TMP/path/timeout"
  [ "$(dispatch_timeout_bin)" = gtimeout ]
  /bin/rm "$TASK_TMP/path/gtimeout"
  cd /
  [ "$(dispatch_timeout_bin)" = "$HELPER" ]
  /bin/rm "$TASK_TMP/path/perl"
  printf '#!/bin/bash\n[ "$#" = 4 ] && [ "$1" = -MPOSIX ] && [ "$2" = -MTime::HiRes ] && [ "$3" = -e ] && [ "$4" = 1 ] && exit 1\nexit 0\n' > "$TASK_TMP/path/perl"
  /bin/chmod +x "$TASK_TMP/path/perl"
  rc=0
  result=$(dispatch_timeout_bin) || rc=$?
  [ "$rc" = 1 ] && [ -z "$result" ]
)
echo 'dispatch_timeout_bin precedence, fallback, probe and source path PASS'
