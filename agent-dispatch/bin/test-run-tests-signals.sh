#!/usr/bin/env bash
. "${BASH_SOURCE[0]%/*}/lib/timeout-bin.sh"
# shellcheck disable=SC2034,SC2154
# Shared fixture setup and assertions; helper is intentionally not executable.
TEST_BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/run-tests-testlib.sh
. "$TEST_BIN/lib/run-tests-testlib.sh"
test_groups="portable accounting signals fallback direct cleanup parent wave2 straggler leak nops ownership grace inherited bash3 interrupt"
for g in $test_groups; do
 grep -q "group $g" "$0" || { echo "FAIL stale test group: $g"; exit 1; }
done
case "${RUN_TESTS__TEST_GROUP:-}" in
 *[[:space:]]*) echo "FAIL unknown test group: $RUN_TESTS__TEST_GROUP"; exit 1 ;;
esac
case " $test_groups " in
 *" ${RUN_TESTS__TEST_GROUP:-} "*) ;;
 *) if [ -n "${RUN_TESTS__TEST_GROUP:-}" ]; then echo "FAIL unknown test group: $RUN_TESTS__TEST_GROUP"; exit 1; fi ;;
esac
# Adjacent valid names used to pass the substring membership check.
if [ -z "${RUN_TESTS__TEST_GROUP:-}" ]; then
 for invalid_group in "${test_groups%% *} ${test_groups#* }" $'changed\tbasics' $'portable\naccounting'; do
  selector_rc=0
  RUN_TESTS__TEST_GROUP_EXPLICIT=1 RUN_TESTS__TEST_GROUP="$invalid_group" bash "$0" > "$TMP/selector-out" 2>&1 || selector_rc=$?
  [ "$selector_rc" = 1 ] && grep -qFx "FAIL unknown test group: $invalid_group" "$TMP/selector-out" || { echo 'FAIL whitespace test group accepted'; exit 1; }
 done
fi
if group portable; then
fixture no-shellcheck; suite bin/test-a.sh 'exit 0'
export PATH="$shim"
run
export PATH="$oldpath"
check test "$rc" = 0
check bash -c 'tail -1 "$1" | grep -qx "GATE PASS: all 1 suites passed; shellcheck skipped (not installed)"' _ "$TMP/out"
check grep -qFx 'run-tests.sh: NOTICE: shellcheck not found; skipping shellcheck --severity=warning' "$TMP/out"
fixture lifted-skip
suite bin/test-a.sh 'printf "SKIP optional tool"'
run
check grep -qFx 'SKIP test-a.sh: SKIP optional tool' "$TMP/out"
output_order
fixture ci-log
suite bin/test-a.sh 'echo FIRST-LOG-LINE; for n in {1..25}; do echo filler; done; exit 1'
export CI=true
run
unset CI
check test "$rc" = 1
check grep -qFx FIRST-LOG-LINE "$TMP/out"
# A timeout shim records the public default and creates the sentinel in the
# post-launch window without scheduler-dependent sleeps.
real_timeout=$(dispatch_timeout_bin) || { echo "FAIL: no usable timer" >&2; exit 1; }
real_timeout=$(command -v "$real_timeout") || exit 1
 probe="$TMP/timeout-probe"; mkdir "$probe"
 printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$TMPDIR/timeout-args"\nexec "%s" "$@"\n' "$real_timeout" > "$probe/timeout"
 chmod +x "$probe/timeout"
 fixture default-limit; suite bin/test-a.sh 'exit 0'
 (unset RUN_TESTS__TEST_KILL_GRACE; PATH="$probe:$oldpath" run)
 check grep -q '^-k 15 420 ' "$TMP/timeout-args"
 PATH="$probe:$oldpath" run
 check grep -q '^-k 2 420 ' "$TMP/timeout-args"
 fixture sentinel-window
 suite bin/test-x.sh 'echo $$ > "$TMPDIR/window.pid"; sleep 60'
 rd=$(mktemp -d "$TMP/window.XXXXXX")
 printf '#!/usr/bin/env bash\ntouch "%s/INTERRUPTED"\nexec "%s" "$@"\n' "$rd" "$real_timeout" > "$probe/timeout"
 window_started=$SECONDS
 PATH="$probe:$oldpath" bash -c 'bash "$1/bin/run-tests.sh" --_run-one bin/test-x.sh "$2" 10 "$3" & wait' _ "$ROOT" "$rd" "$$" > "$TMP/out" 2>&1
 check test "$((SECONDS - window_started))" -lt 5
 check test "$(cat "$rd/bin__test-x.sh.rc")" = not-run
 check test ! -e "$rd/bin__test-x.sh.pid"
 if [ -e "$TMP/window.pid" ]; then check bash -c '! kill -0 "$1" 2>/dev/null' _ "$(cat "$TMP/window.pid")"; fi
if /bin/bash --version | grep -q 'version 3\.'; then
 bash3shim="$TMP/portable-bash3-shim"; mkdir -p "$bash3shim"
 ln -s /bin/bash "$bash3shim/bash"
 export PATH="$bash3shim:$shim:$oldpath"
 full bash3; failures bash3; zero bash3
 export PATH="$oldpath"
else echo 'SKIP bash 3.2'; fi
fi
if group accounting && [ -n "$PERL" ]; then
fixture empty-interrupted
suite bin/test-a.sh 'exit 0'
suite bin/test-b.sh 'for result in "$TMPDIR"/run-tests.*/bin__test-a.sh.rc; do : > "$result"; done; touch "$TMPDIR/empty-ready"; sleep 60'
start_bg bash "$ROOT/bin/run-tests.sh" -j 1
await_file "$TMP/empty-ready"
kill -INT "$bgpid"; wait_bounded "$bgpid" 20
check test "$rc" = 130
check grep -qFx 'FAIL test-a.sh (no result)' "$TMP/out"
check grep -qFx 'NOT RUN test-b.sh' "$TMP/out"
check grep -qFx 'Summary: 0 passed, 1 failed, 2 total' "$TMP/out"
check grep -qFx 'INTERRUPTED: 1 finished, 1 not run' "$TMP/out"
fi
if group signals && [ -n "$PERL" ]; then
signal_case INT 130
signal_case TERM 143
signal_case HUP 129
fixture grandchild
suite bin/test-gc.sh "bash -c 'trap \"\" TERM; echo \$\$ > \"\$TMPDIR/gc.pid\"; sleep 60' & sleep 60"
start_bg bash "$ROOT/bin/run-tests.sh"
await_file "$TMP/gc.pid"
gc_rundir=$(sed -n 's/^Run dir: //p' "$TMP/out")
await_file "$gc_rundir/bin__test-gc.sh.pid"
gc_group=$(cat "$gc_rundir/bin__test-gc.sh.pid")
kill -INT "$bgpid"
wait_bounded "$bgpid" 25
check test "$rc" = 130
check bash -c '! kill -0 "$1" 2>/dev/null' _ "$(cat "$TMP/gc.pid")"
gc_group=
fixture hang
suite bin/test-hang.sh 'trap "" TERM; sleep 60'
began=$SECONDS
start_bg bash "$ROOT/bin/run-tests.sh" --timeout 2
wait_bounded "$bgpid" 25
check test "$rc" = 1
check test "$((SECONDS - began))" -lt 10
check grep -qE '^KILLED test-hang.sh \(' "$TMP/out"
fi
if { group signals || group fallback; } && [ -n "$PERL" ]; then
# A selected fallback group has no fixture from preceding groups.
fixture fallback-setup
base_shim=$shim
shim="$TMP/shim-${ROOT##*/}-${SECONDS}"
cp -R "$base_shim" "$shim"
rm -f "$shim/timeout" "$shim/gtimeout"
export PATH="$shim"
signal_case INT 130
check grep -q 'NOTICE: no timeout/gtimeout found' "$TMP/out"
fixture fallback-hang
export RUN_TESTS__TEST_NOGROUP=1
suite bin/test-hang.sh 'echo $$ > "$TMPDIR/nogroup.pid"; trap "" TERM; exec sleep 60'
began=$SECONDS
start_bg bash "$ROOT/bin/run-tests.sh" --timeout 2
wait_bounded "$bgpid" 25
check test "$rc" = 1
check test "$((SECONDS - began))" -lt 10
check grep -qE '^KILLED test-hang.sh \(' "$TMP/out"
check bash -c '! kill -0 "$1" 2>/dev/null' _ "$(cat "$TMP/nogroup.pid")"
unset RUN_TESTS__TEST_NOGROUP
fixture fallback-grandchild
rm -f "$TMP/gc.pid"
suite bin/test-gc.sh "bash -c 'trap \"\" TERM; echo \$\$ > \"\$TMPDIR/gc.pid\"; sleep 60' & sleep 60"
start_bg bash "$ROOT/bin/run-tests.sh"
await_file "$TMP/gc.pid"
gc_rundir=$(sed -n 's/^Run dir: //p' "$TMP/out")
await_file "$gc_rundir/bin__test-gc.sh.pid"
gc_group=$(cat "$gc_rundir/bin__test-gc.sh.pid")
kill -INT "$bgpid"; wait_bounded "$bgpid" 25
check test "$rc" = 130
check bash -c '! kill -0 "$1" 2>/dev/null' _ "$(cat "$TMP/gc.pid")"
gc_group=
full no-timeout
check grep -q 'NOTICE: no timeout/gtimeout found' "$TMP/out"
export PATH="$oldpath"
shim=$base_shim
fi
if group signals && [ -n "$PERL" ]; then
fixture interrupt-stops-further-launches
for n in 1 2 3 4 5; do
 suite "bin/test-$n.sh" "touch \"\$TMPDIR/started-$n\"; sleep 1"
done
start_bg bash "$ROOT/bin/run-tests.sh" -j 1
await_file "$TMP/started-1"
kill -INT "$bgpid"
wait_bounded "$bgpid" 20
check test "$rc" = 130
for n in 3 4 5; do check test ! -e "$TMP/started-$n"; done
check grep -Eq '^INTERRUPTED: [0-9]+ finished, [3-5] not run$' "$TMP/out"
fi
if group direct; then
fixture pre-sentinel
suite bin/test-x.sh 'touch "$TMPDIR/never-started"'
rd=$(mktemp -d "$TMP/direct.XXXXXX")
touch "$rd/INTERRUPTED"
bash -c 'bash "$1/bin/run-tests.sh" --_run-one bin/test-x.sh "$2" 10 "$3" & wait' _ "$ROOT" "$rd" "$$" > "$TMP/out" 2>&1
check test "$(cat "$rd/bin__test-x.sh.rc")" = not-run
check test ! -e "$TMP/never-started"
check test "$(grep -c '^RUN  ' "$TMP/out")" = 0
rd=$(mktemp -d "$TMP/dead.XXXXXX")
# A reaped child supplies a known dead pid.
sleep 0 & dead=$!; wait "$dead"
RUN_TESTS__PS_AVAILABLE=0 bash -c 'bash "$1/bin/run-tests.sh" --_run-one bin/test-x.sh "$2" 10 "$3" & wait' _ "$ROOT" "$rd" "$dead" > "$TMP/out" 2>&1
check test "$(cat "$rd/bin__test-x.sh.rc")" = not-run
check test ! -e "$TMP/never-started"
check test "$(grep -c '^RUN  ' "$TMP/out")" = 0
fixture dead-midflight
suite bin/test-x.sh 'echo $$ > "$TMPDIR/midflight.pid"; sleep 60'
rd=$(mktemp -d "$TMP/direct.XXXXXX")
# The probe is a real runner parent, with an intermediate xargs-shaped parent.
cat > "$TMP/probe.sh" <<'PROBE'
bash -c 'bash "$1/bin/run-tests.sh" --_run-one bin/test-x.sh "$2" 60 "$3" & wait' _ "$1" "$2" "$$" &
wait
PROBE
RUN_TESTS__PS_AVAILABLE=0 bash "$TMP/probe.sh" "$ROOT" "$rd" > "$TMP/out" 2>&1 & runner_probe_pid=$!
bgpid=$runner_probe_pid
await_file "$rd/bin__test-x.sh.pid"
await_file "$TMP/midflight.pid"
kill -KILL "$runner_probe_pid"; wait "$runner_probe_pid" 2>/dev/null || :; runner_probe_pid=
bgpid=
await_file "$rd/bin__test-x.sh.rc"
check test "$(cat "$rd/bin__test-x.sh.rc")" = not-run
check bash -c '! kill -0 "$1" 2>/dev/null' _ "$(cat "$TMP/midflight.pid")"

fi
if group cleanup && [ -n "$PERL" ]; then
export RUN_TESTS__TEST_KILL_GRACE=5
fixture cleanup-trap
base_shim=$shim
shim="$TMP/shim-${ROOT##*/}-${SECONDS}"
cp -R "$base_shim" "$shim"
rm -f "$shim/timeout" "$shim/gtimeout"
export PATH="$shim"
suite bin/test-clean.sh "trap 'sleep 1; echo cleaned > \"\$TMPDIR/cleaned\"; exit 143' TERM; touch \"\$TMPDIR/clean-ready\"; sleep 60"
suite bin/test-clean-once.sh "trap 'sleep 1 && echo cleaned > \"\$TMPDIR/cleaned-once\"; exit 143' TERM; touch \"\$TMPDIR/clean-once-ready\"; sleep 60"
suite bin/test-count.sh "trap 'echo term >> \"\$TMPDIR/term-count\"; sleep 1' TERM; touch \"\$TMPDIR/count-ready\"; while :; do sleep 60; done"
start_bg bash "$ROOT/bin/run-tests.sh"
await_file "$TMP/count-ready"
await_file "$TMP/clean-once-ready"
await_file "$TMP/clean-ready"
sleep 1
kill -INT "$bgpid"; wait_bounded "$bgpid" 20
check test "$(wc -l < "$TMP/term-count" | tr -d ' ')" = 1
check test -e "$TMP/cleaned"
check test -e "$TMP/cleaned-once"
export PATH="$oldpath"
shim=$base_shim
export RUN_TESTS__TEST_KILL_GRACE=2
fi
if group parent && [ -n "$PERL" ]; then
fixture killed-parent
for n in 1 2 3 4; do suite "bin/test-$n.sh" "touch \"\$TMPDIR/kstarted-$n\"; sleep 2"; done
start_bg bash "$ROOT/bin/run-tests.sh" -j 1
await_file "$TMP/kstarted-1"
kill -KILL "$bgpid"; wait "$bgpid" 2>/dev/null || :; bgpid=
sleep 8
check test ! -e "$TMP/kstarted-3"; check test ! -e "$TMP/kstarted-4"
fi


if group wave2; then
fixture own-exit
suite bin/test-own.sh 'exit 124'
run
check test "$rc" = 1
check grep -q 'FAIL test-own.sh (exit 124,' "$TMP/out"
suite bin/test-own.sh 'exit 137'
run
check grep -q 'FAIL test-own.sh (exit 137,' "$TMP/out"
fixture leaked
suite bin/test-leak.sh 'echo LEAK-LOG; sleep 40 & echo $! > "$TMPDIR/leak.pid"; exit 0'
began=$SECONDS
run --timeout 30
check test "$rc" = 1
check test "$((SECONDS - began))" -lt 20
check test "$(grep -cFx 'FAIL test-leak.sh (exited 0; left processes running)' "$TMP/out")" = 2
check grep -qFx 'Log tail: test-leak.sh' "$TMP/out"
check grep -qFx LEAK-LOG "$TMP/out"
# The runner names each survivor (pid, elapsed time, command) before killing it.
check grep -qE "^LEAK test-leak\.sh: pid $(cat "$TMP/leak.pid"), elapsed [0-9:-]+: sleep 40\$" "$TMP/out"
check bash -c '! kill -0 "$1" 2>/dev/null' _ "$(cat "$TMP/leak.pid")"
fixture timeout-respecting
suite bin/test-hang.sh 'sleep 60'
run --timeout 2
check test "$rc" = 1
check grep -q '^TIMEOUT test-hang.sh (' "$TMP/out"
fixture bad-base
ROOT=$(make_repo)
run --changed nonexistent-ref
check test "$rc" = 2
check grep -qFx 'run-tests.sh: unknown base: nonexistent-ref' "$TMP/out"
fixture invalid-values
suite bin/test-ok.sh 'exit 0'
for label in RUN_TESTS_JOBS RUN_TESTS_TIMEOUT -j --timeout; do
 case "$label" in
 RUN_TESTS_JOBS) RUN_TESTS_JOBS=x run ;;
 RUN_TESTS_TIMEOUT) RUN_TESTS_TIMEOUT=x run ;;
 *) run "$label" x ;;
 esac
 check test "$rc" = 2
 check grep -qFx "run-tests.sh: $label: expected a positive integer: x" "$TMP/out"
done
fixture identity
suite bin/test-x.sh 'touch "$TMPDIR/identity-started"'
rd=$(mktemp -d "$TMP/direct.XXXXXX")
bash "$ROOT/bin/run-tests.sh" --_run-one bin/test-x.sh "$rd" 10 $$ > "$TMP/out" 2>&1
check test "$(cat "$rd/bin__test-x.sh.rc")" = not-run
check test ! -e "$TMP/identity-started"
fi

if group straggler; then
fixture straggler
for delay in 0.3 1.3; do
 suite bin/test-short.sh "( sleep $delay ) & exit 0"
 run
 check test "$rc" = 0
done
fi
if group leak; then
fixture stubborn-leak
suite bin/test-leak.sh '( trap "" TERM; exec sleep 40 ) & echo $! > "$TMPDIR/stubborn.pid"; exit 0'
began=$SECONDS
RUN_TESTS__TEST_KILL_GRACE=30 RUN_TESTS_KEEP_LOGS=1 run --timeout 30
check test "$rc" = 1
check test "$((SECONDS - began))" -lt 15
check grep -q 'left processes running)' "$TMP/out"
check bash -c '! kill -0 "$1" 2>/dev/null' _ "$(cat "$TMP/stubborn.pid")"
rd=$(sed -n 's/^Run dir: //p' "$TMP/out")
check test "$(cat "$rd/bin__test-leak.sh.rc")" = leaked
# The result alone must fail closed, even when the diagnostic sidecar is lost.
fixture leaked-sidecar
suite bin/test-orphan.sh '( trap "" TERM; exec sleep 40 ) & exit 0'
suite bin/test-sidecar.sh 'while :; do for result in "$TMPDIR"/run-tests.*/bin__test-orphan.sh.rc; do if [ -f "$result" ]; then rm -f "${result%.rc}.why"; exit 0; fi; done; sleep 0.1; done'
run --timeout 30
check test "$rc" = 1
check test "$(grep -c 'left processes running)' "$TMP/out")" = 2
fi
if group nops; then
fixture no-ps
suite bin/test-a.sh 'exit 0'
rm "$shim/ps"
PATH="$shim" run
check test "$rc" = 0
check grep -qFx 'run-tests.sh: NOTICE: ps not found; runner identity check disabled (liveness only)' "$TMP/out"
# Simulate an outer runner exporting its cached ps availability. The nested
# top-level runner must probe the shim PATH instead of trusting that cache.
RUN_TESTS__PS_AVAILABLE=1 PATH="$shim" run
check test "$rc" = 0
if ! grep -qFx 'run-tests.sh: NOTICE: ps not found; runner identity check disabled (liveness only)' "$TMP/out"; then
 cat "$TMP/out"
 echo 'FAIL: inherited ps cache suppressed no-ps NOTICE'
 exit 1
fi
suite bin/test-leak.sh 'echo LEAK-LOG; sleep 40 & echo $! > "$TMPDIR/leak.pid"; exit 0'
PATH="$shim" run
check test "$rc" = 1
check grep -qF 'LEAK test-leak.sh: ps not found' "$TMP/out"
printf '#!/usr/bin/env bash\nexit 1\n' > "$shim/ps"
chmod +x "$shim/ps"
PATH="$shim" run
check test "$rc" = 1
check grep -qFx 'LEAK test-leak.sh: survivors could not be listed' "$TMP/out"
rm "$shim/ps"
ln -s "$(command -v ps)" "$shim/ps"
fi
if group ownership; then
fixture ownership
suite bin/test-live.sh 'touch "$TMPDIR/ownership-ready"; sleep 60'
set -m
(cd -P "$ROOT" || exit; exec bash "$PWD/bin/test-live.sh") & owned=$!
sleep 60 & foreign=$!
set +m
await_file "$TMP/ownership-ready"
owned_ok=0; foreign_ok=0
owns_group "$owned" && owned_ok=1
owns_group "$foreign" && foreign_ok=1
kill -TERM -- "-$owned" "-$foreign"
wait "$owned" 2>/dev/null || :; wait "$foreign" 2>/dev/null || :
check test "$owned_ok" = 1
check test "$foreign_ok" = 0
fi
if group grace; then
fixture grace
suite bin/test-a.sh 'exit 0'
for value in 0 x; do
 RUN_TESTS__TEST_KILL_GRACE=$value run
 check test "$rc" = 2
done
fi

if group inherited && [ -n "$PERL" ]; then
 for selected_group in signals fallback; do
  nested_run bash -c 'trap "" INT HUP; exec env RUN_TESTS__TEST_NESTED=1 RUN_TESTS__TEST_GROUP_EXPLICIT=1 RUN_TESTS__TEST_GROUP="$1" bash "$2"' _ "$selected_group" "$0"
 done
fi
if group bash3; then
 if [ -n "$PERL" ] && /bin/bash --version | grep -q 'version 3\.'; then
  bash3shim="$TMP/bash3-shim"; mkdir -p "$bash3shim"
 ln -s /bin/bash "$bash3shim/bash"
  PATH="$bash3shim:$shim:$oldpath" signal_case INT 130
  RUN_TESTS__TEST_NESTED=1 RUN_TESTS__TEST_GROUP_EXPLICIT=1 RUN_TESTS__TEST_GROUP=wave2 PATH="$bash3shim:$shim:$oldpath" nested_run /bin/bash "$0"
  RUN_TESTS__TEST_NESTED=1 RUN_TESTS__TEST_GROUP_EXPLICIT=1 RUN_TESTS__TEST_GROUP=direct PATH="$bash3shim:$shim:$oldpath" nested_run /bin/bash "$0"
 else echo 'SKIP bash 3.2 signal and liveness'; fi
fi
if [ -z "$PERL" ]; then echo 'SKIP signal cases: perl unavailable'; fi
if group interrupt && [ -n "$PERL" ]; then
 began=$SECONDS
 RUN_TESTS__TEST_KILL_GRACE=30 signal_case INT 130 'trap "" TERM; exec sleep 60'
 check test "$((SECONDS - began))" -lt 15
fi
if [ -n "${RUN_TESTS__TEST_GROUP:-}" ] && [ "${RUN_TESTS__TEST_NESTED:-}" != 1 ]; then echo "SKIP runner-tests: only group $RUN_TESTS__TEST_GROUP ran"; fi
echo 'PASS runner signals tests'
