#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/gate-run.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q || return 1
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "Gate Run Test"
  printf 'initial\n' > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -q -m initial
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REPO_A="$TMP_DIR/repo-a"
REPO_B="$TMP_DIR/repo-b"
init_repo "$REPO_A" || fail "could not initialize repo A"
init_repo "$REPO_B" || fail "could not initialize repo B"
TOP_A="$(git -C "$REPO_A" rev-parse --show-toplevel)"
TOP_B="$(git -C "$REPO_B" rev-parse --show-toplevel)"

echo "Running Test 1: moved tree is stamped from inside the command shell..."
set +e
OUT=$(cd "$REPO_A" && "$RUNNER" --expect-root "$REPO_A" -- "cd '$REPO_B' && true" 2>&1)
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "moved tree exited $RC instead of 2; output: $OUT"
printf '%s\n' "$OUT" | grep -q "GATE_TREE_POST .*top=$TOP_B" || fail "POST stamp did not name repo B; output: $OUT"
printf '%s\n' "$OUT" | grep -q "GATE_TREE_MOVED .*pre_top=$TOP_A .*post_top=$TOP_B" || fail "missing moved verdict; output: $OUT"
echo "Test 1 PASS"

echo "Running Test 2: passing command in expected tree passes through 0..."
set +e
OUT=$(cd "$REPO_A" && "$RUNNER" --expect-root "$REPO_A" -- "true" 2>&1)
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "passing command exited $RC instead of 0; output: $OUT"
printf '%s\n' "$OUT" | grep -q "GATE_TREE_POST .*top=$TOP_A .*code=0" || fail "missing passing POST stamp; output: $OUT"
echo "Test 2 PASS"

echo "Running Test 3: failing command in expected tree passes through its code..."
set +e
OUT=$(cd "$REPO_A" && "$RUNNER" --expect-root "$REPO_A" -- "exit 7" 2>&1)
RC=$?
set -e
[ "$RC" -eq 7 ] || fail "failing command exited $RC instead of 7; output: $OUT"
printf '%s\n' "$OUT" | grep -q "GATE_TREE_POST .*top=$TOP_A .*code=7" || fail "missing failing POST stamp; output: $OUT"
echo "Test 3 PASS"

echo "Running Test 4: advancing HEAD is stamped but not rejected..."
set +e
OUT=$(cd "$REPO_A" && "$RUNNER" --expect-root "$REPO_A" -- "printf changed > file.txt && git add file.txt && git commit -q -m changed" 2>&1)
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "HEAD-advancing command exited $RC instead of 0; output: $OUT"
printf '%s\n' "$OUT" | grep -q "GATE_TREE_POST .*top=$TOP_A .*code=0" || fail "missing HEAD-advance POST stamp; output: $OUT"
PRE_HEAD=$(printf '%s\n' "$OUT" | sed -n 's/^GATE_TREE_PRE .*head=\([^ ]*\).*$/\1/p' | tail -1)
POST_HEAD=$(printf '%s\n' "$OUT" | sed -n 's/^GATE_TREE_POST .*head=\([^ ]*\).*$/\1/p' | tail -1)
[ -n "$PRE_HEAD" ] && [ -n "$POST_HEAD" ] || fail "could not parse HEAD stamps; output: $OUT"
[ "$PRE_HEAD" != "$POST_HEAD" ] || fail "HEAD did not advance in stamps; output: $OUT"
echo "Test 4 PASS"

echo "Running Test 5: command without --expect-root stamps and preserves rc..."
set +e
OUT=$(cd "$REPO_A" && "$RUNNER" -- "true" 2>&1)
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "no-expect command exited $RC instead of 0; output: $OUT"
printf '%s\n' "$OUT" | grep -q "GATE_TREE_POST .*top=$TOP_A .*code=0" || fail "missing no-expect POST stamp; output: $OUT"
printf '%s\n' "$OUT" | grep -q "GATE_TREE_UNTRUSTWORTHY" && fail "no-expect command should not enforce a root; output: $OUT"
echo "Test 5 PASS"

echo "Running Test 6: --expect-head is rejected..."
set +e
OUT=$(cd "$REPO_A" && "$RUNNER" --expect-head "$PRE_HEAD" -- "true" 2>&1)
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "--expect-head exited $RC instead of 2; output: $OUT"
printf '%s\n' "$OUT" | grep -q "usage: gate-run.sh" || fail "--expect-head should be rejected by usage gate; output: $OUT"
echo "Test 6 PASS"

# ============================ #180: venv-pinned gate + disclosure ============================
# A fake <workdir>/.venv/bin/ruff shim, distinct from anything on the real PATH, so a resolve
# against it (rather than some other ruff) proves the prepend actually happened.
REPO_VENV="$TMP_DIR/repo-venv"
init_repo "$REPO_VENV" || fail "could not initialize repo for venv test"
mkdir -p "$REPO_VENV/.venv/bin"
cat > "$REPO_VENV/.venv/bin/ruff" <<'RUFF'
#!/usr/bin/env bash
echo "ruff 0.15.16-fixture"
RUFF
chmod +x "$REPO_VENV/.venv/bin/ruff"
RESOLVE_RUFF_CMD='p="$(command -v ruff || true)"; printf "ruff_path=%s" "$p"'

echo "Running Test 7: <workdir>/.venv/bin/ruff shim is resolved by the gate child and named in the gate-env line..."
set +e
OUT=$(cd "$REPO_VENV" && "$RUNNER" --expect-root "$REPO_VENV" -- "$RESOLVE_RUFF_CMD" 2>&1)
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "venv ruff shim run failed rc=$RC; output: $OUT"
printf '%s\n' "$OUT" | grep -qF "ruff_path=$REPO_VENV/.venv/bin/ruff" || fail "gate child's command -v ruff did not resolve to the workdir venv shim; output: $OUT"
printf '%s\n' "$OUT" | grep -qF "ruff=$REPO_VENV/.venv/bin/ruff ruff 0.15.16-fixture" || fail "gate-env line did not name the venv ruff shim with its version; output: $OUT"
echo "Test 7 PASS"

echo "Running Test 8: no .venv leaves PATH unchanged and still prints the gate-env line..."
set +e
OUT=$(cd "$REPO_A" && "$RUNNER" --expect-root "$REPO_A" -- 'printf "child_path=%s" "$PATH"' 2>&1)
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "no-venv gate run failed rc=$RC; output: $OUT"
printf '%s\n' "$OUT" | grep -qF "child_path=$PATH" || fail "PATH should be unchanged when the workdir has no .venv; output: $OUT"
printf '%s\n' "$OUT" | grep -qE '^gate-env: python=' || fail "gate-env line should still print when the workdir has no .venv; output: $OUT"
echo "Test 8 PASS"

echo "Running Test 9: --no-venv restores the inherited PATH even when the workdir has a .venv..."
set +e
OUT=$(cd "$REPO_VENV" && "$RUNNER" --expect-root "$REPO_VENV" --no-venv -- "$RESOLVE_RUFF_CMD" 2>&1)
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "--no-venv gate run failed rc=$RC; output: $OUT"
printf '%s\n' "$OUT" | grep -qF "ruff_path=$REPO_VENV/.venv/bin/ruff" && fail "--no-venv should not resolve ruff via the workdir venv; output: $OUT"
printf '%s\n' "$OUT" | grep -qF "ruff=$REPO_VENV/.venv/bin/ruff" && fail "--no-venv gate-env line should not name the workdir venv ruff; output: $OUT"
printf '%s\n' "$OUT" | grep -qE '^gate-env: python=' || fail "gate-env line should still print under --no-venv; output: $OUT"
echo "Test 9 PASS"

echo "Running Test 10: DISPATCH_NO_VENV=1 env is equivalent to --no-venv..."
set +e
OUT=$(cd "$REPO_VENV" && DISPATCH_NO_VENV=1 "$RUNNER" --expect-root "$REPO_VENV" -- "$RESOLVE_RUFF_CMD" 2>&1)
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "DISPATCH_NO_VENV=1 gate run failed rc=$RC; output: $OUT"
printf '%s\n' "$OUT" | grep -qF "ruff_path=$REPO_VENV/.venv/bin/ruff" && fail "DISPATCH_NO_VENV=1 should not resolve ruff via the workdir venv; output: $OUT"
echo "Test 10 PASS"

echo "ALL TESTS PASSED SUCCESSFULLY"
