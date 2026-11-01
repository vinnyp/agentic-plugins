#!/usr/bin/env bash
# test-agent-dispatch-doctor.sh — acceptance tests for agent-dispatch-doctor.
#
# Tests:
#   1. --install creates correct symlinks under a fake HOME
#   2. Second --install run is idempotent (already-installed, no error)
#   3. --install refuses to overwrite a real file; non-zero exit + file unchanged
#   4. Every executable non-test bin file is registered or explicitly opted out
#   5. Verify mode check 1 sees every registered entrypoint on PATH
#   6. run-tests.sh handles pass, runs all suites, and zero-suite cases
#
# Uses a mktemp dir as HOME so the real ~/.local/bin is never touched.
set -uo pipefail
unset RUN_TESTS_JOBS RUN_TESTS_TIMEOUT RUN_TESTS_KEEP_LOGS RUN_TESTS__PS_AVAILABLE
for run_tests_hook in ${!RUN_TESTS__TEST_@}; do unset "$run_tests_hook"; done
unset run_tests_hook

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck disable=SC1091
. "$BIN_DIR/lib/test-env-reset.sh"
reset_dispatch_env  # neutralize any operator-exported dispatch vars before the suite runs
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/agy-models.sh"
export AGY_TEST_CODING_PIN="$AGY_MODEL_CODING_DEFAULT" AGY_TEST_REVIEW_PIN="$AGY_MODEL_REVIEW_DEFAULT"
DOCTOR_BIN="$BIN_DIR/agent-dispatch-doctor"
RUN_TESTS_BIN="$BIN_DIR/run-tests.sh"

if [ ! -x "$DOCTOR_BIN" ]; then
  echo "FAIL: doctor not found or not executable at $DOCTOR_BIN"
  exit 1
fi

if [ ! -x "$RUN_TESTS_BIN" ]; then
  echo "FAIL: run-tests.sh not found or not executable at $RUN_TESTS_BIN"
  exit 1
fi

ENTRYPOINTS=()
while IFS= read -r entrypoint || [ -n "$entrypoint" ]; do
  ENTRYPOINTS+=("$entrypoint")
done <<EOF
$("$DOCTOR_BIN" --print-entrypoints)
EOF

FAILS=0

fail() {
  echo "FAIL: $*"
  FAILS=$((FAILS + 1))
}

pass() {
  echo "PASS: $*"
}

contains_name() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

assert_registry_complete() {
  local local_fails=0 candidate name

  # Deliberate non-entrypoints belong here with a comment explaining why they
  # are executable but not installed. agy-* probes are sourced internal helpers
  # and are intentionally not executable, so they do not need opt-outs.
  local opt_out=(
    audit-test-skips.sh    # repo-local kept-log audit, not an installed operator command
    run-stock-gate.sh      # repo-local stock environment gate, not an installed operator command
    run-tests.sh           # repo-local aggregate gate invoked as bin/run-tests.sh, not an installed operator command
    ensure-review-gate.sh  # build glue for the review-gate CLI, invoked by the skill via $CLAUDE_PLUGIN_ROOT, not by bare name
  )

  for candidate in "$BIN_DIR"/*; do
    [ -f "$candidate" ] || continue
    [ -x "$candidate" ] || continue
    name="$(basename "$candidate")"
    case "$name" in
      test-*.sh) continue ;;
    esac

    if contains_name "$name" "${ENTRYPOINTS[@]}" || contains_name "$name" ${opt_out[@]+"${opt_out[@]}"}; then
      continue
    fi

    echo "FAIL: $name is executable in bin/ but not registered in ENTRYPOINTS; add it to ENTRYPOINTS in bin/agent-dispatch-doctor or add a commented opt-out in bin/test-agent-dispatch-doctor.sh."
    local_fails=$((local_fails + 1))
  done

  [ "$local_fails" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Set up a temp HOME
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
export TMPDIR="$TMP"
UNREGISTERED_FIXTURE=""
cleanup() {
  [ -n "$UNREGISTERED_FIXTURE" ] && rm -f "$UNREGISTERED_FIXTURE"
  rm -rf "$TMP"
}
trap cleanup EXIT
# Make signal-terminated runs route through the EXIT trap explicitly. On bash 3.2
# the EXIT trap already fires for INT/TERM (verified). Explicit signal exits
# keep cleanup consistent for all temporary fixtures.
trap 'exit 1' INT TERM

FAKE_LOCAL_BIN="$TMP/.local/bin"

# ---------------------------------------------------------------------------
# Test 1: --install creates correct symlinks
# ---------------------------------------------------------------------------
echo "--- Test 1: --install creates symlinks under fake HOME ---"
HOME="$TMP" "$DOCTOR_BIN" --install
install_exit=$?

if [ "$install_exit" -ne 0 ]; then
  fail "Test 1: --install exited $install_exit (expected 0)"
else
  pass "Test 1: --install exit code 0"
fi

for name in "${ENTRYPOINTS[@]}"; do
  dst="$FAKE_LOCAL_BIN/$name"
  if [ ! -L "$dst" ]; then
    fail "Test 1: $name is not a symlink at $dst"
    continue
  fi
  target="$(readlink "$dst")"
  # Target may be absolute or relative — resolve it
  case "$target" in
    /*) abs_target="$target" ;;
    *)  abs_target="$FAKE_LOCAL_BIN/$target" ;;
  esac
  # Canonicalise both sides before comparing
  real_target="$(cd "$(dirname "$abs_target")" && pwd)/$(basename "$abs_target")"
  real_src="$(cd "$(dirname "$DOCTOR_BIN")" && pwd)/$name"
  if [ "$real_target" = "$real_src" ]; then
    pass "Test 1: $name → $real_src"
  else
    fail "Test 1: $name symlink points to $real_target, expected $real_src"
  fi
done

# ---------------------------------------------------------------------------
# Test 4: registry covers executable non-test bin files
# ---------------------------------------------------------------------------
echo
echo "--- Test 4: executable bin files are registered ---"
if assert_registry_complete; then
  pass "Test 4: executable non-test bin files are registered"
else
  fail "Test 4: executable non-test bin registry is incomplete"
fi

registry_bin=$BIN_DIR
BIN_DIR="$TMP/registry"
mkdir -p "$BIN_DIR"
UNREGISTERED_FIXTURE="$BIN_DIR/zz-unregistered-entrypoint.fixture"
printf '#!/usr/bin/env bash\nexit 0\n' > "$UNREGISTERED_FIXTURE"
chmod +x "$UNREGISTERED_FIXTURE"
registry_out="$(assert_registry_complete 2>&1)"
registry_rc=$?
rm -f "$UNREGISTERED_FIXTURE"
UNREGISTERED_FIXTURE=""
BIN_DIR=$registry_bin

if [ "$registry_rc" -eq 0 ]; then
  fail "Test 4: unregistered executable fixture did not fail registry check"
elif printf '%s\n' "$registry_out" | grep -qF "zz-unregistered-entrypoint.fixture is executable in bin/ but not registered in ENTRYPOINTS"; then
  pass "Test 4: unregistered executable fixture fails with file name and remediation"
else
  printf '%s\n' "$registry_out"
  fail "Test 4: unregistered executable failure did not name file and remediation"
fi

# ---------------------------------------------------------------------------
# Test 5: run-tests.sh aggregate runner behavior
# ---------------------------------------------------------------------------
echo
echo "--- Test 5: verify mode sees all registered entrypoints ---"
FAKE_RUNTIME_BIN="$TMP/fake-runtime-bin"
mkdir -p "$FAKE_RUNTIME_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_RUNTIME_BIN/codex"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_RUNTIME_BIN/shellcheck"
cat > "$FAKE_RUNTIME_BIN/agy" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "models" ]; then
  if [ "${DOCTOR_UNPARSEABLE:-}" = 1 ]; then echo "format drift"; exit 0; fi
  [ "${DOCTOR_DROP_MODEL:-}" = coding ] || printf '%s\tCoding\n' "$AGY_TEST_CODING_PIN"
  [ "${DOCTOR_DROP_MODEL:-}" = review ] || printf '%s\tReview\n' "$AGY_TEST_REVIEW_PIN"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_RUNTIME_BIN/codex" "$FAKE_RUNTIME_BIN/agy" "$FAKE_RUNTIME_BIN/shellcheck"
verify_out="$(PATH="$FAKE_RUNTIME_BIN:$BIN_DIR:$PATH" "$DOCTOR_BIN" 2>&1)"
verify_rc=$?
if [ "$verify_rc" -eq 0 ] &&
   printf '%s\n' "$verify_out" | grep -qF "all ${#ENTRYPOINTS[@]} entrypoints on PATH + executable"; then
  pass "Test 5: verify mode check 1 covers all ${#ENTRYPOINTS[@]} registered entrypoints"
else
  printf '%s\n' "$verify_out"
  fail "Test 5: verify mode did not pass check 1 for all registered entrypoints"
fi

# Both pins fail closed independently, including through relative symlink hops.
mkdir -p "$TMP/links/hop"
ln -s "$DOCTOR_BIN" "$TMP/links/hop/doctor"
ln -s hop/doctor "$TMP/links/doctor"
verify_out="$(PATH="$FAKE_RUNTIME_BIN:$BIN_DIR:$PATH" "$TMP/links/doctor" 2>&1)"; verify_rc=$?
[ "$verify_rc" -eq 0 ] || fail "relative multi-hop doctor symlink failed: $verify_out"
for role in coding review; do
  verify_out="$(DOCTOR_DROP_MODEL="$role" PATH="$FAKE_RUNTIME_BIN:$BIN_DIR:$PATH" "$DOCTOR_BIN" 2>&1)"; verify_rc=$?
  if [ "$verify_rc" -eq 1 ] && printf '%s\n' "$verify_out" | grep -q "FAIL.*$role default model"; then
    pass "missing $role pin fails doctor"
  else
    fail "missing $role pin did not fail doctor: $verify_out"
  fi
done

verify_out="$(DOCTOR_UNPARSEABLE=1 PATH="$FAKE_RUNTIME_BIN:$BIN_DIR:$PATH" "$DOCTOR_BIN" 2>&1)"; verify_rc=$?
if [ "$verify_rc" -eq 2 ] && printf '%s\n' "$verify_out" | grep -q 'WARN.*unparseable agy models'; then
  pass "unparseable models warn rather than report missing pins"
else
  fail "unparseable models should warn: $verify_out"
fi
mkdir -p "$TMP/broken-install"
cp "$DOCTOR_BIN" "$TMP/broken-install/agent-dispatch-doctor"
verify_out="$("$TMP/broken-install/agent-dispatch-doctor" 2>&1)"; verify_rc=$?
if [ "$verify_rc" -eq 1 ] && printf '%s\n' "$verify_out" | grep -q 'broken install'; then
  pass "missing model library reports broken install"
else
  fail "missing model library diagnostic: $verify_out"
fi

# ---------------------------------------------------------------------------
# Test 6: run-tests.sh aggregate runner behavior
# ---------------------------------------------------------------------------
echo
echo "--- Test 6: run-tests.sh aggregate runner ---"

if [ "${DOCTOR_SKIP_RUNNER_TESTS:-0}" != 1 ]; then
RUNNER_PASS="$TMP/runner-pass/bin"
mkdir -p "$RUNNER_PASS" "$TMP/runner-pass/test"
cp "$RUN_TESTS_BIN" "$RUNNER_PASS/run-tests.sh"
chmod +x "$RUNNER_PASS/run-tests.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNNER_PASS/test-b.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNNER_PASS/test-a.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/runner-pass/test/stray_commit.sh"
chmod +x "$RUNNER_PASS/test-a.sh" "$RUNNER_PASS/test-b.sh" "$TMP/runner-pass/test/stray_commit.sh"
pass_out="$("$RUNNER_PASS/run-tests.sh" -j 1 2>&1)"
pass_rc=$?
if [ "$pass_rc" -eq 0 ] &&
   printf '%s\n' "$pass_out" | grep -qx 'PASS test-a.sh ([0-9]*s)' &&
   printf '%s\n' "$pass_out" | grep -qx 'PASS test-b.sh ([0-9]*s)' &&
   printf '%s\n' "$pass_out" | grep -qFx "RUN  stray_commit.sh" &&
   printf '%s\n' "$pass_out" | grep -qx 'PASS stray_commit.sh ([0-9]*s)' &&
   printf '%s\n' "$pass_out" | grep -qFx "Summary: 3 passed, 0 failed, 3 total" &&
   printf '%s\n' "$pass_out" | grep -q '^GATE PASS:'; then
  pass "Test 6: run-tests.sh passes all suites and summarizes count"
else
  printf '%s\n' "$pass_out"
  fail "Test 6: run-tests.sh passing fixture did not exit 0 with expected summary"
fi

RUNNER_FAIL="$TMP/runner-fail/bin"
mkdir -p "$RUNNER_FAIL"
cp "$RUN_TESTS_BIN" "$RUNNER_FAIL/run-tests.sh"
chmod +x "$RUNNER_FAIL/run-tests.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RUNNER_FAIL/test-a.sh"
printf '#!/usr/bin/env bash\necho MARK-B\nexit 7\n' > "$RUNNER_FAIL/test-b.sh"
printf '#!/usr/bin/env bash\necho MARK-D\nexit 3\n' > "$RUNNER_FAIL/test-d.sh"
printf '#!/usr/bin/env bash\ntouch "%s/test-c-ran"\nexit 0\n' "$TMP" > "$RUNNER_FAIL/test-c.sh"
chmod +x "$RUNNER_FAIL/test-a.sh" "$RUNNER_FAIL/test-b.sh" "$RUNNER_FAIL/test-c.sh" "$RUNNER_FAIL/test-d.sh"
fail_out="$("$RUNNER_FAIL/run-tests.sh" -j 1 2>&1)"
fail_rc=$?
if [ "$fail_rc" -eq 1 ] &&
   [ -e "$TMP/test-c-ran" ] &&
   printf '%s\n' "$fail_out" | grep -qF "FAIL test-b.sh (exit 7," &&
   printf '%s\n' "$fail_out" | grep -qF "FAIL test-d.sh (exit 3," &&
   printf '%s\n' "$fail_out" | grep -qF "MARK-B" &&
   printf '%s\n' "$fail_out" | grep -qF "MARK-D" &&
   ! printf '%s\n' "$fail_out" | grep -q '^GATE PASS'; then
  pass "Test 6: run-tests.sh runs all suites and names every failing suite"
else
  printf '%s\n' "$fail_out"
  fail "Test 6: run-tests.sh failing fixture did not run all suites with expected failures"
fi

RUNNER_ZERO="$TMP/runner-zero/bin"
mkdir -p "$RUNNER_ZERO"
cp "$RUN_TESTS_BIN" "$RUNNER_ZERO/run-tests.sh"
chmod +x "$RUNNER_ZERO/run-tests.sh"
zero_out="$("$RUNNER_ZERO/run-tests.sh" 2>&1)"
zero_rc=$?
if [ "$zero_rc" -ne 0 ] &&
   printf '%s\n' "$zero_out" | grep -qF "ERROR: discovered 0 test suites"; then
  pass "Test 6: run-tests.sh zero-suite glob is a hard error"
else
  printf '%s\n' "$zero_out"
  fail "Test 6: run-tests.sh zero-suite fixture did not hard-fail"
fi

fi

# ---------------------------------------------------------------------------
# Test 2: second --install is idempotent
# ---------------------------------------------------------------------------
echo
echo "--- Test 2: second --install is idempotent ---"
HOME="$TMP" "$DOCTOR_BIN" --install
idempotent_exit=$?

if [ "$idempotent_exit" -ne 0 ]; then
  fail "Test 2: second --install exited $idempotent_exit (expected 0)"
else
  pass "Test 2: second --install exit code 0 (idempotent)"
fi

# Verify all symlinks still point correctly after idempotent run
for name in "${ENTRYPOINTS[@]}"; do
  dst="$FAKE_LOCAL_BIN/$name"
  if [ ! -L "$dst" ]; then
    fail "Test 2: $name symlink missing after idempotent run"
  else
    pass "Test 2: $name symlink still intact"
  fi
done

# ---------------------------------------------------------------------------
# Test 3: --install refuses to overwrite a real file
# ---------------------------------------------------------------------------
echo
echo "--- Test 3: --install refuses to overwrite a real file ---"

# Replace dispatch-worker symlink with a real file
VICTIM="$FAKE_LOCAL_BIN/dispatch-worker"
rm "$VICTIM"
echo "real file content" > "$VICTIM"
original_content="$(cat "$VICTIM")"

HOME="$TMP" "$DOCTOR_BIN" --install
clobber_exit=$?

if [ "$clobber_exit" -eq 0 ]; then
  fail "Test 3: --install exited 0 when a real file was present (expected non-zero)"
else
  pass "Test 3: --install exited $clobber_exit (non-zero, as expected)"
fi

# The real file must still exist and be unchanged (not a symlink)
if [ -L "$VICTIM" ]; then
  fail "Test 3: dispatch-worker was overwritten with a symlink (should have been refused)"
elif [ ! -f "$VICTIM" ]; then
  fail "Test 3: dispatch-worker disappeared (should have been left untouched)"
else
  current_content="$(cat "$VICTIM")"
  if [ "$current_content" = "$original_content" ]; then
    pass "Test 3: real file left untouched (content unchanged)"
  else
    fail "Test 3: real file content changed (was: '$original_content', now: '$current_content')"
  fi
fi

# The other entrypoints should still be installed correctly (doctor continues past the refusal)
for name in "${ENTRYPOINTS[@]}"; do
  [ "$name" = "dispatch-worker" ] && continue  # that's the victim
  dst="$FAKE_LOCAL_BIN/$name"
  if [ ! -L "$dst" ]; then
    fail "Test 3: $name symlink missing after partial --install (should be unaffected)"
  else
    pass "Test 3: $name symlink intact (unaffected by refused clobber)"
  fi
done

# ---------------------------------------------------------------------------
# Test 7: --install refuses to re-point a SYMLINK that is not ours, and DOES
# re-point one that belongs to another agent-dispatch checkout.
# A same-named symlink into somebody else's tool is exactly as much theirs as a
# real file is; silently hijacking it is the same defect the real-file refusal
# already guards against.
# ---------------------------------------------------------------------------
echo
echo "--- Test 7: --install and foreign vs agent-dispatch symlinks ---"

# 7a. A symlink to a FOREIGN tool must survive untouched, with a WARN.
FOREIGN_TOOL="$TMP/foreign-tool/gate-run.sh"
mkdir -p "$(dirname "$FOREIGN_TOOL")"
printf '#!/usr/bin/env bash\necho foreign\n' > "$FOREIGN_TOOL"
chmod +x "$FOREIGN_TOOL"
rm -f "$FAKE_LOCAL_BIN/gate-run.sh"
ln -s "$FOREIGN_TOOL" "$FAKE_LOCAL_BIN/gate-run.sh"
foreign_out="$(HOME="$TMP" "$DOCTOR_BIN" --install 2>&1)"
if [ "$(readlink "$FAKE_LOCAL_BIN/gate-run.sh")" = "$FOREIGN_TOOL" ]; then
  pass "Test 7a: foreign symlink left pointing at its own target"
else
  fail "Test 7a: --install hijacked a foreign symlink (now -> $(readlink "$FAKE_LOCAL_BIN/gate-run.sh"))"
fi
if printf '%s' "$foreign_out" | grep -q "not an agent-dispatch checkout"; then
  pass "Test 7a: refusal explains why the symlink was left alone"
else
  fail "Test 7a: no WARN naming the foreign symlink: $foreign_out"
fi

# 7b. A symlink into ANOTHER agent-dispatch checkout IS re-pointed at this one.
OTHER_CHECKOUT="$TMP/other-agent-dispatch"
mkdir -p "$OTHER_CHECKOUT/bin" "$OTHER_CHECKOUT/.claude-plugin"
printf '{ "name": "agent-dispatch", "version": "0.0.1" }\n' > "$OTHER_CHECKOUT/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\necho other\n' > "$OTHER_CHECKOUT/bin/gate-run.sh"
chmod +x "$OTHER_CHECKOUT/bin/gate-run.sh"
rm -f "$FAKE_LOCAL_BIN/gate-run.sh"
ln -s "$OTHER_CHECKOUT/bin/gate-run.sh" "$FAKE_LOCAL_BIN/gate-run.sh"
HOME="$TMP" "$DOCTOR_BIN" --install >/dev/null 2>&1
if [ "$(readlink "$FAKE_LOCAL_BIN/gate-run.sh")" = "$BIN_DIR/gate-run.sh" ]; then
  pass "Test 7b: a symlink from another agent-dispatch checkout is re-pointed"
else
  fail "Test 7b: --install did not re-point an agent-dispatch symlink (now -> $(readlink "$FAKE_LOCAL_BIN/gate-run.sh"))"
fi

# ---------------------------------------------------------------------------
# Test 8: --install honours the documented exit contract (0/1/2) — a WARN with no
# FAIL must exit 2, not 0. A skipped entrypoint means a command is NOT installed;
# an installer script that reads exit 0 as "done" would ship a broken PATH.
# ---------------------------------------------------------------------------
echo
echo "--- Test 8: --install exits 2 on WARN-and-no-FAIL ---"

# Clear the Test 3 victim (a real file => FAIL) so WARN is the only condition left.
rm -f "$VICTIM"
HOME="$TMP" "$DOCTOR_BIN" --install >/dev/null 2>&1
clean_exit=$?
if [ "$clean_exit" -eq 0 ]; then
  pass "Test 8: a clean --install exits 0"
else
  fail "Test 8: a clean --install exited $clean_exit (expected 0)"
fi

# Now reintroduce exactly one foreign symlink => exactly one WARN, zero FAILs.
rm -f "$FAKE_LOCAL_BIN/gate-run.sh"
ln -s "$FOREIGN_TOOL" "$FAKE_LOCAL_BIN/gate-run.sh"
HOME="$TMP" "$DOCTOR_BIN" --install >/dev/null 2>&1
warn_exit=$?
if [ "$warn_exit" -eq 2 ]; then
  pass "Test 8: --install exits 2 when an entrypoint was skipped (WARN, no FAIL)"
else
  fail "Test 8: --install exited $warn_exit with a skipped entrypoint (expected 2)"
fi
if [ "$(readlink "$FAKE_LOCAL_BIN/gate-run.sh")" = "$FOREIGN_TOOL" ]; then
  pass "Test 8: the skipped entrypoint is still untouched after the WARN exit"
else
  fail "Test 8: the foreign symlink was modified (now -> $(readlink "$FAKE_LOCAL_BIN/gate-run.sh"))"
fi

# A partial installation must diagnose every required review helper.
for missing_helper in repo-state.sh review-clone.sh timeout-bin.sh; do
  fake_install="$TMP/missing-$missing_helper"
  mkdir -p "$fake_install/lib"
  fake_install="$(cd "$fake_install" && pwd -P)"
  cp "$DOCTOR_BIN" "$fake_install/agent-dispatch-doctor"
  cp "$(dirname "$DOCTOR_BIN")/lib/portable-timeout" "$(dirname "$DOCTOR_BIN")/lib/portable-stat.sh" "$fake_install/lib/"
  cp "$(dirname "$DOCTOR_BIN")/lib/agy-models.sh" "$fake_install/lib/agy-models.sh"
  for helper in repo-state.sh review-clone.sh timeout-bin.sh; do
    if [ "$helper" != "$missing_helper" ]; then
      cp "$(dirname "$DOCTOR_BIN")/lib/$helper" "$fake_install/lib/$helper"
    fi
  done
  missing_rc=0
  missing_out="$(bash "$fake_install/agent-dispatch-doctor" 2>&1)" || missing_rc=$?
  if [ "$missing_rc" -eq 1 ] && printf '%s\n' "$missing_out" | grep -qF "FAIL broken install: cannot read $fake_install/lib/$missing_helper"; then
    pass "missing $missing_helper fails installation check"
  else
    fail "missing $missing_helper was not diagnosed: $missing_out"
  fi
done

cp "$(dirname "$DOCTOR_BIN")/lib/timeout-bin.sh" "$fake_install/lib/"
chmod -x "$fake_install/lib/portable-timeout"
missing_rc=0
missing_out="$(bash "$fake_install/agent-dispatch-doctor" 2>&1)" || missing_rc=$?
if [ "$missing_rc" = 1 ] && printf '%s\n' "$missing_out" | grep -qF 'FAIL broken install: helper is not executable'; then
  pass 'nonexecutable timer helper fails installation check'
else
  fail "nonexecutable timer helper was not diagnosed: $missing_out"
fi

# Live checks use only these PATH stubs, never an installed agent.
LIVE_BIN="$TMP/live-bin"
mkdir -p "$LIVE_BIN" "$TMP/live-temp"
cat > "$LIVE_BIN/agy" <<'EOF'
#!/usr/bin/env bash
case "$PWD" in "$TMPDIR"/*)
  [ -f .git ] && git rev-parse --git-common-dir | grep -q /seed/.git || exit 8
  grep -qx 'Use the shell command tool to run: ls -a . Then reply with DONE.' || exit 9
  case "${LIVE_TMPDIR:-empty}" in
    output) printf 'DONE\n' ;;
    failure) exit 3 ;;
    timeout) exit 124 ;;
  esac
  exit 0 ;;
esac
[ "${LIVE_FAIL:-}" != agy ] || exit 3
if [ "${LIVE_AUTH_FAIL:-0}" = 1 ]; then
  echo 'invalid_grant'; exit 0
fi
case " $* " in
  *' models '*) ;;
  ' --dangerously-skip-permissions ') cat >/dev/null ;;
  *) exit 9 ;;
esac
case "${LIVE_NEGATIVE:-}" in
  silent) exit 0 ;;
  stderr) echo LIVE_SMOKE_OK >&2; exit 0 ;;
  signin) echo 'sign in to continue'; exit 0 ;;
  claim) echo 'success'; exit 0 ;;
  sleep) while :; do sleep 1; done ;;
esac
printf 'LIVE_SMOKE_OK\n'
EOF
cat > "$LIVE_BIN/codex" <<'EOF'
#!/usr/bin/env bash
case "$PWD/" in "$TMPDIR/"*) exit 9 ;; esac
[ "${GIT_CONFIG_NOSYSTEM:-}" = 1 ] && [ -f "${GIT_CONFIG_GLOBAL:-}" ] && [ ! -s "$GIT_CONFIG_GLOBAL" ] || exit 9
case " $* " in
  *' --sandbox read-only '*)
    [ "${LIVE_RO_WRITE:-0}" != 1 ] || echo bad > live-smoke-inside
    ;;
  *' --sandbox workspace-write '*)
    for arg in "$@"; do prompt=$arg; done
    content=${prompt#Write exactly }; content=${content%% followed*}
    printf '%s\n' "$content" > live-smoke-inside
    [ "${LIVE_ESCAPE:-0}" != 1 ] || printf 'escaped\n' > ../outside
    ;;
  *) exit 9 ;;
esac
printf '%s\n' "$*" >&2
case "${LIVE_REPLY:-}" in
  silent) exit 0 ;;
  stderr) echo WRITE_REFUSED >&2; exit 0 ;;
  claim) echo WRITE_OK; exit 0 ;;
esac
printf 'WRITE_REFUSED\n'
EOF
cat > "$LIVE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
case " $* " in *' --permission-mode plan '*) ;; *) exit 9 ;; esac
[ "${LIVE_PLAN_WRITE:-0}" != 1 ] || echo bad > live-smoke-inside
printf '%s\n' "$*" >&2
case "${LIVE_REPLY:-}" in
  silent) exit 0 ;;
  stderr) echo WRITE_REFUSED >&2; exit 0 ;;
  claim) echo WRITE_OK; exit 0 ;;
esac
printf 'WRITE_REFUSED\n'
EOF
chmod +x "$LIVE_BIN/agy" "$LIVE_BIN/codex" "$LIVE_BIN/claude"
# A closed PATH prevents a missing stub from falling through to a real runtime.
for tool in bash git mkdir mktemp rm cat grep date mv dirname basename chmod sleep perl timeout gtimeout; do
  location=$(command -v "$tool" 2>/dev/null) || continue
  ln -s "$location" "$LIVE_BIN/$tool"
done
live_run() {
  DISPATCH_LIVE_TIMEOUT=1 HOME="$TMP" TMPDIR="$TMP/live-temp" XDG_STATE_HOME="$TMP/state" PATH="$LIVE_BIN" "$DOCTOR_BIN" --live
}
live_out=$(live_run 2>&1); live_rc=$?
[ "$live_rc" = 0 ] && [ "$(printf '%s\n' "$live_out" | grep -c '^PASS ')" = 5 ] || fail "live all-pass: $live_out"
last_good="$TMP/state/agent-dispatch/last-live.json"
[ -s "$last_good" ] || fail 'live success did not record last-good JSON'
good=$(cat "$last_good" 2>/dev/null)
printf '%s\n' "$good" | grep -q '"checks":5' || fail 'INFO counted in last-good checks'
printf '%s\n' "$live_out" | grep -q '^INFO agy-tmpdir: no output (denial trap active) (rc=0)$' || fail 'empty TMPDIR observation missing'
for outcome in output failure timeout; do
  live_out=$(LIVE_TMPDIR="$outcome" live_run 2>&1); live_rc=$?
  [ "$live_rc" = 0 ] && [ "$(printf '%s\n' "$live_out" | grep -c '^PASS ')" = 5 ] || fail "TMPDIR $outcome turned result red: $live_out"
  case "$outcome" in
    output) expected='output present (rc=0)' ;;
    failure) expected='inconclusive (rc=3)' ;;
    timeout) expected='inconclusive (rc=124)' ;;
  esac
  printf '%s\n' "$live_out" | grep -qxF "INFO agy-tmpdir: $expected" || fail "TMPDIR $outcome observation missing: $live_out"
done
for fixture in "$TMP/live-temp"/dispatch-live.* "$TMP/.cache/agent-dispatch-live"/smoke.*; do
  [ ! -e "$fixture" ] || fail "live fixture was not cleaned up: $fixture"
done
good=$(cat "$last_good" 2>/dev/null)
LIVE_FAIL=agy live_run > "$TMP/live-fail" 2>&1; live_rc=$?
[ "$live_rc" != 0 ] && grep -q '^FAIL ' "$TMP/live-fail" || fail 'live agent failure should fail'
LIVE_ESCAPE=1 live_run > "$TMP/live-escape" 2>&1; live_rc=$?
[ "$live_rc" != 0 ] || fail 'workspace-write outside mutation accepted'
for fault in LIVE_AUTH_FAIL LIVE_RO_WRITE LIVE_PLAN_WRITE; do
  live_out=$(export "$fault=1"; live_run 2>&1); live_rc=$?
  [ "$live_rc" != 0 ] || fail "$fault regression accepted: $live_out"
done
for reply in silent stderr claim; do
  live_out=$(LIVE_REPLY="$reply" live_run 2>&1); live_rc=$?
  [ "$live_rc" != 0 ] && printf '%s\n' "$live_out" | grep -q '^FAIL.*codex-read-only' &&
    printf '%s\n' "$live_out" | grep -q '^FAIL.*claude-plan' || fail "$reply write reply accepted: $live_out"
done
for negative in silent signin claim stderr sleep; do
  started=$SECONDS
  live_out=$(LIVE_NEGATIVE="$negative" live_run 2>&1); live_rc=$?
  [ "$live_rc" != 0 ] && printf '%s\n' "$live_out" | grep -q '^FAIL.*agy' || fail "$negative reply accepted: $live_out"
  [ "$((SECONDS - started))" -lt 12 ] || fail "$negative timeout was not prompt"
done
rm "$LIVE_BIN/claude"
live_out=$(live_run 2>&1); live_rc=$?
[ "$live_rc" != 0 ] && printf '%s\n' "$live_out" | grep -q '^NOT RUN.*claude' || fail "missing agent must be NOT RUN: $live_out"
[ "$(cat "$last_good" 2>/dev/null)" = "$good" ] || fail 'failed live run replaced last-good'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if [ "$FAILS" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "FAILED: $FAILS assertion(s) failed"
  exit 1
fi
