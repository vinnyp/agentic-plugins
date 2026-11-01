#!/usr/bin/env bash
set -uo pipefail

SELF_DIR="$IMPL_BIN"

AGY_MODEL_CODING_DEFAULT=gemini-3.8-flash-medium
AGY_MODEL_REVIEW_DEFAULT=gemini-4-argon-high
export AGY_TEST_CODING_PIN="$AGY_MODEL_CODING_DEFAULT" AGY_TEST_REVIEW_PIN="$AGY_MODEL_REVIEW_DEFAULT"
PREFLIGHT="$SELF_DIR/coding-preflight.sh"
DW="$SELF_DIR/dispatch-worker"
TMP="$SCN_TMP/fixture"
mkdir -p "$TMP"


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
    if [ -n "${AGY_MODELS_FILE:-}" ]; then cat "$AGY_MODELS_FILE"; exit 0; fi
    case "${AGY_STUB_MODE:-healthy}" in
      unparseable) echo 'format drift'; exit 0 ;;
      review_missing) printf '%s\tCoding\r\ncustom-id\tCustom Display\r\ncustom-id-high\tTiered\r\n' "$AGY_TEST_CODING_PIN"; exit 0 ;;
      missing) printf 'custom-id\tCustom Display\n'; exit 0 ;;
      healthy)
        printf '%s\tGemini 3.8 Flash (Medium)\n%s\tGemini 4 Argon (High)\ncustom-id\tCustom Display\n' "$AGY_TEST_CODING_PIN" "$AGY_TEST_REVIEW_PIN"
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
        exit 98
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
printf '%s\n' "$*" >> "$AGY_CALL_LOG.timeout"
[ "${1:-}" != -k ] || shift 2
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

# Public readiness outcomes replace private probe return codes.
public_auth_check() { "$PREFLIGHT" agy; }

reset_calls
AGY_STUB_MODE=network public_auth_check >"$TMP/probe-network.out" 2>"$TMP/probe-network.err"; rc=$?
[ "$rc" -eq 0 ] || fail "network probe should proceed with public rc0, got $rc"
assert_called "models"
grep -qE '^-k 2s 5s .*agy models$' "$AGY_CALL_LOG.timeout" || fail "auth timeout argv"
echo "test probe 1 (network error advisory) PASS"

reset_calls
AGY_STUB_MODE=unknown public_auth_check >"$TMP/probe-unknown.out" 2>"$TMP/probe-unknown.err"; rc=$?
[ "$rc" -eq 0 ] || fail "unknown non-zero probe should proceed with public rc0, got $rc"
assert_called "models"
echo "test probe 2 (unknown non-zero advisory) PASS"

reset_calls
rm -rf "$HOME/.gemini"
AGY_STUB_MODE=healthy public_auth_check >"$TMP/probe-no-creds-healthy.out" 2>"$TMP/probe-no-creds-healthy.err"; rc=$?
[ "$rc" -eq 0 ] || fail "absent creds + healthy live models should return rc0, got $rc"
assert_called "models"
echo "test probe 3 (absent creds ignored; live models healthy) PASS"

reset_calls
AGY_STUB_MODE=dead_antigravity public_auth_check >"$TMP/probe-antigravity-dead.out" 2>"$TMP/probe-antigravity-dead.err"; rc=$?
[ "$rc" -eq 1 ] || fail "'not logged into Antigravity' should hard-block public readiness with rc1, got $rc"
assert_called "models"
echo "test probe 4 (not logged into Antigravity -> preflight rc1) PASS"

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

# Review authentication failure is covered by worker-agy-auth.

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

# Missing coding pin and both supported override forms.
AGY_STUB_MODE=missing "$PREFLIGHT" agy >"$TMP/missing.out" 2>&1; rc=$?
[ "$rc" -eq 1 ] || fail "missing coding default should fail rc1"
grep -qF "PREFLIGHT=error: agy model '$AGY_MODEL_CODING_DEFAULT'" "$TMP/missing.out" || fail "missing coding diagnostic lacks ID"
for model in custom-id 'Custom Display'; do
  AGY_STUB_MODE=missing AGY_MODEL="$model" "$PREFLIGHT" agy >"$TMP/override.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "offered override $model should pass"
  grep -qFx "CODING_MODEL=$model" "$TMP/override.out" || fail "effective coding model not reported"
done

# Model parsing is exercised through the published model check.
export AGY_MODELS_FILE="$TMP/model-list"
printf 'id-one\tDisplay One\tignored\r\n' > "$AGY_MODELS_FILE"
for model in id-one 'Display One' 'display one' ID-ONE id; do
  AGY_MODEL="$model" "$PREFLIGHT" agy > "$TMP/parser.out" 2> "$TMP/parser.err"; rc=$?
  [ "$rc" -eq 0 ] || fail "model rejected: $model"
  grep -q '^AGY_MODEL_CHECK=ok$' "$TMP/parser.out" || fail 'model check missing'
  if [ "$model" = id ]; then grep -q 'has no tier' "$TMP/parser.err" || fail 'tier warning'; fi
done
for model in Display ignored '   ' "$(printf 'bad\nmodel')" "$(printf 'bad\tmodel')" 'literal\nmodel'; do
  AGY_MODEL="$model" "$PREFLIGHT" agy > "$TMP/parser.out" 2> "$TMP/parser.err"; rc=$?
  [ "$rc" -eq 1 ] || fail "invalid model accepted: $model"
done
printf 'format drift\n' > "$AGY_MODELS_FILE"
for model in '   ' "$(printf '\n.')" "$(printf '\t')"; do
  AGY_MODEL="$model" "$PREFLIGHT" agy > "$TMP/parser.out" 2> "$TMP/parser.err"; rc=$?
  [ "$rc" -eq 1 ] || fail 'invalid unparseable model accepted'
done
AGY_MODEL=id-one "$PREFLIGHT" agy > "$TMP/parser.out" 2> "$TMP/parser.err"; rc=$?
[ "$rc" -eq 0 ] || fail 'unparseable models blocked'
grep -q '^AGY_MODEL_CHECK=skipped:unparseable models$' "$TMP/parser.out" || fail 'unparseable status'
unset AGY_MODELS_FILE

grep -qFx "CODING_MODEL=$AGY_MODEL_CODING_DEFAULT" "$TMP/preflight-healthy.out" || fail "default coding model missing"
grep -qFx 'AGY_MODEL_CHECK=ok' "$TMP/preflight-healthy.out" || fail "check status missing"
grep -qF -- "--model $AGY_MODEL_CODING_DEFAULT" "$TMP/preflight-healthy.out" || fail "invoke lacks model"
AGY_STUB_MODE=healthy AGY_MODEL=bogus "$PREFLIGHT" agy >"$TMP/bogus.out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q "PREFLIGHT=error: agy model 'bogus'" "$TMP/bogus.out" || fail "bogus preflight override accepted"
for mode in network unparseable review_missing; do
  AGY_STUB_MODE="$mode" "$PREFLIGHT" agy >"$TMP/check.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "preflight $mode should proceed"
  if [ "$mode" != review_missing ]; then grep -q 'AGY_MODEL_CHECK=skipped:' "$TMP/check.out" || fail "skip not reported"; fi
done
for model in 'custom display' custom-id; do
  AGY_STUB_MODE=review_missing AGY_MODEL="$model" "$PREFLIGHT" agy >"$TMP/name.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "name form rejected: $model"
done
export AGY_MODELS_FILE="$TMP/model-list"
printf 'gemini-4-argon-high\tGemini Argon\ncustom-id-high\tCustom\n' > "$AGY_MODELS_FILE"
for model in gemini gemini-4; do
  AGY_MODEL="$model" "$PREFLIGHT" agy > "$TMP/family.out" 2>&1; rc=$?
  [ "$rc" -eq 1 ] || fail "family prefix accepted: $model"
done
unset AGY_MODELS_FILE
# All review tests use this suite's isolated workdir.
for mode in network unparseable review_missing healthy; do
  : >"$AGY_CALL_LOG"
  AGY_STUB_MODE="$mode" AGY_MODEL_REVIEW_DEFAULT=bogus DISPATCH_MIN_REVIEW_BYTES=1 DISPATCH_REVIEW_REQUIRE_EVIDENCE=0 TIMEOUT=0 "$DW" --runtime agy --review --brief "$BRIEF" --workdir "$REVIEW_WORKDIR" >"$TMP/review.out" 2>"$TMP/review.err"; rc=$?
  if [ "$mode" = review_missing ]; then
    [ "$rc" -eq 9 ] || fail "missing review pin should return 9: $rc"
    [ "$(wc -l <"$AGY_CALL_LOG" | tr -d ' ')" -eq 1 ] || fail "missing pin dispatched"
  else
    [ "$rc" -eq 0 ] || fail "review $mode should dispatch: $rc"
    grep -qF "agy model: $AGY_MODEL_REVIEW_DEFAULT (review, default)" "$TMP/review.err" || fail "pin overridden or source diagnostic missing"
    if [ "$mode" != healthy ]; then grep -q 'skipping model check' "$TMP/review.err" || fail "worker skip note missing"; fi
  fi
done
AGY_STUB_MODE=review_missing TIMEOUT=0 "$DW" --runtime agy --brief "$BRIEF" --workdir "$REVIEW_WORKDIR" >"$TMP/edit.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] || fail "review-only missing pin blocked edit"
: >"$AGY_CALL_LOG"
AGY_STUB_MODE=healthy TIMEOUT=0 "$DW" --runtime agy --model bogus --brief "$BRIEF" --workdir "$REVIEW_WORKDIR" >"$TMP/dw-bogus.out" 2>&1; rc=$?
[ "$rc" -eq 9 ] || fail "bogus worker override should return 9"
[ "$(wc -l <"$AGY_CALL_LOG" | tr -d ' ')" -eq 1 ] || fail "bogus worker override dispatched"
grep -qF -- '--model/MODEL' "$TMP/dw-bogus.out" || fail "override source missing"
for model in 'custom display' custom-id; do
  AGY_STUB_MODE=review_missing TIMEOUT=0 "$DW" --runtime agy --model "$model" --brief "$BRIEF" --workdir "$REVIEW_WORKDIR" >"$TMP/dw-name.out" 2>&1; rc=$?
  [ "$rc" -eq 0 ] || fail "worker rejected name form $model"
  if [ "$model" = custom-id ]; then grep -q 'has no tier' "$TMP/dw-name.out" && fail "exact ID should win over tierless prefix"; fi
done
AGY_STUB_MODE=review_missing TIMEOUT=0 "$DW" --runtime agy --model custom --brief "$BRIEF" --workdir "$REVIEW_WORKDIR" >"$TMP/dw-tier.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q 'has no tier' "$TMP/dw-tier.out" || fail "worker tierless override/warning failed"
mkdir -p "$TMP/broken-install"
cp "$DW" "$TMP/broken-install/dispatch-worker"
"$TMP/broken-install/dispatch-worker" --help >"$TMP/broken.out" 2>&1; rc=$?
[ "$rc" -eq 3 ] && grep -q 'broken install' "$TMP/broken.out" || fail "missing worker model library diagnostic"
echo "ALL PASS"
