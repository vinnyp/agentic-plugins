#!/usr/bin/env bash
# Slow mutation-verify regressions: signals, clock ticks, and real toolchains.
# shellcheck source=lib/portable-stat.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/portable-stat.sh"
set -uo pipefail
unset MUTATION_VERIFY_COPY_ROOT MUTATION_VERIFY_FILE MUTATION_VERIFY_SWEEP_JOBS
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
MV="$SELF_DIR/mutation-verify.sh"
PERL=$(command -v perl || :)
fail() { echo "FAIL: $1"; exit 1; }

# ---------------------------------------------------------------------------
# Test 13 (BLOCKER 3 regression): a SIGINT delivered while --test-cmd is
# running must exit with a signal-derived status (NOT 0 — a bare `trap
# cleanup EXIT INT TERM` lets bash resume past the trap, so an interrupted
# test's non-zero test_rc gets misreported as a mutation-CAUGHT success),
# and must restore the file. This also guards a real regression found while
# fixing BLOCKER 3: cleanup() firing TWICE (once explicitly from the INT
# handler, once again via the EXIT trap when the re-raised signal actually
# terminates the process) — the second call found the snapshot dir already
# removed by the first and printed a spurious "RESTORE FAILED" for a run
# that had actually succeeded. cleanup() must be idempotent, and its
# stderr must NOT claim failure when the restore genuinely succeeded.
# ---------------------------------------------------------------------------
if [ -n "$PERL" ]; then
F13="$TMP/sigint_target.txt"
printf 'hello world\n' > "$F13"
before13="$(cat "$F13")"
cat > "$TMP/slow_test.sh" <<'EOF'
#!/usr/bin/env bash
: > "$MUTATION_VERIFY_TEST_READY"
sleep 10
EOF
chmod +x "$TMP/slow_test.sh"
# `set -m` (job control) is required here: without it, a non-interactive
# script's ASYNC commands have SIGINT/SIGQUIT set to ignored by bash itself
# before mutation-verify.sh even starts, and a shell may not trap a signal
# that was already ignored on entry — so `kill -INT` on the background job
# would silently do nothing and this test would just run to completion.
set -m
# Reset inherited ignored SIGINT before starting the shell.
MUTATION_VERIFY_TEST_READY="$TMP/int-ready" "$PERL" -e '$SIG{INT}=$SIG{TERM}=$SIG{HUP}="DEFAULT"; exec @ARGV' bash "$MV" --file "$F13" --test-cmd "$TMP/slow_test.sh" --mutate-sed 's/hello/goodbye/' >"$TMP/out13" 2>&1 &
sig_pid=$!
ready_deadline=$((SECONDS+15))
while [ ! -f "$TMP/int-ready" ]; do
  [ "$SECONDS" -lt "$ready_deadline" ] || fail 'in-place INT test did not become ready'
  sleep 0.1
done
kill -s INT "$sig_pid"
wait "$sig_pid"
rc=$?
set +m
[ "$rc" -eq 130 ] || { cat "$TMP/out13"; fail "SIGINT: expected exit 130 (signal-derived), got $rc"; }
[ "$(cat "$F13")" = "$before13" ] || fail "SIGINT: file not restored/byte-identical after interrupt"
grep -qi "restore failed" "$TMP/out13" && { cat "$TMP/out13"; fail "SIGINT: spurious RESTORE FAILED message for a run that actually succeeded (cleanup() ran twice)"; }
echo "test SIGINT during test-cmd -> signal-derived exit, file restored, no spurious failure PASS"


# Copy cleanup has its own signal trap and must remove every phase copy.
mkdir -p "$TMP/int-root" "$TMP/int-tmp"
printf 'hello\n' > "$TMP/int-root/subject"
set -m
(cd "$TMP/int-root" && TMPDIR="$TMP/int-tmp" exec "$PERL" -e '$SIG{INT}=$SIG{TERM}=$SIG{HUP}="DEFAULT"; exec @ARGV' bash "$MV" --copy-root . --file subject \
  --test-cmd 'sleep 9' --mutate-sed 's/hello/bye/' \
  --expect-fail-output hazard --control-sed 's/hello/control/' \
  --control-expect-fail-output control) > "$TMP/copy-int-out" 2>&1 &
copy_sig_pid=$!
ready_deadline=$((SECONDS+15))
while [ -z "$(find "$TMP/int-tmp" -name 'mutation-verify-copy.*' -type d -print)" ]; do
  [ "$SECONDS" -lt "$ready_deadline" ] || fail 'copy INT test did not create its directory'
  sleep 0.1
done
kill -s INT "$copy_sig_pid"
wait "$copy_sig_pid"
rc=$?
set +m
[ "$rc" -eq 130 ] || { cat "$TMP/copy-int-out"; fail 'copy INT must exit 130'; }
[ -z "$(find "$TMP/int-tmp" -name 'mutation-verify-copy.*' -print)" ] || fail 'copy INT leaked directory'
echo 'test copy-root: cleanup on INT PASS'
else
  echo 'SKIP in-place INT: perl unavailable to reset SIGINT'
  echo 'SKIP copy INT: perl unavailable to reset SIGINT'
fi

# ---------------------------------------------------------------------------
# Test 23 (cover-check): --cover-check function unreachable. Mutating a
# function that no test executes leaves the test command green, but that is
# NOT evidence of a survivor. It must be reported as MUTANT-UNREACHABLE.
# ---------------------------------------------------------------------------
GO23="$TMP/go_unreachable"; mkdir -p "$GO23"
cat > "$GO23/go.mod" <<'EOF'
module example.com/mutationverify/unreachable

go 1.21
EOF
cat > "$GO23/target.go" <<'EOF'
package unreachable

func Reachable() int {
	return 1
}

func Unreachable() int {
	return 2
}
EOF
cat > "$GO23/target_test.go" <<'EOF'
package unreachable

import "testing"

func TestReachable(t *testing.T) {
	if Reachable() != 1 {
		t.Fatal("unexpected Reachable result")
	}
}
EOF
before23="$(cat "$GO23/target.go")"
bash "$MV" --file "$GO23/target.go" --test-cmd "cd '$GO23' && go test ." \
  --cover-check Unreachable \
  --mutate-sed 's/return 2/return 3/' >"$TMP/out23" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out23"; fail "--cover-check unreachable function: expected exit 1, got $rc"; }
grep -q "MUTANT-UNREACHABLE" "$TMP/out23" || { cat "$TMP/out23"; fail "--cover-check unreachable function: expected MUTANT-UNREACHABLE"; }
grep -qi "mutation NOT caught" "$TMP/out23" && { cat "$TMP/out23"; fail "--cover-check unreachable function: must not report a survivor/false-green verdict"; }
[ "$(cat "$GO23/target.go")" = "$before23" ] || fail "--cover-check unreachable function: file not byte-identical after restore"
echo "test --cover-check unreachable function -> MUTANT-UNREACHABLE PASS"

# ---------------------------------------------------------------------------
# Test 24 (cover-check): --cover-check function reachable. Once the mutated
# function is actually executed, the legacy caught/not-caught verdicts still
# apply normally.
# ---------------------------------------------------------------------------
GO24="$TMP/go_reachable"; mkdir -p "$GO24"
cat > "$GO24/go.mod" <<'EOF'
module example.com/mutationverify/reachable

go 1.21
EOF
cat > "$GO24/target.go" <<'EOF'
package reachable

func Value() int {
	return 1
}
EOF
cat > "$GO24/caught_test.go" <<'EOF'
package reachable

import "testing"

func TestValueIsOne(t *testing.T) {
	if Value() != 1 {
		t.Fatal("unexpected Value result")
	}
}
EOF
before24="$(cat "$GO24/target.go")"
bash "$MV" --file "$GO24/target.go" --test-cmd "cd '$GO24' && go test ." \
  --cover-check Value \
  --mutate-sed 's/return 1/return 2/' >"$TMP/out24a" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out24a"; fail "--cover-check reachable killed mutant: expected exit 0, got $rc"; }
grep -q "mutation CAUGHT" "$TMP/out24a" || { cat "$TMP/out24a"; fail "--cover-check reachable killed mutant: expected caught verdict"; }
grep -q "MUTANT-UNREACHABLE" "$TMP/out24a" && { cat "$TMP/out24a"; fail "--cover-check reachable killed mutant: must not report unreachable"; }
[ "$(cat "$GO24/target.go")" = "$before24" ] || fail "--cover-check reachable killed mutant: file not byte-identical after restore"
cat > "$GO24/caught_test.go" <<'EOF'
package reachable

import "testing"

func TestValueExecutes(t *testing.T) {
	_ = Value()
}
EOF
bash "$MV" --file "$GO24/target.go" --test-cmd "cd '$GO24' && go test ." \
  --cover-check Value \
  --mutate-sed 's/return 1/return 2/' >"$TMP/out24b" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out24b"; fail "--cover-check reachable survived mutant: expected exit 1, got $rc"; }
grep -q "mutation NOT caught" "$TMP/out24b" || { cat "$TMP/out24b"; fail "--cover-check reachable survived mutant: expected not-caught verdict"; }
grep -q "MUTANT-UNREACHABLE" "$TMP/out24b" && { cat "$TMP/out24b"; fail "--cover-check reachable survived mutant: must not report unreachable"; }
[ "$(cat "$GO24/target.go")" = "$before24" ] || fail "--cover-check reachable survived mutant: file not byte-identical after restore"
echo "test --cover-check reachable mutants preserve caught/not-caught verdicts PASS"

# ---------------------------------------------------------------------------
# Test 25: --cover-check plus compile-breaking mutation. A mutation that
# breaks build/test is caught even though coverage cannot be produced.
# ---------------------------------------------------------------------------
GO25="$TMP/go_compile_break"; mkdir -p "$GO25"
cat > "$GO25/go.mod" <<'EOF'
module example.com/mutationverify/compilebreak

go 1.21
EOF
cat > "$GO25/target.go" <<'EOF'
package compilebreak

func Value() int {
	return 1
}
EOF
cat > "$GO25/target_test.go" <<'EOF'
package compilebreak

import "testing"

func TestValue(t *testing.T) {
	if Value() != 1 {
		t.Fatal("unexpected Value result")
	}
}
EOF
before25="$(cat "$GO25/target.go")"
bash "$MV" --file "$GO25/target.go" --test-cmd "cd '$GO25' && go test ." \
  --cover-check Value \
  --mutate-sed 's/return 1/return/' >"$TMP/out25" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out25"; fail "--cover-check compile-breaking mutant: expected caught exit 0, got $rc"; }
grep -q "mutation CAUGHT" "$TMP/out25" || { cat "$TMP/out25"; fail "--cover-check compile-breaking mutant: expected caught verdict"; }
grep -q "coverage unavailable" "$TMP/out25" || { cat "$TMP/out25"; fail "--cover-check compile-breaking mutant: expected coverage unavailable suffix"; }
grep -q "MUTANT-UNREACHABLE" "$TMP/out25" && { cat "$TMP/out25"; fail "--cover-check compile-breaking mutant: must not report unreachable"; }
[ "$(cat "$GO25/target.go")" = "$before25" ] || fail "--cover-check compile-breaking mutant: file not byte-identical after restore"
echo "test --cover-check compile-breaking mutant -> CAUGHT PASS"

# ---------------------------------------------------------------------------
# Test 26: the restored file must look NEWER than anything built from the
# mutant. mtime-based build tools (cargo's fingerprint,
# make) skip a rebuild when the source is older than its artifacts. A restore
# that copies the snapshot's ORIGINAL (old) mtime back leaves the mutant's
# artifacts looking fresh, so the next run silently executes the mutant.
# The test-cmd stands in for a build: it writes an artifact on every run, the
# last one being the under-mutation run.
# ---------------------------------------------------------------------------
F26="$TMP/mtime_target.txt"
A26="$TMP/mtime_artifact"
REF26="$TMP/mtime_ref"
printf 'hello world\n' > "$F26"
touch -t 200001010000 "$F26"
touch -t 200001020000 "$REF26"
before26="$(cat "$F26")"
cat > "$TMP/mtime_test.sh" <<EOF
#!/usr/bin/env bash
test_sec=\$(date +%s)
while [ "\$(date +%s)" -le "\$test_sec" ]; do sleep 0.02; done
rc=0
grep -q "hello world" "$F26" || rc=\$?
touch "$A26"
exit "\$rc"
EOF
chmod +x "$TMP/mtime_test.sh"
bash "$MV" --file "$F26" --test-cmd "$TMP/mtime_test.sh" --mutate-sed 's/hello/goodbye/' >"$TMP/out26" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out26"; fail "restore mtime: expected exit 0 (mutation caught), got $rc"; }
[ "$(cat "$F26")" = "$before26" ] || fail "restore mtime: file not byte-identical after restore"
[ "$F26" -nt "$REF26" ] || fail "restore mtime: restored file kept its pre-mutation mtime — an mtime-based build would reuse the mutant's artifacts"
mtime_sec() {
  pstat_mtime "$1"
}
[ "$(mtime_sec "$F26")" -gt "$(mtime_sec "$A26")" ] || fail "restore mtime: restored source must be strictly newer than mutant artifacts in whole seconds"
echo "test restored file is newer than mutant artifacts -> PASS"

# ---------------------------------------------------------------------------
# Test 27: same-size Python mutants must not survive in timestamp-based pyc.
# Start each import early in a second so a plain touch reproduces the bug.
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then (
  unset PYTHONDONTWRITEBYTECODE PYTHONPYCACHEPREFIX
  PY27="$TMP/python_cache"; mkdir -p "$PY27"
  printf 'def value(): return 1 == 1\n' > "$PY27/m.py"
  cat > "$PY27/check.py" <<'EOF'
import importlib.util
import os
import sys

# macOS Python may default to a system cache prefix even with env unset.
sys.pycache_prefix = None
cache = importlib.util.cache_from_source("m.py")
if os.path.exists(cache):
    os.unlink(cache)
import m
assert m.value()
EOF
  cat > "$PY27/mutate.sh" <<'EOF'
#!/usr/bin/env bash
second=$(date +%s)
while [ "$(date +%s)" -le "$second" ]; do sleep 0.02; done
sed 's/==/!=/' m.py > mutant
cat mutant > m.py
EOF
  bash "$MV" --file "$PY27/m.py" --test-cmd "cd '$PY27' && python3 check.py" \
    --mutate-cmd "cd '$PY27' && bash mutate.sh" >"$TMP/out27" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || { cat "$TMP/out27"; fail "Python cache: expected caught exit 0, got $rc"; }
  set -- "$PY27"/__pycache__/m.*.pyc
  [ -f "$1" ] || fail "Python cache: mutated run did not write a pyc"
  (cd "$PY27" && python3 -c 'import sys; sys.pycache_prefix = None; import m; assert m.value()') || fail "Python cache: fresh import reused the same-size mutant"
  echo "test restored Python module invalidates mutant pyc -> PASS"
) || fail "Python cache regression"
else
  echo "SKIP: Python cache regression (python3 absent)"
fi

# ---------------------------------------------------------------------------
# Test 28: syntax failure must restore newer than artifacts written after
# the mutation second, even though the mutated test never runs.
# ---------------------------------------------------------------------------
F28="$TMP/syntax_mtime_target.txt"
A28="$TMP/syntax_mtime_artifact"
printf 'hello world\n' > "$F28"
cat > "$TMP/syntax_artifact.sh" <<EOF
#!/usr/bin/env bash
second=\$(date +%s)
while [ "\$(date +%s)" -le "\$second" ]; do sleep 0.02; done
touch "$A28"
exit 1
EOF
bash "$MV" --file "$F28" --test-cmd "grep -q hello '$F28'" \
  --mutate-sed 's/hello/goodbye/' --syntax-cmd "bash '$TMP/syntax_artifact.sh'" >"$TMP/out28" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out28"; fail "syntax restore mtime: expected exit 2, got $rc"; }
[ "$(cat "$F28")" = "hello world" ] || fail "syntax restore mtime: original content not restored"
[ -f "$A28" ] || fail "syntax restore mtime: syntax command did not write an artifact"
[ "$(mtime_sec "$F28")" -gt "$(mtime_sec "$A28")" ] || fail "syntax restore mtime: restored source must be strictly newer than syntax artifacts in whole seconds"
echo "test syntax failure restores newer than artifacts -> PASS"

# Test 39 needs only the original guard fixture from the core cause tests.
F29="$TMP/cause_target.txt"
printf 'guard=on\nbanner=hello\n' > "$F29"

# 39: a test that leaves a background child holding its output must not make
# the run wait for that child.
cat > "$TMP/cause_bg_test.sh" <<EOF
#!/usr/bin/env bash
sleep 30 &
echo \$! >> "$TMP/bg39.pids"
grep -q '^guard=on\$' "$F29" || { echo "HAZARD: guard disabled"; exit 1; }
exit 0
EOF
chmod +x "$TMP/cause_bg_test.sh"
start39=$(date +%s)
bash "$MV" --file "$F29" --test-cmd "$TMP/cause_bg_test.sh" --mutate-sed 's/^guard=on$/guard=off/' \
  --expect-fail-output "HAZARD: guard disabled" >"$TMP/out39" 2>&1
rc=$?
elapsed39=$(( $(date +%s) - start39 ))
while read -r bgpid; do
  case "$bgpid" in ''|*[!0-9]*) continue ;; esac
  kill "$bgpid" 2>/dev/null
done < "$TMP/bg39.pids"
[ "$rc" -eq 0 ] || { cat "$TMP/out39"; fail "background child: expected exit 0, got $rc"; }
[ "$elapsed39" -lt 20 ] || fail "background child: run waited ${elapsed39}s for a background child"
echo "test --expect-fail-output does not wait for a background child PASS"

# 40: --expect-fail-output with --cover-check keeps both checks: the mutated
# run must still carry -coverprofile (reachability verified), and a reachable
# survivor stays NOT caught, never MUTANT-UNREACHABLE.
GO40="$TMP/go_cause_cover"; mkdir -p "$GO40"
printf 'module example.com/mutationverify/causecover\n\ngo 1.21\n' > "$GO40/go.mod"
printf 'package causecover\n\nfunc Value() int {\n\treturn 1\n}\n' > "$GO40/target.go"
cat > "$GO40/caught_test.go" <<'EOF'
package causecover

import "testing"

func TestValueIsOne(t *testing.T) {
	if Value() != 1 {
		t.Fatal("hazard: Value is not one")
	}
}
EOF
before40="$(cat "$GO40/target.go")"
bash "$MV" --file "$GO40/target.go" --test-cmd "cd '$GO40' && go test ." --cover-check Value \
  --mutate-sed 's/return 1/return 2/' --expect-fail-output "hazard: Value is not one" >"$TMP/out40a" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out40a"; fail "--cover-check + --expect-fail-output caught: expected exit 0, got $rc"; }
grep -q "reachability verified by --cover-check Value" "$TMP/out40a" || { cat "$TMP/out40a"; fail "--cover-check + --expect-fail-output caught: expected reachability verified"; }
grep -q "expected failure text present in output" "$TMP/out40a" || { cat "$TMP/out40a"; fail "--cover-check + --expect-fail-output caught: expected the text-present verdict"; }
printf 'package causecover\n\nimport "testing"\n\nfunc TestValueExecutes(t *testing.T) {\n\t_ = Value()\n}\n' > "$GO40/caught_test.go"
bash "$MV" --file "$GO40/target.go" --test-cmd "cd '$GO40' && go test ." --cover-check Value \
  --mutate-sed 's/return 1/return 2/' --expect-fail-output "hazard: Value is not one" >"$TMP/out40b" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out40b"; fail "--cover-check + --expect-fail-output survivor: expected exit 1, got $rc"; }
grep -q "mutation NOT caught" "$TMP/out40b" || { cat "$TMP/out40b"; fail "--cover-check + --expect-fail-output survivor: expected not-caught verdict"; }
grep -q "MUTANT-UNREACHABLE" "$TMP/out40b" && { cat "$TMP/out40b"; fail "--cover-check + --expect-fail-output survivor: must not report unreachable"; }
[ "$(cat "$GO40/target.go")" = "$before40" ] || fail "--cover-check + --expect-fail-output: file not byte-identical after restore"
echo "test --cover-check with --expect-fail-output keeps both verdicts PASS"

# 42: with --cover-check, the baseline runs with -coverprofile too, so text
# every coverprofile run prints ("of statements") is refused, not matched.
GO42="$TMP/go_cause_cover_baseline"; mkdir -p "$GO42"
printf 'module example.com/mutationverify/causecoverbaseline\n\ngo 1.21\n' > "$GO42/go.mod"
printf 'package causecoverbaseline\n\nfunc Value() int {\n\treturn 1\n}\n' > "$GO42/target.go"
printf 'package causecoverbaseline\n\nimport "testing"\n\nfunc TestValueIsOne(t *testing.T) {\n\tif Value() != 1 {\n\t\tt.Fatal("hazard: Value is not one")\n\t}\n}\n' > "$GO42/caught_test.go"
before42="$(cat "$GO42/target.go")"
bash "$MV" --file "$GO42/target.go" --test-cmd "cd '$GO42' && go test ." --cover-check Value \
  --mutate-sed 's/return 1/return 2/' --expect-fail-output "of statements" >"$TMP/out42" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out42"; fail "--cover-check baseline refusal: expected exit 2, got $rc"; }
grep -q "already appears in the passing baseline output" "$TMP/out42" || { cat "$TMP/out42"; fail "--cover-check baseline refusal: expected the baseline message"; }
[ "$(cat "$GO42/target.go")" = "$before42" ] || fail "--cover-check baseline refusal: file not byte-identical"
echo "test --cover-check baseline runs with -coverprofile for the refusal PASS"

# 79: a real runner with an exact (anchored) deselect: go test -skip '^TestParse$'.
# TestParse (the weak hazard test) and TestParseEmpty (a sibling) share one
# helper message; the mutant breaks only what the sibling checks, so the text
# persists without the hazard test and the run is refused.
GO79="$TMP/go_knockout"; mkdir -p "$GO79"
printf 'module example.com/mutationverify/knockout\n\ngo 1.21\n' > "$GO79/go.mod"
printf 'package knockout\n\nfunc Parse(s string) int {\n\tif s == "" {\n\t\treturn 0\n\t}\n\treturn len(s)\n}\n' > "$GO79/target.go"
cat > "$GO79/target_test.go" <<'EOF'
package knockout

import "testing"

func check(t *testing.T, got, want int) {
	t.Helper()
	if got != want {
		t.Fatal("value mismatch")
	}
}

func TestParse(t *testing.T)      { check(t, Parse("abc"), 3) }
func TestParseEmpty(t *testing.T) { check(t, Parse(""), 0) }
EOF
before79="$(cat "$GO79/target.go")"
# The documented go form: -v (one "=== RUN" line per test), one package, an
# anchored -skip, and --knockout-delta-line '=== RUN ' (go prints no
# deselection count; the tool counts one fewer RUN line).
GO79_TEST="cd '$GO79' && go test -v -count=1 ."
bash "$MV" --file "$GO79/target.go" --test-cmd "$GO79_TEST" \
  --mutate-sed 's/return 0/return 1/' --expect-fail-output "value mismatch" \
  --knockout-cmd "$GO79_TEST -skip '^TestParse\$'" --knockout-delta-line '=== RUN ' >"$TMP/out79" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out79"; fail "go exact knock-out, sibling catches: expected exit 2, got $rc"; }
grep -q "TEXT PERSISTS WITHOUT THE HAZARD TEST" "$TMP/out79" || { cat "$TMP/out79"; fail "go exact knock-out, sibling catches: expected the persists message"; }
[ "$(cat "$GO79/target.go")" = "$before79" ] || fail "go exact knock-out: file not byte-identical after restore"
echo "test a go exact knock-out refuses a sibling-only catch PASS"

# 79b: the same go form as a positive control: a mutant only TestParse
# catches loses its text under the knock-out -> CAUGHT with the count line.
bash "$MV" --file "$GO79/target.go" --test-cmd "$GO79_TEST" \
  --mutate-sed 's/return len(s)/return len(s)+1/' --expect-fail-output "value mismatch" \
  --knockout-cmd "$GO79_TEST -skip '^TestParse\$'" --knockout-delta-line '=== RUN ' >"$TMP/out79b" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out79b"; fail "go exact knock-out, hazard catches: expected exit 0, got $rc"; }
grep -F -q "deselection shown by one fewer '=== RUN ' line) removed the expected text" "$TMP/out79b" || { cat "$TMP/out79b"; fail "go exact knock-out, hazard catches: verdict must quote the delta line"; }
[ "$(cat "$GO79/target.go")" = "$before79" ] || fail "go exact knock-out positive control: file not byte-identical after restore"
echo "test a go exact knock-out attributes a hazard-only catch PASS"

# 87: the round-8 cargo case on the real runner (skipped without cargo): an
# unanchored --skip removes the sibling too and prints "11 filtered out"; the
# exact form keeps it and the text persists. Neither may report CAUGHT.
if command -v cargo >/dev/null 2>&1; then
  RS87="$TMP/rs_knockout"; mkdir -p "$RS87/src"
  printf '[package]\nname = "ko87"\nversion = "0.1.0"\nedition = "2021"\n\n[lib]\npath = "src/lib.rs"\n' > "$RS87/Cargo.toml"
  {
    printf 'pub fn parse(s: &str) -> usize { if s.is_empty() { 0 } else { s.len() } }\n\n#[cfg(test)]\nmod tests {\n    use super::*;\n'
    printf '    fn check(got: usize, want: usize) { assert!(got == want, "value mismatch"); }\n'
    printf '    #[test] fn parse_ok() { check(parse("abc"), 3); }\n'
    printf '    #[test] fn parse_ok_empty() { check(parse(""), 0); }\n'
    for i in 2 3 4 5 6 7 8 9 10; do printf '    #[test] fn parse_ok_n%s() { check(parse("x"), 1); }\n' "$i"; done
    printf '}\n'
  } > "$RS87/src/lib.rs"
  before87="$(cat "$RS87/src/lib.rs")"
  RS87_TEST="cd '$RS87' && CARGO_TARGET_DIR='$TMP/rs87-target' cargo test -q --offline"
  bash "$MV" --file "$RS87/src/lib.rs" --test-cmd "$RS87_TEST" --mutate-sed 's/{ 0 } else/{ 1 } else/' \
    --expect-fail-output "value mismatch" --knockout-cmd "$RS87_TEST -- --skip parse_ok" \
    --knockout-expect-output "1 filtered out" >"$TMP/out87a" 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out87a"; fail "cargo substring --skip: expected exit 2, got $rc"; }
  grep -q "must be --test-cmd plus exactly one documented deselect" "$TMP/out87a" || { cat "$TMP/out87a"; fail "cargo substring --skip: expected the shape refusal"; }
  bash "$MV" --file "$RS87/src/lib.rs" --test-cmd "$RS87_TEST" --mutate-sed 's/{ 0 } else/{ 1 } else/' \
    --expect-fail-output "value mismatch" --knockout-cmd "$RS87_TEST -- --exact --skip tests::parse_ok" \
    --knockout-expect-output "1 filtered out" >"$TMP/out87b" 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out87b"; fail "cargo exact --skip, sibling catches: expected exit 2, got $rc"; }
  grep -q "TEXT PERSISTS WITHOUT THE HAZARD TEST" "$TMP/out87b" || { cat "$TMP/out87b"; fail "cargo exact --skip, sibling catches: expected the persists message"; }
  [ "$(cat "$RS87/src/lib.rs")" = "$before87" ] || fail "cargo knock-out: file not byte-identical after restore"
  echo "test cargo knock-out: substring refused, exact form keeps the sibling PASS"
else
  echo "SKIP: cargo knock-out (cargo absent)"
fi

# 88: cargo with two test binaries sharing a test path (lib and tests/it.rs):
# --exact --skip deselects one test in EACH and each prints "1 filtered out";
# the tool sums them to 2 and refuses (skipped without cargo).
if command -v cargo >/dev/null 2>&1; then
  RS88="$TMP/rs_twobin"; mkdir -p "$RS88/src" "$RS88/tests"
  printf '[package]\nname = "ko88"\nversion = "0.1.0"\nedition = "2021"\n\n[lib]\npath = "src/lib.rs"\n' > "$RS88/Cargo.toml"
  printf 'pub fn parse(s: &str) -> usize { if s.is_empty() { 0 } else { s.len() } }\n\n#[cfg(test)]\nmod tests {\n    #[test] fn roundtrip() { assert!(super::parse("abc") == 3, "value mismatch"); }\n}\n' > "$RS88/src/lib.rs"
  printf 'mod tests {\n    #[test] fn roundtrip() { assert!(ko88::parse("") == 0, "value mismatch"); }\n}\n' > "$RS88/tests/it.rs"
  before88="$(cat "$RS88/src/lib.rs")"
  RS88_TEST="cd '$RS88' && CARGO_TARGET_DIR='$TMP/rs88-target' cargo test -q --offline"
  bash "$MV" --file "$RS88/src/lib.rs" --test-cmd "$RS88_TEST" --mutate-sed 's/{ 0 } else/{ 1 } else/' \
    --expect-fail-output "value mismatch" --knockout-cmd "$RS88_TEST -- --exact --skip tests::roundtrip" \
    --knockout-expect-output "1 filtered out" >"$TMP/out88" 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out88"; fail "cargo two binaries sharing a path: expected exit 2, got $rc"; }
  grep -q "counts sum to 2, not the declared --knockout-expect-output" "$TMP/out88" || { cat "$TMP/out88"; fail "cargo two binaries sharing a path: expected the summed-count refusal"; }
  grep -q "mutation CAUGHT" "$TMP/out88" && { cat "$TMP/out88"; fail "cargo two binaries sharing a path: must not report CAUGHT"; }
  [ "$(cat "$RS88/src/lib.rs")" = "$before88" ] || fail "cargo two binaries: file not byte-identical after restore"
  echo "test cargo knock-out across two test binaries is refused (summed count) PASS"
else
  echo "SKIP: cargo two-binary knock-out (cargo absent)"
fi

# 89: go delta line: a name defined in both the internal and the external
# test package is skipped twice (two fewer RUN lines) -> refused; a whole
# table skipped as '^Name$' removes every row -> refused; one row skipped as
# '^Name$/^row$' removes one RUN line -> accepted, and the sibling row that
# really catches the mutant keeps the text -> TEXT PERSISTS.
GO89="$TMP/go_delta"; mkdir -p "$GO89"
printf 'module example.com/mutationverify/delta\n\ngo 1.21\n' > "$GO89/go.mod"
printf 'package delta\n\nfunc Parse(s string) int {\n\tif s == "" {\n\t\treturn 0\n\t}\n\treturn len(s)\n}\n' > "$GO89/target.go"
cat > "$GO89/internal_test.go" <<'EOF'
package delta

import "testing"

func TestDup(t *testing.T) { _ = Parse("abc") }

func TestTable(t *testing.T) {
	for _, c := range []struct {
		name string
		in   string
		want int
	}{{"weak", "abc", 3}, {"empty", "", 0}} {
		t.Run(c.name, func(t *testing.T) {
			if c.name == "weak" {
				return
			}
			if Parse(c.in) != c.want {
				t.Fatal("value mismatch")
			}
		})
	}
}
EOF
cat > "$GO89/external_test.go" <<'EOF'
package delta_test

import (
	"testing"

	"example.com/mutationverify/delta"
)

func TestDup(t *testing.T) {
	if delta.Parse("") != 0 {
		t.Fatal("value mismatch")
	}
}
EOF
before89="$(cat "$GO89/target.go")"
GO89_TEST="cd '$GO89' && go test -v -count=1 ."
bash "$MV" --file "$GO89/target.go" --test-cmd "$GO89_TEST" --mutate-sed 's/return 0/return 1/' \
  --expect-fail-output "value mismatch" --knockout-cmd "$GO89_TEST -skip '^TestDup\$'" --knockout-delta-line '=== RUN ' >"$TMP/out89a" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out89a"; fail "go duplicate name in two test packages: expected exit 2, got $rc"; }
grep -q "full run 5, knock-out 3; exactly one fewer is required" "$TMP/out89a" || { cat "$TMP/out89a"; fail "go duplicate name: expected the delta refusal"; }
bash "$MV" --file "$GO89/target.go" --test-cmd "$GO89_TEST" --mutate-sed 's/return 0/return 1/' \
  --expect-fail-output "value mismatch" --knockout-cmd "$GO89_TEST -skip '^TestTable\$'" --knockout-delta-line '=== RUN ' >"$TMP/out89b" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out89b"; fail "go whole table skipped: expected exit 2, got $rc"; }
grep -q "full run 5, knock-out 2; exactly one fewer is required" "$TMP/out89b" || { cat "$TMP/out89b"; fail "go whole table skipped: expected the delta refusal"; }
bash "$MV" --file "$GO89/target.go" --test-cmd "$GO89_TEST" --mutate-sed 's/return 0/return 1/' \
  --expect-fail-output "value mismatch" --knockout-cmd "$GO89_TEST -skip '^TestTable\$/^weak\$'" --knockout-delta-line '=== RUN ' >"$TMP/out89c" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out89c"; fail "go one row skipped, sibling row catches: expected exit 2, got $rc"; }
grep -q "TEXT PERSISTS WITHOUT THE HAZARD TEST" "$TMP/out89c" || { cat "$TMP/out89c"; fail "go one row skipped: expected the persists message (the delta check passed)"; }
[ "$(cat "$GO89/target.go")" = "$before89" ] || fail "go delta tests: file not byte-identical after restore"
echo "test go delta line: duplicates and whole tables refused, one row accepted PASS"

# 91b: the go half of the re-check on the mutant. TestA_Hazard is weak but sets
# state; TestB_Setup panics on the mutant without it; TestC_Sibling really
# catches. Without the hazard test the binary dies at TestB, so the text
# "disappears" for the wrong reason; one fewer RUN line no longer holds on the
# mutant, and the run is refused.
GO91="$TMP/go_panic"; mkdir -p "$GO91"
printf 'module example.com/mutationverify/panic\n\ngo 1.21\n' > "$GO91/go.mod"
printf 'package panicdemo\n\nfunc Parse(s string) int {\n\tif s == "" {\n\t\treturn 0\n\t}\n\treturn len(s)\n}\n' > "$GO91/target.go"
cat > "$GO91/a_test.go" <<'EOF'
package panicdemo

import "testing"

var ready bool

func TestA_Hazard(t *testing.T) { ready = true; _ = Parse("abc") }

func TestB_Setup(t *testing.T) {
	if Parse("") != 0 && !ready {
		panic("setup crashed")
	}
}

func TestC_Sibling(t *testing.T) {
	if Parse("") != 0 {
		t.Fatal("value mismatch")
	}
}
EOF
before91b="$(cat "$GO91/target.go")"
GO91_TEST="cd '$GO91' && go test -v -count=1 ."
bash "$MV" --file "$GO91/target.go" --test-cmd "$GO91_TEST" --mutate-sed 's/return 0/return 1/' \
  --expect-fail-output "value mismatch" --knockout-cmd "$GO91_TEST -skip '^TestA_Hazard\$'" \
  --knockout-delta-line '=== RUN ' >"$TMP/out91b" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out91b"; fail "go knock-out crashing on the mutant: expected exit 2, got $rc"; }
grep -q "KNOCK-OUT SCOPE UNPROVEN ON THE MUTANT — lines starting with '=== RUN ': main run 3, knock-out run 1" "$TMP/out91b" || { cat "$TMP/out91b"; fail "go knock-out crashing on the mutant: expected the delta re-check refusal"; }
grep -q "mutation CAUGHT" "$TMP/out91b" && { cat "$TMP/out91b"; fail "go knock-out crashing on the mutant: must not report CAUGHT"; }
[ "$(cat "$GO91/target.go")" = "$before91b" ] || fail "go knock-out crashing on the mutant: file not byte-identical after restore"
echo "test a go knock-out that crashes on the mutant -> exit 2 PASS"

# 93b: the same on real cargo (skipped without cargo): the weak hazard test and
# the real catcher are the only two tests; with "-- --nocapture" in the test
# command, "-- --exact --skip tests::hazard_weak" would run ONLY the hazard
# test and print "1 filtered out" -> a false CAUGHT without the refusal.
if command -v cargo >/dev/null 2>&1; then
  RS93="$TMP/rs_doubledash"; mkdir -p "$RS93/src"
  printf '[package]\nname = "ko93"\nversion = "0.1.0"\nedition = "2021"\n\n[lib]\npath = "src/lib.rs"\ndoctest = false\n' > "$RS93/Cargo.toml"
  printf 'pub fn parse(s: &str) -> usize { s.len() + 1 }\n\n#[cfg(test)]\nmod tests {\n    use super::*;\n    #[test] fn hazard_weak() { assert!(parse("ab") < 1000, "value mismatch"); }\n    #[test] fn sibling_catches() { assert!(parse("") == 1, "value mismatch"); }\n}\n' > "$RS93/src/lib.rs"
  before93="$(cat "$RS93/src/lib.rs")"
  RS93_TEST="cd '$RS93' && CARGO_TARGET_DIR='$TMP/rs93-target' cargo test -q --offline -- --nocapture"
  bash "$MV" --file "$RS93/src/lib.rs" --test-cmd "$RS93_TEST" --mutate-sed 's/s.len() + 1/s.len() + 2/' \
    --expect-fail-output "value mismatch" --knockout-cmd "$RS93_TEST -- --exact --skip tests::hazard_weak" \
    --knockout-expect-output "1 filtered out" >"$TMP/out93b" 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || { cat "$TMP/out93b"; fail "real cargo test command with its own '--': expected exit 2, got $rc"; }
  grep -q "needs a --test-cmd without its own '--' section" "$TMP/out93b" || { cat "$TMP/out93b"; fail "real cargo test command with its own '--': expected the message"; }
  [ "$(cat "$RS93/src/lib.rs")" = "$before93" ] || fail "real cargo double-dash: file not byte-identical"
  echo "test real cargo: a test command with its own '--' section is refused PASS"
else
  echo "SKIP: real cargo double-dash knock-out (cargo absent)"
fi

echo "ALL PASS (slow)"
