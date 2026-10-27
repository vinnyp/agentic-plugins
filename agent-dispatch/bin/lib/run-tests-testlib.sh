#!/usr/bin/env bash
# Shared functions and variables are consumed by both runner suites.
# shellcheck disable=SC2034,SC2120
set -eu
# Discard runner caches inherited from an outer gate; preserve the explicit
# test-group protocol and reset test hooks separately below.
unset RUN_TESTS__PS_AVAILABLE
unset RUN_TESTS_JOBS RUN_TESTS_TIMEOUT RUN_TESTS_KEEP_LOGS RUN_TESTS__TEST_DROP_RC RUN_TESTS__TEST_NOGROUP RUN_TESTS__TEST_KILL_GRACE
export RUN_TESTS__TEST_KILL_GRACE=2
if [ "${RUN_TESTS__TEST_GROUP_EXPLICIT:-}" != 1 ]; then unset RUN_TESTS__TEST_GROUP; fi
unset RUN_TESTS__TEST_GROUP_EXPLICIT
PERL=$(command -v perl || :)
SOURCE="$TEST_BIN/run-tests.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/runner-tests.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
export TMPDIR="$TMP"
owns_group() {
 ps -A -o pgid=,command= | awk -v g="$1" -v t="$TMP" '$1==g && index($0,t) { found=1 } END { exit !found }'
}
cleanup() {
 if [ -n "${bgpid:-}" ] && kill -0 "$bgpid" 2>/dev/null; then
  kill -INT "$bgpid" 2>/dev/null || :
  wait "$bgpid" 2>/dev/null || :
 fi
 if [ -n "${runner_probe_pid:-}" ]; then kill -TERM "$runner_probe_pid" 2>/dev/null || :; wait "$runner_probe_pid" 2>/dev/null || :; fi
 if [ -n "${gc_group:-}" ] && owns_group "$gc_group"; then kill -KILL -- "-$gc_group" 2>/dev/null || :; fi
 # These pid files belong exclusively to fixture runners created by this suite.
 shopt -s nullglob
 for pidfile in "$TMP"/run-tests.*/*.pid "$TMP"/direct.*/*.pid; do
  [ ! -e "${pidfile%.pid}.rc" ] || continue
  fixture_pgid=$(cat "$pidfile")
  owns_group "$fixture_pgid" || continue
  kill -KILL -- "-$fixture_pgid" 2>/dev/null || :
 done
 rm -rf "$TMP"
}
trap cleanup EXIT
# Internal self-test selector for focused mutation checks; default runs all groups.
group() { [ "${1}" = "${RUN_TESTS__TEST_GROUP:-$1}" ]; }
fixture() {
  ROOT="$TMP/$1"
  mkdir -p "$ROOT/bin" "$ROOT/test"
  cp "$SOURCE" "$ROOT/bin/run-tests.sh"
}
suite() { printf '%s\n' '#!/usr/bin/env bash' "$2" > "$ROOT/$1"; }
run() {
  rc=0
  bash "$ROOT/bin/run-tests.sh" "$@" > "$TMP/out" 2>&1 || rc=$?
}
check() { "$@" || { [ ! -f "$TMP/out" ] || cat "$TMP/out"; echo "FAIL: $*"; exit 1; }; }
output_order() {
 check awk -v need_tail="${1:-0}" '
 /^PASS .*\([0-9]+s\)$/ || /^FAIL .*\(/ || /^TIMEOUT / || /^KILLED / { if (stage > 0) exit 1; seen=1 }
 /^Summary: / { if (!seen || stage != 0) exit 1; stage=1 }
 /^Slowest suites:/ { if (stage != 1) exit 1; stage=2 }
 /^Log tail:/ { if (stage < 2 || stage > 3) exit 1; stage=3 }
 /^SKIP test-/ { if (stage < 2 || stage > 4 || (need_tail && stage < 3)) exit 1; stage=4 }
 /^RUN  shellcheck/ { if (stage < 2 || stage > 4) exit 1; stage=5 }
 /^Total wall:/ { if (stage < 2 || stage > 5) exit 1; stage=6 }
 /^(GATE PASS:|GATE FAIL:|PARTIAL RUN:)/ { if (stage != 6) exit 1; stage=7 }
 END { if (stage != 7) exit 1 }
 ' "$TMP/out"
}
full() {
 fixture "full-$1"
 suite bin/test-a.sh 'exit 0'; suite bin/test-b.sh 'exit 0'; suite test/stray_commit.sh 'exit 0'
 run
 check test "$rc" = 0
 output_order
 check test "$(head -1 "$TMP/out")" = "$(sed -n '/^Run dir: /p' "$TMP/out")"
 check grep -q '^Run dir: /' "$TMP/out"
 check grep -qx 'PASS test-a.sh ([0-9]*s)' "$TMP/out"
 check grep -qFx 'RUN  stray_commit.sh' "$TMP/out"
 check grep -qFx 'Summary: 3 passed, 0 failed, 3 total' "$TMP/out"
 check grep -qx 'Total wall: [0-9]*s' "$TMP/out"
 check bash -c 'tail -1 "$1" | grep -q "^GATE PASS: all 3 suites passed; shellcheck "' _ "$TMP/out"
}
failures() {
 fixture "fail-$1"
 suite bin/test-a.sh 'exit 0'; suite bin/test-b.sh 'echo MARK-B; echo SKIP x; exit 7'
 suite bin/test-c.sh 'touch "$TMPDIR/c-ran"'; suite bin/test-d.sh 'echo MARK-D; exit 3'
 run
 check test "$rc" = 1; check test -e "$TMP/c-ran"
 output_order 1
 check grep -qFx "GATE FAIL: 2 of 4 suites failed" "$TMP/out"
 check grep -q 'FAIL test-b.sh (exit 7,' "$TMP/out"
 check grep -q 'FAIL test-d.sh (exit 3,' "$TMP/out"
 check grep -q MARK-B "$TMP/out"; check grep -q MARK-D "$TMP/out"
 check test "$(grep -c '^GATE PASS' "$TMP/out")" = 0
}
zero() { fixture "zero-$1"; run; check test "$rc" = 1; check grep -q 'discovered 0 test suites' "$TMP/out"; }
make_repo() (
 set -eu
 repo=$(mktemp -d "${TMPDIR:-/tmp}/changed-repo.XXXXXX")
 [ -n "$repo" ] || exit 1
 git -C "$repo" init --bare "$repo/origin.git" >/dev/null 2>&1
 git -C "$repo" init "$repo/work" >/dev/null 2>&1
 ROOT="$repo/work/agent-dispatch"
 mkdir -p "$ROOT/bin/lib" "$ROOT/test" "$ROOT/docs" "$repo/work/other"
 cp "$SOURCE" "$ROOT/bin/run-tests.sh"
 suite bin/test-a.sh ': docs/a.md docs/new.md'
 suite bin/test-b.sh ': other/x.md'
 suite bin/test-c.sh 'exit 0'
 suite bin/tool.sh ': pre.md'
 for path in docs/a.md docs/pre.md bin/lib/h.sh README.md; do echo baseline > "$ROOT/$path"; done
 echo baseline > "$repo/work/other/x.md"
 git -C "$repo/work" add .
 git -C "$repo/work" -c user.name=Fixture -c user.email=fixture@example.com commit -qm baseline
 git -C "$repo/work" branch -M main
 git -C "$repo/work" remote add origin "$repo/origin.git"
 git -C "$repo/work" push -q -u origin main
 git -C "$repo/work" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
 git -C "$repo/work" checkout -qb feat
 printf '%s\n' "$ROOT"
)
changed_selected() {
 check test "$rc" = 4
 check test "$(grep -c '^RUN  ' "$TMP/out")" = 1
 check grep -qFx "RUN  $1" "$TMP/out"
 check test "$(grep -c shellcheck "$TMP/out")" = 0
}
changed_full() {
 check test "$rc" = 0
 check grep -qFx "FULL GATE: $1" "$TMP/out"
 check test "$(grep -c '^RUN  test-' "$TMP/out")" = "${2:-3}"
}
shim="$TMP/shim"
mkdir -p "$shim"
for command in awk mkdir cp grep ln sed bash dirname readlink mktemp find wc tr sort xargs date basename mv rm cat tail head getconf sysctl timeout gtimeout sleep touch ps; do
 target=$(command -v "$command" || :)
 [ -z "$target" ] || ln -s "$target" "$shim/$command"
done
oldpath=$PATH
start_bg() {
 set -m
 if [ -n "$PERL" ]; then
  "$PERL" -e '$SIG{INT}=$SIG{TERM}=$SIG{HUP}="DEFAULT"; exec @ARGV' "$@" > "$TMP/out" 2>&1 &
 else
  echo "SKIP signal cases: perl unavailable"; return 1
 fi
 bgpid=$!; bgpgid=$bgpid
 set +m
}
wait_bounded() {
 local pid=$1 seconds=$2 end
 end=$(( $(date +%s) + seconds ))
 while kill -0 "$pid" 2>/dev/null; do
  if [ "$(date +%s)" -ge "$end" ]; then
   if owns_group "$bgpgid"; then kill -KILL -- "-$bgpgid" 2>/dev/null || :; fi
   echo 'FAIL bounded wait'; exit 1
  fi
  sleep 0.1
 done
 rc=0; wait "$pid" || rc=$?
 bgpid=
}
await_file() {
 local end
 end=$(( $(date +%s) + 10 ))
 while [ ! -e "$1" ]; do
  check test "$(date +%s)" -lt "$end"
  sleep 0.1
 done
}
signal_case() {
 fixture "signal-$1-$2"
 rm -f "$TMP/slow.pid"
 suite bin/test-slow.sh 'echo $$ > "$TMPDIR/slow.pid"; '"${3:-sleep 60}"
 RUN_TESTS_KEEP_LOGS=1 start_bg bash "$ROOT/bin/run-tests.sh"
 await_file "$TMP/slow.pid"
 kill -"$1" "$bgpid"
 wait_bounded "$bgpid" 20
 check test "$rc" = "$2"
 check grep -q '^INTERRUPTED: ' "$TMP/out"
 check test "$(grep -c '^GATE PASS' "$TMP/out")" = 0
 check test "$(grep -c 'Terminated:.*sleep 0.1' "$TMP/out")" = 0
 rd=$(sed -n 's/^Run dir: //p' "$TMP/out")
 check test "$(find "$rd" -name '*.pid' | wc -l | tr -d ' ')" = 0
 check bash -c '! kill -0 "$1" 2>/dev/null' _ "$(cat "$TMP/slow.pid")"
}

# Nested invocations use the same explicit selector without advertising a partial
# outer suite to the aggregate gate.
nested_run() {
 local rc
 rc=0; "$@" > "$TMP/nested.out" 2>&1 || rc=$?
 cat "$TMP/nested.out"
 [ "$rc" = 0 ] || { echo "FAIL nested: $*"; exit 1; }
 if grep -q '^SKIP runner-tests: only group ' "$TMP/nested.out"; then
  echo 'FAIL nested group advertised as skipped'; exit 1
 fi
}
