#!/usr/bin/env bash
# test-mutation-verify.sh — TDD suite for mutation-verify.sh.
#
# Covers: RED (genuine test) -> exit 0; GREEN/false-green -> exit 1;
# no-op mutation -> exit 2; byte-identical restore in all cases; restore
# still happens when --test-cmd crashes UNDER MUTATION; a failing BASELINE
# (before mutation) aborts with exit 2 and leaves the file untouched; the
# load-bearing uncommitted-work case (the whole point of #115); a relative
# --file combined with a cd-ing --test-cmd (the #115 follow-up regression);
# a value-less trailing flag must exit 2 promptly instead of hanging; the
# --mutate-cmd happy path; temp-dir cleanup leaves no stray snapshot dirs;
# a failed restore KEEPS the snapshot and prints its path; and a static
# check that the script never invokes git.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
MV="$SELF_DIR/mutation-verify.sh"
fail() { echo "FAIL: $1"; exit 1; }

# ---------------------------------------------------------------------------
# Test 1: RED case — a genuine test that checks the file's content. Mutating
# the file must break the test (test-cmd exits non-zero) -> mutation-verify
# reports the mutation was CAUGHT: exit 0.
# ---------------------------------------------------------------------------
F1="$TMP/red_target.txt"
printf 'hello world\n' > "$F1"
before1="$(cat "$F1")"
cat > "$TMP/red_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "hello world" "$F1"
EOF
chmod +x "$TMP/red_test.sh"
bash "$MV" --file "$F1" --test-cmd "$TMP/red_test.sh" --mutate-sed 's/hello/goodbye/' >"$TMP/out1" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out1"; fail "RED case: expected exit 0 (mutation caught), got $rc"; }
[ "$(cat "$F1")" = "$before1" ] || fail "RED case: file not byte-identical after restore"
echo "test RED case (genuine test) -> exit 0 PASS"

# ---------------------------------------------------------------------------
# Test 2: GREEN/false-green case — a test that ignores the file entirely.
# Mutating the file leaves test-cmd green -> mutation-verify must report
# the test does NOT isolate the fix: exit 1.
# ---------------------------------------------------------------------------
F2="$TMP/green_target.txt"
printf 'hello world\n' > "$F2"
before2="$(cat "$F2")"
printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/green_test.sh"
chmod +x "$TMP/green_test.sh"
bash "$MV" --file "$F2" --test-cmd "$TMP/green_test.sh" --mutate-sed 's/hello/goodbye/' >"$TMP/out2" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out2"; fail "GREEN/false-green case: expected exit 1, got $rc"; }
[ "$(cat "$F2")" = "$before2" ] || fail "GREEN/false-green case: file not byte-identical after restore"
echo "test GREEN/false-green case -> exit 1 PASS"

# ---------------------------------------------------------------------------
# Test 3: no-op mutation — the sed expression matches nothing, so the file
# is unchanged post-mutation. This must be caught as a hard error: exit 2.
# ---------------------------------------------------------------------------
F3="$TMP/noop_target.txt"
printf 'hello world\n' > "$F3"
before3="$(cat "$F3")"
printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/noop_test.sh"
chmod +x "$TMP/noop_test.sh"
bash "$MV" --file "$F3" --test-cmd "$TMP/noop_test.sh" --mutate-sed 's/nonexistent-pattern/x/' >"$TMP/out3" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out3"; fail "no-op mutation: expected exit 2, got $rc"; }
grep -qi "unchanged\|no-op\|no changes\|did not change" "$TMP/out3" || { cat "$TMP/out3"; fail "no-op mutation: expected a clear error message"; }
[ "$(cat "$F3")" = "$before3" ] || fail "no-op mutation: file not byte-identical after restore"
echo "test no-op mutation -> exit 2 PASS"

# ---------------------------------------------------------------------------
# Test 4: restore still happens when --test-cmd crashes UNDER MUTATION (as
# opposed to a baseline failure — that's test 4b below). The test-cmd passes
# cleanly against the unmutated content (so it clears the baseline run) but
# execs a nonexistent command once the file has been mutated, so the
# under-mutation run dies with a command-not-found rather than a clean
# assertion failure. Restore must still run on every path.
# ---------------------------------------------------------------------------
F4="$TMP/crash_target.txt"
printf 'hello world\n' > "$F4"
before4="$(cat "$F4")"
cat > "$TMP/crash_test.sh" <<EOF
#!/usr/bin/env bash
if grep -q "hello world" "$F4"; then
  exit 0
else
  exec "$TMP/this-command-does-not-exist-anywhere"
fi
EOF
chmod +x "$TMP/crash_test.sh"
bash "$MV" --file "$F4" --test-cmd "$TMP/crash_test.sh" --mutate-sed 's/hello/goodbye/' >"$TMP/out4" 2>&1
rc=$?
# The under-mutation run command-not-founds (non-zero) -> mutation was
# "caught" (exit 0), same as any other non-zero test-cmd exit. The
# load-bearing assertion here is that the file is restored regardless.
[ "$rc" -eq 0 ] || { cat "$TMP/out4"; fail "crashing test-cmd under mutation: expected exit 0 (non-zero test-cmd = caught), got $rc"; }
[ "$(cat "$F4")" = "$before4" ] || fail "crashing test-cmd under mutation: file not restored/byte-identical"
echo "test restore happens when test-cmd crashes under mutation PASS"

# ---------------------------------------------------------------------------
# Test 4b (MAJOR 5): a --test-cmd that is already broken/failing BEFORE
# mutation must be caught by the baseline run and abort with exit 2 — a
# false green inside the false-green detector otherwise (if the baseline
# had been skipped, this would have exited 0 "mutation caught" for the
# wrong reason). The file must be left completely untouched: no mutation is
# ever attempted once the baseline fails.
# ---------------------------------------------------------------------------
F4B="$TMP/baseline_fail_target.txt"
printf 'hello world\n' > "$F4B"
before4b="$(cat "$F4B")"
bash "$MV" --file "$F4B" --test-cmd "$TMP/this-command-does-not-exist-anywhere" --mutate-sed 's/hello/goodbye/' >"$TMP/out4b" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out4b"; fail "baseline-fails: expected exit 2, got $rc"; }
grep -qi "baseline\|before mutation" "$TMP/out4b" || { cat "$TMP/out4b"; fail "baseline-fails: expected a message naming the baseline failure"; }
[ "$(cat "$F4B")" = "$before4b" ] || fail "baseline-fails: file was NOT left untouched"
echo "test baseline-fails (broken test-cmd) -> exit 2, file untouched PASS"

# ---------------------------------------------------------------------------
# Test 5 (the whole point of #115): a file with UNCOMMITTED modifications
# (staged or unstaged, ahead of HEAD) must be preserved EXACTLY after a
# mutation-verify run — not reverted to the last commit. This is the case
# that `git checkout -- <file>` gets wrong three times over (#33/#43/#115).
# ---------------------------------------------------------------------------
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
F5="$REPO/dirty.txt"
printf 'committed baseline\n' > "$F5"
git -C "$REPO" add -A
git -C "$REPO" commit -qm baseline
# Now make an UNCOMMITTED edit — this is the "in-flight fix" the helper must protect.
printf 'committed baseline\nUNCOMMITTED fix in progress\n' > "$F5"
uncommitted_content="$(cat "$F5")"
[ -n "$(git -C "$REPO" status --porcelain -- dirty.txt)" ] || fail "setup: dirty.txt should show as modified before the run"
cat > "$TMP/dirty_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "UNCOMMITTED fix in progress" "$F5"
EOF
chmod +x "$TMP/dirty_test.sh"
bash "$MV" --file "$F5" --test-cmd "$TMP/dirty_test.sh" --mutate-sed 's/UNCOMMITTED/MUTATED/' >"$TMP/out5" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out5"; fail "uncommitted-work case: expected exit 0 (mutation caught), got $rc"; }
[ "$(cat "$F5")" = "$uncommitted_content" ] || fail "uncommitted-work case: file was NOT preserved exactly (reverted to HEAD instead of the uncommitted edit?)"
[ "$(cat "$F5")" != "committed baseline" ] || fail "uncommitted-work case: file was reverted to the committed baseline — this is exactly the #33/#43/#115 bug"
echo "test uncommitted-work preserved exactly (not reverted to HEAD) PASS"

# ---------------------------------------------------------------------------
# Test 6: static assertion — the script must NEVER invoke git in any form.
# Strip full-line comments first (the doc header legitimately DISCUSSES git
# as the anti-pattern this helper replaces) and check only the executable
# code for a "git" token.
# ---------------------------------------------------------------------------
grep -v '^[[:space:]]*#' "$MV" | grep -qE '(^|[^a-zA-Z0-9_-])git($|[^a-zA-Z0-9_-])' && fail "mutation-verify.sh must NEVER invoke git in any form (outside comments)"
echo "test script contains no git invocation PASS"

# ---------------------------------------------------------------------------
# Test 7: bad args -> usage + exit 2.
# ---------------------------------------------------------------------------
bash "$MV" >"$TMP/out_usage" 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "missing args: expected exit 2, got $rc"
bash "$MV" --file "$TMP/does-not-exist.txt" --test-cmd true --mutate-sed 's/a/b/' >"$TMP/out_missing" 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "missing --file target: expected exit 2, got $rc"
F7="$TMP/both_mutate.txt"; printf 'x\n' > "$F7"
bash "$MV" --file "$F7" --test-cmd true --mutate-sed 's/a/b/' --mutate-cmd true >"$TMP/out_both" 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "both --mutate-sed and --mutate-cmd given: expected exit 2, got $rc"
bash "$MV" --file "$F7" --test-cmd true >"$TMP/out_neither" 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "neither --mutate-sed nor --mutate-cmd given: expected exit 2, got $rc"
echo "test bad args -> exit 2 with usage PASS"

# ---------------------------------------------------------------------------
# Test 8 (BLOCKER 2 regression): a value-less trailing flag (--file as the
# LAST argument, with no value after it) must exit 2 PROMPTLY. Before the
# fix, `shift 2` on a `$#`-of-1 arg list left `$#` unchanged and the parse
# loop spun forever. Wrapped in `timeout 5` so a regression fails loudly
# (timeout's 124) instead of hanging the whole suite.
# ---------------------------------------------------------------------------
timeout 5 bash "$MV" --file >"$TMP/out_trailing_flag" 2>&1
rc=$?
[ "$rc" -ne 124 ] || { cat "$TMP/out_trailing_flag"; fail "value-less trailing --file: HUNG (timeout 124) — BLOCKER 2 regression"; }
[ "$rc" -eq 2 ] || { cat "$TMP/out_trailing_flag"; fail "value-less trailing --file: expected exit 2, got $rc"; }
echo "test value-less trailing flag -> exit 2 promptly (no hang) PASS"

# ---------------------------------------------------------------------------
# Test 9 (BLOCKER 1 regression): a RELATIVE --file combined with a --test-cmd
# that `cd`s elsewhere. Before the fix, restore_file's `cp -p "$snap_file"
# "$file"` ran from the test-cmd's new cwd and wrote to the WRONG path,
# leaving the real target file MUTATED (and a stray copy at the wrong
# location) while the script still exited 0. The file must be restored
# byte-identically at its ORIGINAL absolute path, with no stray copy
# anywhere under the relative subdirectory the test-cmd cd'd into.
# ---------------------------------------------------------------------------
CDCASE="$TMP/cdcase"; mkdir -p "$CDCASE/sub"
(
  cd "$CDCASE" || exit 1
  printf 'hello world\n' > target.txt
  before9="$(cat target.txt)"
  # Content-aware test-cmd: cd's into sub/ (changing cwd) then checks the
  # target file's content via a path relative to sub/. Passes on the
  # original content (clears the baseline run) and fails once mutated, so
  # this proves cwd-independence rather than short-circuiting on a
  # permanently-broken test-cmd.
  bash "$MV" --file target.txt --test-cmd "cd sub && grep -q 'hello world' ../target.txt" --mutate-sed 's/hello/goodbye/' >out9 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || { cat out9; fail "relative --file + cd-ing test-cmd: expected exit 0 (mutation caught), got $rc"; }
  [ "$(cat target.txt)" = "$before9" ] || fail "relative --file + cd-ing test-cmd: target.txt not byte-identical at its original path after restore"
  [ ! -e sub/target.txt ] || fail "relative --file + cd-ing test-cmd: a stray copy was left at sub/target.txt"
)
[ $? -eq 0 ] || fail "relative --file + cd-ing test-cmd subshell reported failure"
echo "test relative --file + cd-ing test-cmd restores at the original path, no stray copy PASS"

# ---------------------------------------------------------------------------
# Test 10: --mutate-cmd HAPPY PATH. Previously --mutate-cmd was only
# exercised in the bad-args (--mutate-sed + --mutate-cmd together) test, so
# the actual mutation branch was entirely unverified. Use --mutate-cmd to
# perform the same content mutation as the sed cases and confirm the RED
# verdict + byte-identical restore.
# ---------------------------------------------------------------------------
F10="$TMP/mutate_cmd_target.txt"
printf 'hello world\n' > "$F10"
before10="$(cat "$F10")"
cat > "$TMP/mutate_cmd_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "hello world" "$F10"
EOF
chmod +x "$TMP/mutate_cmd_test.sh"
bash "$MV" --file "$F10" --test-cmd "$TMP/mutate_cmd_test.sh" --mutate-cmd "printf 'goodbye world\n' > '$F10'" >"$TMP/out10" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out10"; fail "--mutate-cmd happy path: expected exit 0 (mutation caught), got $rc"; }
[ "$(cat "$F10")" = "$before10" ] || fail "--mutate-cmd happy path: file not byte-identical after restore"
echo "test --mutate-cmd happy path -> exit 0, byte-identical restore PASS"

# ---------------------------------------------------------------------------
# Test 11: temp-dir cleanup. Point TMPDIR at a controlled, empty directory;
# after a successful run it must contain NO leftover mutation-verify.*
# snapshot dirs. Reviewer-proven necessity: deleting the trap and the
# `rm -rf` leaves the rest of the suite fully green today, so this is the
# only test that would catch that regression.
# ---------------------------------------------------------------------------
CLEANTMP="$TMP/cleantmp"; mkdir -p "$CLEANTMP"
F11="$TMP/cleanup_target.txt"
printf 'hello world\n' > "$F11"
TMPDIR="$CLEANTMP" bash "$MV" --file "$F11" --test-cmd true --mutate-sed 's/hello/goodbye/' >"$TMP/out11" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out11"; fail "temp-dir cleanup setup: expected exit 1 (false-green, test-cmd=true), got $rc"; }
leftover="$(find "$CLEANTMP" -mindepth 1 -name 'mutation-verify.*')"
[ -z "$leftover" ] || fail "temp-dir cleanup: leftover snapshot dir(s) after a successful run: $leftover"
echo "test temp-dir cleanup leaves no leftover mutation-verify.* dirs PASS"

# ---------------------------------------------------------------------------
# Test 12 (BLOCKER 4 regression): restore-failure KEEPS the snapshot. Force
# a restore failure by making the mutated file itself read-only (via
# --mutate-cmd, since the file must still be writable at mutation time) so
# the later `cp -p` restore is denied. The script must exit 2 AND the
# snapshot dir must still exist (not deleted by cleanup), with its path
# printed to stderr so the work is recoverable by hand.
# ---------------------------------------------------------------------------
F12="$TMP/restore_fail_target.txt"
printf 'hello world\n' > "$F12"
before12="$(cat "$F12")"
CLEANTMP12="$TMP/cleantmp12"; mkdir -p "$CLEANTMP12"
TMPDIR="$CLEANTMP12" bash "$MV" --file "$F12" --test-cmd true \
  --mutate-cmd "printf 'MUTATED\n' > '$F12' && chmod 444 '$F12'" \
  >"$TMP/out12" 2>&1
rc=$?
chmod 644 "$F12" 2>/dev/null || true
[ "$rc" -eq 2 ] || { cat "$TMP/out12"; fail "restore-failure: expected exit 2, got $rc"; }
grep -qi "restore failed" "$TMP/out12" || { cat "$TMP/out12"; fail "restore-failure: expected a RESTORE FAILED message"; }
snap_path="$(grep -oE '/[^ ]*mutation-verify\.[A-Za-z0-9]+' "$TMP/out12" | head -1)"
[ -n "$snap_path" ] || { cat "$TMP/out12"; fail "restore-failure: expected the snapshot dir's path to be printed"; }
[ -d "$snap_path" ] || fail "restore-failure: snapshot dir $snap_path was NOT kept (cleanup deleted the only surviving backup)"
[ -f "$snap_path/snapshot" ] || fail "restore-failure: snapshot file missing under $snap_path"
[ "$(cat "$snap_path/snapshot")" = "$before12" ] || fail "restore-failure: kept snapshot does not match the original content"
rm -rf "$snap_path"
echo "test restore-failure keeps the snapshot and prints its path PASS"

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
F13="$TMP/sigint_target.txt"
printf 'hello world\n' > "$F13"
before13="$(cat "$F13")"
cat > "$TMP/slow_test.sh" <<'EOF'
#!/usr/bin/env bash
sleep 10
EOF
chmod +x "$TMP/slow_test.sh"
# `set -m` (job control) is required here: without it, a non-interactive
# script's ASYNC commands have SIGINT/SIGQUIT set to ignored by bash itself
# before mutation-verify.sh even starts, and a shell may not trap a signal
# that was already ignored on entry — so `kill -INT` on the background job
# would silently do nothing and this test would just run to completion.
set -m
bash "$MV" --file "$F13" --test-cmd "$TMP/slow_test.sh" --mutate-sed 's/hello/goodbye/' >"$TMP/out13" 2>&1 &
sig_pid=$!
sleep 1
kill -s INT "$sig_pid"
wait "$sig_pid"
rc=$?
set +m
[ "$rc" -eq 130 ] || { cat "$TMP/out13"; fail "SIGINT: expected exit 130 (signal-derived), got $rc"; }
[ "$(cat "$F13")" = "$before13" ] || fail "SIGINT: file not restored/byte-identical after interrupt"
grep -qi "restore failed" "$TMP/out13" && { cat "$TMP/out13"; fail "SIGINT: spurious RESTORE FAILED message for a run that actually succeeded (cleanup() ran twice)"; }
echo "test SIGINT during test-cmd -> signal-derived exit, file restored, no spurious failure PASS"

# ---------------------------------------------------------------------------
# Test 14 (applied-verification): --expect-anchor present. The anchor is checked
# against the original snapshot before mutation; a valid anchor must preserve
# the existing caught verdict and restore the file byte-identically.
# ---------------------------------------------------------------------------
F14="$TMP/expect_anchor_present.txt"
printf 'hello anchor world\n' > "$F14"
before14="$(cat "$F14")"
cat > "$TMP/expect_anchor_present_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "hello anchor world" "$F14"
EOF
chmod +x "$TMP/expect_anchor_present_test.sh"
bash "$MV" --file "$F14" --test-cmd "$TMP/expect_anchor_present_test.sh" \
  --expect-anchor "anchor world" \
  --mutate-sed 's/hello/goodbye/' >"$TMP/out14" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out14"; fail "--expect-anchor present: expected exit 0, got $rc"; }
[ "$(cat "$F14")" = "$before14" ] || fail "--expect-anchor present: file not byte-identical after restore"
echo "test --expect-anchor present preserves verdict PASS"

# ---------------------------------------------------------------------------
# Test 15 (applied-verification): --expect-anchor absent. This is a harness error:
# the mutation target is not present in the original snapshot, so the helper
# must exit 2 before mutating and leave the file byte-identical.
# ---------------------------------------------------------------------------
F15="$TMP/expect_anchor_absent.txt"
printf 'hello world\n' > "$F15"
before15="$(cat "$F15")"
bash "$MV" --file "$F15" --test-cmd true \
  --expect-anchor "missing anchor" \
  --mutate-sed 's/hello/goodbye/' >"$TMP/out15" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out15"; fail "--expect-anchor absent: expected exit 2, got $rc"; }
grep -q "ANCHOR NOT FOUND" "$TMP/out15" || { cat "$TMP/out15"; fail "--expect-anchor absent: expected ANCHOR NOT FOUND"; }
[ "$(cat "$F15")" = "$before15" ] || fail "--expect-anchor absent: file not byte-identical after restore"
echo "test --expect-anchor absent -> exit 2 PASS"

# ---------------------------------------------------------------------------
# Test 16 (applied-verification): --expect-marker present after mutation. The marker
# proves the intended edit landed, while the content-aware test still drives
# the normal caught verdict.
# ---------------------------------------------------------------------------
F16="$TMP/expect_marker_present.txt"
printf 'hello world\n' > "$F16"
before16="$(cat "$F16")"
cat > "$TMP/expect_marker_present_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "hello world" "$F16"
EOF
chmod +x "$TMP/expect_marker_present_test.sh"
bash "$MV" --file "$F16" --test-cmd "$TMP/expect_marker_present_test.sh" \
  --expect-marker "goodbye world" \
  --mutate-sed 's/hello/goodbye/' >"$TMP/out16" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out16"; fail "--expect-marker present: expected exit 0, got $rc"; }
[ "$(cat "$F16")" = "$before16" ] || fail "--expect-marker present: file not byte-identical after restore"
echo "test --expect-marker present preserves verdict PASS"

# ---------------------------------------------------------------------------
# Test 17 (applied-verification, load-bearing): bytes change, but the intended marker
# is absent and the test fails for an unrelated command-not-found reason.
# Without marker verification, this would be misreported as mutation CAUGHT
# (exit 0). The correct result is a harness error: exit 2.
# ---------------------------------------------------------------------------
F17="$TMP/marker_absent_unrelated_failure.txt"
printf 'state=original\n' > "$F17"
before17="$(cat "$F17")"
cat > "$TMP/marker_absent_unrelated_failure_test.sh" <<EOF
#!/usr/bin/env bash
if grep -q "state=original" "$F17"; then
  exit 0
fi
exec "$TMP/marker-absent-command-does-not-exist"
EOF
chmod +x "$TMP/marker_absent_unrelated_failure_test.sh"
bash "$MV" --file "$F17" --test-cmd "$TMP/marker_absent_unrelated_failure_test.sh" \
  --expect-marker "state=intended_marker" \
  --mutate-sed 's/state=original/state=wrong_edit/' >"$TMP/out17" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out17"; fail "marker absent with unrelated failure: expected exit 2, got $rc"; }
grep -q "MARKER ABSENT" "$TMP/out17" || { cat "$TMP/out17"; fail "marker absent with unrelated failure: expected MARKER ABSENT"; }
[ "$(cat "$F17")" = "$before17" ] || fail "marker absent with unrelated failure: file not byte-identical after restore"
echo "test marker absent blocks unrelated failure false-pass PASS"

# ---------------------------------------------------------------------------
# Test 18 (applied-verification): --syntax-cmd failing after mutation. A syntactically
# invalid mutated file is a harness error, because any later test failure
# would be the wrong red.
# ---------------------------------------------------------------------------
F18="$TMP/syntax_failing_target.sh"
printf 'echo ok\n' > "$F18"
before18="$(cat "$F18")"
bash "$MV" --file "$F18" --test-cmd true \
  --syntax-cmd "bash -n '$F18'" \
  --mutate-sed 's/echo ok/if then/' >"$TMP/out18" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out18"; fail "--syntax-cmd failing: expected exit 2, got $rc"; }
grep -q "MUTATED FILE INVALID" "$TMP/out18" || { cat "$TMP/out18"; fail "--syntax-cmd failing: expected MUTATED FILE INVALID"; }
[ "$(cat "$F18")" = "$before18" ] || fail "--syntax-cmd failing: file not byte-identical after restore"
echo "test --syntax-cmd failing -> exit 2 PASS"

# ---------------------------------------------------------------------------
# Test 19 (applied-verification): --syntax-cmd passing. A valid syntax command is
# enough to verify application for verdict-label purposes and must preserve
# the existing caught exit code.
# ---------------------------------------------------------------------------
F19="$TMP/syntax_passing_target.sh"
printf 'echo hello\n' > "$F19"
before19="$(cat "$F19")"
cat > "$TMP/syntax_passing_test.sh" <<EOF
#!/usr/bin/env bash
grep -q "echo hello" "$F19"
EOF
chmod +x "$TMP/syntax_passing_test.sh"
bash "$MV" --file "$F19" --test-cmd "$TMP/syntax_passing_test.sh" \
  --syntax-cmd "bash -n '$F19'" \
  --mutate-sed 's/echo hello/echo goodbye/' >"$TMP/out19" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out19"; fail "--syntax-cmd passing: expected exit 0, got $rc"; }
grep -q "\[UNVERIFIED APPLICATION\]" "$TMP/out19" && { cat "$TMP/out19"; fail "--syntax-cmd passing: verdict should not be labelled unverified"; }
[ "$(cat "$F19")" = "$before19" ] || fail "--syntax-cmd passing: file not byte-identical after restore"
echo "test --syntax-cmd passing preserves verified verdict PASS"

# ---------------------------------------------------------------------------
# Test 20 (applied-verification): no applied-verification flags supplied. Exit code
# remains identical to the legacy false-green path, but the verdict is
# labelled unverified.
# ---------------------------------------------------------------------------
F20="$TMP/unverified_no_flags.txt"
printf 'hello world\n' > "$F20"
before20="$(cat "$F20")"
bash "$MV" --file "$F20" --test-cmd true \
  --mutate-sed 's/hello/goodbye/' >"$TMP/out20" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out20"; fail "no verification flags: expected legacy exit 1, got $rc"; }
grep -q "\[UNVERIFIED APPLICATION\]" "$TMP/out20" || { cat "$TMP/out20"; fail "no verification flags: expected unverified verdict label"; }
grep -qi "reachability was NOT verified" "$TMP/out20" || { cat "$TMP/out20"; fail "no cover-check flag: expected reachability-not-verified summary"; }
[ "$(cat "$F20")" = "$before20" ] || fail "no verification flags: file not byte-identical after restore"
echo "test no verification flags labels unchanged verdict PASS"

# ---------------------------------------------------------------------------
# Test 21 (applied-verification): two --expect-marker flags, second missing. Every
# supplied marker must be present; a partial match is still a harness error.
# ---------------------------------------------------------------------------
F21="$TMP/two_markers_second_missing.txt"
printf 'hello world\n' > "$F21"
before21="$(cat "$F21")"
bash "$MV" --file "$F21" --test-cmd true \
  --expect-marker "goodbye world" \
  --expect-marker "second marker missing" \
  --mutate-sed 's/hello/goodbye/' >"$TMP/out21" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out21"; fail "two markers second missing: expected exit 2, got $rc"; }
grep -q "MARKER ABSENT" "$TMP/out21" || { cat "$TMP/out21"; fail "two markers second missing: expected MARKER ABSENT"; }
[ "$(cat "$F21")" = "$before21" ] || fail "two markers second missing: file not byte-identical after restore"
echo "test repeated --expect-marker requires every marker PASS"

# ---------------------------------------------------------------------------
# Test 22 (bash-3.2 regression): explicitly use /bin/bash with
# none of the new array-backed flags. On macOS bash 3.2, unguarded empty
# array expansion under set -u fails with "unbound variable"; PATH-resolved
# bash may be newer and would not catch the regression.
# ---------------------------------------------------------------------------
if /bin/bash --version 2>/dev/null | head -1 | grep -q 'version 3\.'; then
  F22="$TMP/bash32_empty_arrays.txt"
  printf 'hello world\n' > "$F22"
  before22="$(cat "$F22")"
  /bin/bash "$MV" --file "$F22" --test-cmd true \
    --mutate-sed 's/hello/goodbye/' >"$TMP/out22" 2>&1
  rc=$?
  [ "$rc" -ne 127 ] || { cat "$TMP/out22"; fail "bash-3.2 empty arrays: command failed with rc 127"; }
  grep -q "unbound variable" "$TMP/out22" && { cat "$TMP/out22"; fail "bash-3.2 empty arrays: unguarded empty array expansion"; }
  [ "$(cat "$F22")" = "$before22" ] || fail "bash-3.2 empty arrays: file not byte-identical after restore"
  echo "test /bin/bash 3.x empty-array guarded expansion PASS"
else
  echo "SKIP bash-3.2 empty-array regression: /bin/bash is not 3.x"
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

echo "ALL PASS"
