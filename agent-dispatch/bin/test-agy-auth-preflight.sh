#!/usr/bin/env bash
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SELF_DIR/lib/test-env-reset.sh"
reset_dispatch_env  # neutralize any operator-exported dispatch vars before the suite runs
PREFLIGHT="$SELF_DIR/coding-preflight.sh"
DW="$SELF_DIR/dispatch-worker"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $1"; exit 1; }

mkdir -p "$TMP/bin" "$TMP/home"
export HOME="$TMP/home"
export PATH="$TMP/bin:$PATH"
export AGY_CALL_LOG="$TMP/agy-calls"

cat > "$TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGY_CALL_LOG"
case "${1:-}" in
  models)
    case "${AGY_STUB_MODE:-healthy}" in
      healthy)
        printf '%s\n' 'Gemini 3.1 Pro (High)'
        exit 0
        ;;
      dead)
        printf '%s\n' 'Error: Please sign in to view available models. Launch the CLI without arguments to sign in.' >&2
        exit 1
        ;;
      dead_antigravity)
        printf '%s\n' 'You are not logged into Antigravity' >&2
        exit 1
        ;;
      network)
        printf '%s\n' 'dial tcp: connection refused' >&2
        exit 1
        ;;
      unknown)
        printf '%s\n' 'some unexpected internal error' >&2
        exit 1
        ;;
      slow)
        sleep 60
        exit 0
        ;;
      *)
        printf '%s\n' "unknown AGY_STUB_MODE=${AGY_STUB_MODE:-}" >&2
        exit 99
        ;;
    esac
    ;;
  *)
    cat
    exit 0
    ;;
esac
STUB

cat > "$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
shift
# Scoped to the `agy models` call the auth probe makes (AGY_STUB_MODE=slow
# simulates ONLY that call hanging) — a blanket match on every timeout invocation
# would also swallow the unrelated agy-print-form-probe.sh bare-stdin call that
# shares this stubbed `timeout` binary, forcing it to a spurious 124 too.
if [ "${AGY_STUB_MODE:-}" = "slow" ]; then
  case "$*" in
    *models*)
      printf '%s\n' "${*:2}" >> "$AGY_CALL_LOG"
      exit 124
      ;;
  esac
fi
"$@"
STUB

chmod +x "$TMP/bin/agy" "$TMP/bin/timeout"

reset_calls() {
  : > "$AGY_CALL_LOG"
}

assert_called() {
  grep -qF "$1" "$AGY_CALL_LOG" || fail "expected agy call '$1', got: $(cat "$AGY_CALL_LOG")"
}

assert_not_called() {
  grep -qF "$1" "$AGY_CALL_LOG" && fail "unexpected agy call '$1', got: $(cat "$AGY_CALL_LOG")"
}

assert_no_rejected_agy_args() {
  grep -Eq '(^| )exec( |$)|(^| )-( |$)' "$AGY_CALL_LOG" && fail "agy invocation used rejected positional args: $(cat "$AGY_CALL_LOG")"
}

BRIEF="$TMP/brief.md"
printf 'Review the diff.\n' > "$BRIEF"

# Real (throwaway) git repo for --review dispatches: dispatch_agy's hermetic-review
# path (agent-dispatch 0.6.1+) actually `cd`s into the review target — first into an
# isolated detached worktree at HEAD when the workdir is a git work tree, else
# non-hermetically into the workdir itself — so it can read the files under review.
# A nonexistent path like the old placeholder /repo/x now fails that `cd` outright
# (rc=1, no agy dispatch at all), which is not the healthy-dispatch scenario these
# tests mean to exercise. Give review dispatches a real repo with a commit at HEAD.
REVIEW_WORKDIR="$TMP/review-repo"
mkdir -p "$REVIEW_WORKDIR"
git -C "$REVIEW_WORKDIR" init -q
git -C "$REVIEW_WORKDIR" -c user.email=test@example.com -c user.name=test commit -q --allow-empty -m "init"

# Probe-unit coverage for advisory vs hard-block branches.
# shellcheck disable=SC1091
. "$SELF_DIR/agy-auth-probe.sh"

reset_calls
AGY_STUB_MODE=network agy_auth_probe >"$TMP/probe-network.out" 2>"$TMP/probe-network.err"; rc=$?
[ "$rc" -eq 2 ] || fail "network probe should be advisory rc2, got $rc"
assert_called "models"
echo "test probe 1 (network error advisory) PASS"

reset_calls
AGY_STUB_MODE=unknown agy_auth_probe >"$TMP/probe-unknown.out" 2>"$TMP/probe-unknown.err"; rc=$?
[ "$rc" -eq 2 ] || fail "unknown non-zero probe should be advisory rc2, got $rc"
assert_called "models"
echo "test probe 2 (unknown non-zero advisory) PASS"

reset_calls
rm -rf "$HOME/.gemini"
AGY_STUB_MODE=healthy agy_auth_probe >"$TMP/probe-no-creds-healthy.out" 2>"$TMP/probe-no-creds-healthy.err"; rc=$?
[ "$rc" -eq 0 ] || fail "absent creds + healthy live models should return rc0, got $rc"
assert_called "models"
echo "test probe 3 (absent creds ignored; live models healthy) PASS"

reset_calls
AGY_STUB_MODE=dead_antigravity agy_auth_probe >"$TMP/probe-antigravity-dead.out" 2>"$TMP/probe-antigravity-dead.err"; rc=$?
[ "$rc" -eq 7 ] || fail "'not logged into Antigravity' should hard-block rc7, got $rc"
assert_called "models"
echo "test probe 4 (not logged into Antigravity -> rc7) PASS"

# 1. coding-preflight agy, healthy.
reset_calls
AGY_STUB_MODE=healthy "$PREFLIGHT" agy >"$TMP/preflight-healthy.out" 2>"$TMP/preflight-healthy.err"; rc=$?
[ "$rc" -eq 0 ] || fail "healthy preflight should exit 0, got $rc"
grep -q '^PREFLIGHT=ok$' "$TMP/preflight-healthy.out" || fail "healthy preflight missing PREFLIGHT=ok"
assert_called "models"
echo "test 1 (coding-preflight agy healthy) PASS"

# 1b. coding-preflight agy, invoked through a PATH-style symlink.
reset_calls
ln -s "$PREFLIGHT" "$TMP/bin/coding-preflight-symlink.sh"
AGY_STUB_MODE=healthy "$TMP/bin/coding-preflight-symlink.sh" agy >"$TMP/preflight-symlink.out" 2>"$TMP/preflight-symlink.err"; rc=$?
[ "$rc" -eq 0 ] || fail "symlinked preflight should exit 0, got $rc: $(cat "$TMP/preflight-symlink.err")"
grep -q '^PREFLIGHT=ok$' "$TMP/preflight-symlink.out" || fail "symlinked preflight missing PREFLIGHT=ok"
grep -q 'agy-auth-probe.sh: No such file' "$TMP/preflight-symlink.err" && fail "symlinked preflight resolved helper from symlink dir"
assert_called "models"
echo "test 1b (coding-preflight agy symlink resolves helper) PASS"

# 2. coding-preflight agy, dead token.
reset_calls
AGY_STUB_MODE=dead "$PREFLIGHT" agy >"$TMP/preflight-dead.out" 2>"$TMP/preflight-dead.err"; rc=$?
[ "$rc" -ne 0 ] || fail "dead-token preflight should fail"
grep -q '^PREFLIGHT=ok$' "$TMP/preflight-dead.out" && fail "dead-token preflight must not emit PREFLIGHT=ok"
grep -qi 'sign in' "$TMP/preflight-dead.out" || grep -qi 'sign in' "$TMP/preflight-dead.err" || fail "dead-token preflight should tell user to sign in"
assert_called "models"
echo "test 2 (coding-preflight agy dead token) PASS"

# 3. coding-preflight agy, no creds file: live probe is authoritative and succeeds.
reset_calls
rm -rf "$HOME/.gemini"
AGY_STUB_MODE=healthy "$PREFLIGHT" agy >"$TMP/preflight-nocreds.out" 2>"$TMP/preflight-nocreds.err"; rc=$?
[ "$rc" -eq 0 ] || fail "no-creds + healthy live models preflight should exit 0, got $rc"
grep -q '^PREFLIGHT=ok$' "$TMP/preflight-nocreds.out" || fail "no-creds healthy preflight missing PREFLIGHT=ok"
assert_called "models"
echo "test 3 (coding-preflight agy no creds still probes live models) PASS"

# 4. coding-preflight agy, probe timeout: warn but do not block.
reset_calls
AGY_STUB_MODE=slow "$PREFLIGHT" agy >"$TMP/preflight-timeout.out" 2>"$TMP/preflight-timeout.err"; rc=$?
[ "$rc" -eq 0 ] || fail "timeout preflight should proceed, got $rc"
grep -q '^PREFLIGHT=ok$' "$TMP/preflight-timeout.out" || fail "timeout preflight missing PREFLIGHT=ok"
grep -qi 'timed out' "$TMP/preflight-timeout.err" || fail "timeout preflight should warn"
assert_called "models"
echo "test 4 (coding-preflight agy timeout proceeds) PASS"

# 5. dispatch_agy --review, dead token: fail fast before dispatch.
reset_calls
AGY_STUB_MODE=dead TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir /repo/x >"$TMP/dw-review-dead.out" 2>"$TMP/dw-review-dead.err"; rc=$?
[ "$rc" -eq 7 ] || fail "dead-token review dispatch should return 7, got $rc"
grep -qi 're-authenticate agy' "$TMP/dw-review-dead.err" || fail "dead-token dispatch should tell user to re-authenticate agy"
assert_called "models"
assert_no_rejected_agy_args
echo "test 5 (dispatch_agy review dead token fails fast) PASS"

# 6. dispatch_agy --review, healthy: probe then dispatch.
# DISPATCH_MIN_REVIEW_BYTES=1: this test is about the auth-probe-then-dispatch
# flow, not review substantiveness — the passthrough stub only echoes the short
# shared $BRIEF, which the default 1200B floor would
# otherwise fail closed.
reset_calls
AGY_STUB_MODE=healthy DISPATCH_MIN_REVIEW_BYTES=1 DISPATCH_REVIEW_REQUIRE_EVIDENCE=0 TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$REVIEW_WORKDIR" >"$TMP/dw-review-healthy.out" 2>"$TMP/dw-review-healthy.err"; rc=$?
[ "$rc" -eq 0 ] || fail "healthy review dispatch should exit 0, got $rc"
grep -q 'READ-ONLY REVIEW MODE' "$TMP/dw-review-healthy.out" || fail "healthy review dispatch did not send review brief"
assert_called "models"
assert_no_rejected_agy_args
echo "test 6 (dispatch_agy review healthy proceeds) PASS"

# 6b. dispatch-worker agy --review, invoked through a PATH-style symlink.
# DISPATCH_MIN_REVIEW_BYTES=1: see #6 — this test is about symlink resolution,
# not review substantiveness.
reset_calls
ln -s "$DW" "$TMP/bin/dispatch-worker-symlink"
AGY_STUB_MODE=healthy DISPATCH_MIN_REVIEW_BYTES=1 DISPATCH_REVIEW_REQUIRE_EVIDENCE=0 TIMEOUT=0 "$TMP/bin/dispatch-worker-symlink" --runtime agy --review --brief "$BRIEF" --workdir "$REVIEW_WORKDIR" >"$TMP/dw-review-symlink.out" 2>"$TMP/dw-review-symlink.err"; rc=$?
[ "$rc" -eq 0 ] || fail "symlinked review dispatch should exit 0, got $rc: $(cat "$TMP/dw-review-symlink.err")"
grep -q 'READ-ONLY REVIEW MODE' "$TMP/dw-review-symlink.out" || fail "symlinked review dispatch did not send review brief"
grep -q 'agy-auth-probe.sh: No such file' "$TMP/dw-review-symlink.err" && fail "symlinked dispatch resolved helper from symlink dir"
assert_called "models"
assert_no_rejected_agy_args
echo "test 6b (dispatch_agy review symlink resolves helper) PASS"

# 7. dispatch non-review: build dispatch uses the same live auth probe as review.
reset_calls
rm -rf "$HOME/.gemini"
AGY_STUB_MODE=dead TIMEOUT=0 "$DW" --runtime agy --brief "$BRIEF" --workdir /repo/x >"$TMP/dw-edit-nocreds.out" 2>"$TMP/dw-edit-nocreds.err"; rc=$?
[ "$rc" -eq 7 ] || fail "non-review dead live auth should return 7, got $rc"
grep -qi 're-authenticate agy' "$TMP/dw-edit-nocreds.err" || fail "non-review dead auth should tell user to re-authenticate agy"
assert_called "models"
assert_no_rejected_agy_args

reset_calls
AGY_STUB_MODE=healthy TIMEOUT=0 "$DW" --runtime agy --brief "$BRIEF" --workdir /repo/x >"$TMP/dw-edit-healthy.out" 2>"$TMP/dw-edit-healthy.err"; rc=$?
[ "$rc" -eq 0 ] || fail "non-review healthy live auth should proceed, got $rc"
assert_called "models"
assert_no_rejected_agy_args
echo "test 7 (dispatch_agy non-review live auth and bare stdin) PASS"

echo "ALL PASS"
