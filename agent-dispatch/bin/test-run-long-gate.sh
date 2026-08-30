#!/usr/bin/env bash
set -uo pipefail

# Find the scripts dir
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run-long-gate.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Cleanup function
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Test 1: Successful gate -> --wait exits 0; log ends GATE_EXIT=0
echo "Running Test 1..."
LOG1="$TMP_DIR/test1.log"
"$RUNNER" --cmd "echo hello && sleep 0.5" --log "$LOG1"
"$RUNNER" --wait --log "$LOG1" --timeout-secs 10 --poll-secs 1 || fail "Test 1 wait failed"
grep -q "GATE_EXIT=0" "$LOG1" || fail "Test 1 exit code not in log"
echo "Test 1 PASS"

# Test 2: Failing gate exits 7 -> --wait exits 7
echo "Running Test 2..."
LOG2="$TMP_DIR/test2.log"
"$RUNNER" --cmd "sleep 0.5 && exit 7" --log "$LOG2"
set +e
"$RUNNER" --wait --log "$LOG2" --timeout-secs 10 --poll-secs 1
RC=$?
set -e
[ "$RC" -eq 7 ] || fail "Test 2 wait exited with $RC instead of 7"
grep -q "GATE_EXIT=7" "$LOG2" || fail "Test 2 exit code not in log"
echo "Test 2 PASS"

# Test 3: --status while running (exit 3) and after completion (exit 0)
echo "Running Test 3..."
LOG3="$TMP_DIR/test3.log"
"$RUNNER" --cmd "sleep 1.5" --log "$LOG3"
# Immediate status check should be 3
set +e
"$RUNNER" --status --log "$LOG3"
RC=$?
set -e
[ "$RC" -eq 3 ] || fail "Test 3 status check on running gate got $RC instead of 3"

# Wait for completion
sleep 2
set +e
STATUS_OUT=$("$RUNNER" --status --log "$LOG3")
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "Test 3 status check on completed gate got $RC instead of 0"
[ "$STATUS_OUT" = "GATE_EXIT=0" ] || fail "Test 3 status output was '$STATUS_OUT' instead of 'GATE_EXIT=0'"
echo "Test 3 PASS"

# Test 4: --status on missing log -> exit 2
echo "Running Test 4..."
set +e
"$RUNNER" --status --log "$TMP_DIR/missing.log"
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "Test 4 status check on missing log got $RC instead of 2"
echo "Test 4 PASS"

# Test 5: The survival case: launch the gate from a subshell that then EXITS, and assert the gate still completes and writes GATE_EXIT
echo "Running Test 5..."
LOG5="$TMP_DIR/test5.log"
(
  # Spawn run-long-gate.sh and immediately exit this subshell
  "$RUNNER" --cmd "sleep 2 && exit 42" --log "$LOG5"
)
# The subshell above has exited. Give it a moment to run and complete
sleep 3.5
set +e
"$RUNNER" --status --log "$LOG5"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "Test 5 gate did not complete after parent shell exited (status RC: $RC)"
grep -q "GATE_EXIT=42" "$LOG5" || fail "Test 5 did not write correct GATE_EXIT=42"
echo "Test 5 PASS"

# Test 6: --wait --timeout-secs 1 against a longer gate -> exit 124, gate still running (not killed)
echo "Running Test 6..."
LOG6="$TMP_DIR/test6.log"
# Spawn a 4-second sleep command
launch_out=$("$RUNNER" --cmd "sleep 4 && echo 'done'" --log "$LOG6")
pid=$(echo "$launch_out" | grep '^PID=' | cut -d= -f2)

set +e
"$RUNNER" --wait --log "$LOG6" --timeout-secs 1 --poll-secs 1
RC=$?
set -e
[ "$RC" -eq 124 ] || fail "Test 6 wait did not timeout with 124 (got $RC)"

# Check if process is still running
kill -0 "$pid" 2>/dev/null || fail "Test 6 gate process was killed on timeout"

# Wait for it to finish and clean up
sleep 4
kill -0 "$pid" 2>/dev/null && fail "Test 6 process did not finish eventually"
echo "Test 6 PASS"

# Test 7: Launch mode returns immediately
# NOTE: this test leaves a 3s gate running, so it gets its own --workdir. Since the
# rule-6 concurrency guard is scoped per-workdir, sharing the default workdir with
# Test 8 (which launches immediately after) would be a real conflict, not a test bug.
echo "Running Test 7..."
LOG7="$TMP_DIR/test7.log"
WD7="$TMP_DIR/wd7"; mkdir -p "$WD7"
start_time=$(date +%s)
"$RUNNER" --cmd "sleep 3" --log "$LOG7" --workdir "$WD7"
end_time=$(date +%s)
elapsed=$((end_time - start_time))
[ "$elapsed" -lt 2 ] || fail "Test 7 launch took $elapsed seconds, did not return immediately"
echo "Test 7 PASS"

# Test 8: Stdin is not consumed from the caller
echo "Running Test 8..."
LOG8="$TMP_DIR/test8.log"
WD8="$TMP_DIR/wd8"; mkdir -p "$WD8"
echo "input_sentinel" | "$RUNNER" --cmd "sleep 0.5" --log "$LOG8" --workdir "$WD8"
# If it tried to read from stdin, it might block or get EOF.
# Proving stdin is not consumed: the command runs and exits
"$RUNNER" --wait --log "$LOG8" --timeout-secs 5 --poll-secs 1
echo "Test 8 PASS"

# --- same-workdir concurrency guard ---

# Test 9: a second launch for the SAME workdir while a gate is live is refused (exit 4)
# and never starts a process. This is the load-bearing case: mutating away the guard in
# run-long-gate.sh makes this test fail.
echo "Running Test 9..."
WD9="$TMP_DIR/wd9"; mkdir -p "$WD9"
LOG9A="$TMP_DIR/test9a.log"
LOG9B="$TMP_DIR/test9b.log"
"$RUNNER" --cmd "sleep 4" --log "$LOG9A" --workdir "$WD9" > /dev/null
set +e
GUARD_OUT=$("$RUNNER" --cmd "echo second_gate_ran" --log "$LOG9B" --workdir "$WD9" 2>&1)
RC=$?
set -e
[ "$RC" -eq 4 ] || fail "Test 9 second launch got $RC instead of 4; output: $GUARD_OUT"
echo "$GUARD_OUT" | grep -q "already running" \
  || fail "Test 9 refusal did not name the conflict: $GUARD_OUT"
echo "$GUARD_OUT" | grep -q "$LOG9A" \
  || fail "Test 9 refusal did not name the conflicting log $LOG9A: $GUARD_OUT"
# The blocked gate must not have run at all -- a refusal that still launches is not a guard.
if [ -f "$LOG9B" ] && grep -q "second_gate_ran" "$LOG9B"; then
  fail "Test 9 blocked gate actually executed"
fi
echo "Test 9 PASS"

# Test 10: a gate in a DIFFERENT workdir is NOT blocked while the Test 9 gate is live.
# Non-regression: the guard must not become a global mutex across unrelated repos.
echo "Running Test 10..."
WD10="$TMP_DIR/wd10"; mkdir -p "$WD10"
LOG10="$TMP_DIR/test10.log"
"$RUNNER" --cmd "echo other_repo_gate" --log "$LOG10" --workdir "$WD10" > /dev/null \
  || fail "Test 10 gate in a different workdir was blocked"
"$RUNNER" --wait --log "$LOG10" --timeout-secs 10 --poll-secs 1 \
  || fail "Test 10 gate in a different workdir did not complete"
grep -q "other_repo_gate" "$LOG10" || fail "Test 10 gate did not actually run"
echo "Test 10 PASS"

# Test 11: --allow-concurrent overrides the guard (deliberate parallel run stays possible)
echo "Running Test 11..."
LOG11="$TMP_DIR/test11.log"
"$RUNNER" --cmd "echo override_ran" --log "$LOG11" --workdir "$WD9" --allow-concurrent > /dev/null \
  || fail "Test 11 --allow-concurrent was still blocked"
"$RUNNER" --wait --log "$LOG11" --timeout-secs 10 --poll-secs 1 \
  || fail "Test 11 overridden gate did not complete"
grep -q "override_ran" "$LOG11" || fail "Test 11 overridden gate did not run"
echo "Test 11 PASS"

# Test 12: a lock left behind by a DEAD holder is stale, not a conflict -- a killed gate
# must not wedge the launcher forever ("killed runs leave state", rule 5).
echo "Running Test 12..."
WD12="$TMP_DIR/wd12"; mkdir -p "$WD12"
LOG12="$TMP_DIR/test12.log"
WD12_REAL="$(cd "$WD12" && pwd -P)"
LOCK12="${TMPDIR:-/tmp}/run-long-gate-$(printf '%s' "$WD12_REAL" | cksum | awk '{print $1 "-" $2}').lock"
# Find a pid that is certainly not alive: spawn, reap, then reuse its number.
sh -c 'exit 0' & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
kill -0 "$dead_pid" 2>/dev/null && fail "Test 12 could not obtain a dead pid"
printf 'PID=%s\nLOG_PATH=/tmp/stale.log\nWORKDIR=%s\n' "$dead_pid" "$WD12_REAL" > "$LOCK12"
"$RUNNER" --cmd "echo stale_reclaimed" --log "$LOG12" --workdir "$WD12" > /dev/null \
  || fail "Test 12 stale lock blocked a new gate"
"$RUNNER" --wait --log "$LOG12" --timeout-secs 10 --poll-secs 1 \
  || fail "Test 12 gate did not complete after reclaiming a stale lock"
grep -q "stale_reclaimed" "$LOG12" || fail "Test 12 gate did not run"
echo "Test 12 PASS"

# Test 13: the lock is RELEASED when the gate finishes, so a serial re-run is not blocked.
echo "Running Test 13..."
WD13="$TMP_DIR/wd13"; mkdir -p "$WD13"
LOG13A="$TMP_DIR/test13a.log"
LOG13B="$TMP_DIR/test13b.log"
"$RUNNER" --cmd "echo first" --log "$LOG13A" --workdir "$WD13" > /dev/null
"$RUNNER" --wait --log "$LOG13A" --timeout-secs 10 --poll-secs 1 || fail "Test 13 first gate failed"
sleep 0.5
"$RUNNER" --cmd "echo second" --log "$LOG13B" --workdir "$WD13" > /dev/null \
  || fail "Test 13 serial re-run was blocked -- the lock was not released"
"$RUNNER" --wait --log "$LOG13B" --timeout-secs 10 --poll-secs 1 || fail "Test 13 second gate failed"
grep -q "second" "$LOG13B" || fail "Test 13 second gate did not run"
echo "Test 13 PASS"


# Test 14: with no --log, the default log is created under $TMPDIR (not a fixed, predictable
# /tmp path), is private (0600), and is unique per launch instead of appended to forever.
echo "Running Test 14..."
WD14="$TMP_DIR/wd14"; mkdir -p "$WD14"
export TMPDIR="$TMP_DIR/tmpdir14"; mkdir -p "$TMPDIR"
OUT14A=$("$RUNNER" --cmd "echo default_log_a" --workdir "$WD14")
LOG14A="${OUT14A#*LOG_PATH=}"; LOG14A="${LOG14A%%$'\n'*}"
[ -n "$LOG14A" ] || fail "Test 14 launcher did not print LOG_PATH"
case "$LOG14A" in "$TMPDIR"/*) ;; *) fail "Test 14 default log is not under \$TMPDIR: $LOG14A";; esac
case "$LOG14A" in */*-gate.log) fail "Test 14 default log is still the predictable fixed name: $LOG14A";; esac
perms=$(ls -l "$LOG14A" | cut -c2-10)
[ "$perms" = "rw-------" ] || fail "Test 14 default log is not 0600, got $perms ($LOG14A)"
"$RUNNER" --wait --log "$LOG14A" --timeout-secs 10 --poll-secs 1 || fail "Test 14 default-log gate did not complete"
grep -q "default_log_a" "$LOG14A" || fail "Test 14 default-log gate did not run"
OUT14B=$("$RUNNER" --cmd "echo default_log_b" --workdir "$WD14")
LOG14B="${OUT14B#*LOG_PATH=}"; LOG14B="${LOG14B%%$'\n'*}"
[ "$LOG14A" != "$LOG14B" ] || fail "Test 14 a second launch reused the same default log path (append-forever)"
"$RUNNER" --wait --log "$LOG14B" --timeout-secs 10 --poll-secs 1 || fail "Test 14 second default-log gate did not complete"
grep -q "default_log_a" "$LOG14B" && fail "Test 14 second default log inherited the first run's output"
unset TMPDIR
echo "Test 14 PASS"

# Test 15: --log pointing at a SYMLINK is refused (exit 2) and nothing is written through it.
echo "Running Test 15..."
WD15="$TMP_DIR/wd15"; mkdir -p "$WD15"
TARGET15="$TMP_DIR/test15-target.txt"; : > "$TARGET15"
LINK15="$TMP_DIR/test15-link.log"; ln -s "$TARGET15" "$LINK15"
set +e
OUT15=$("$RUNNER" --cmd "echo through_the_symlink" --log "$LINK15" --workdir "$WD15" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "Test 15 symlink --log should exit 2, got $rc ($OUT15)"
case "$OUT15" in *symlink*) ;; *) fail "Test 15 refusal did not mention the symlink: $OUT15";; esac
sleep 0.5
[ ! -s "$TARGET15" ] || fail "Test 15 wrote through the symlink to $TARGET15: $(cat "$TARGET15")"
echo "Test 15 PASS"

echo "ALL TESTS PASSED SUCCESSFULLY"
