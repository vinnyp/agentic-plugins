#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CD="$SCRIPT_DIR/coding-dispatch.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/hash.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
wd=""
while [ $# -gt 0 ]; do
  [ "$1" = "-C" ] && { wd="$2"; shift 2; continue; }
  shift
done
: "${wd:=$PWD}"
printf 'agent change\n' > "$wd/agent_made_this.txt"
STUB
chmod +x "$TMP/bin/codex"

# Make the fetch bound deterministic on platforms with either timeout implementation.
cat > "$TMP/bin/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TIMEOUT_LOG:?}"
while [ $# -gt 0 ]; do
  case "$1" in
    -k) shift 2 ;;
    [0-9]*[smh]) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
STUB
chmod +x "$TMP/bin/timeout"

init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "Dispatch Freshness Test"
  git -C "$dir" checkout -q -b main
  printf 'base\n' > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -q -m base
}

init_remote_repo() {
  local repo="$1" remote="$2"
  init_repo "$repo"
  git init -q --bare "$remote"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q -u origin main
  git -C "$remote" symbolic-ref HEAD refs/heads/main
}

advance_remote() {
  local remote="$1" checkout="$2"
  git clone -q "$remote" "$checkout"
  git -C "$checkout" config user.email test@example.invalid
  git -C "$checkout" config user.name "Dispatch Freshness Test"
  printf 'remote ahead\n' >> "$checkout/file.txt"
  git -C "$checkout" add file.txt
  git -C "$checkout" commit -q -m remote-ahead
  git -C "$checkout" push -q origin main
}

expected_wt() {
  local p="$1" slug="$2" p_real p_bn p_hash
  p_real="$(cd "$p" && git rev-parse --show-toplevel)"
  p_bn=$(basename "$p_real" | tr -cs 'A-Za-z0-9_-' '_')
  if command -v md5sum >/dev/null 2>&1; then
    p_hash=$(printf '%s' "$p_real" | md5sum | cut -c1-8)
  else
    p_hash=$(printf '%s' "$p_real" | md5_hex | cut -c1-8)
  fi
  printf '%s/.worktrees/%s_%s/%s\n' "$(cd "$p_real/.." && pwd -P)" "$p_bn" "$p_hash" "$slug"
}

run_dispatch() {
  local output="$1" slug="$2" repo="$3"
  shift 3
  set +e
  PATH="$TMP/bin:$PATH" TIMEOUT_LOG="$TMP/timeout.log" \
    CODING_DISPATCH_WORKTREE="$slug" bash "$CD" --worktree "$@" codex "$repo" "$TMP/prompt" "true" >"$output" 2>&1
  RUN_RC=$?
  set -e
}

remove_wt() {
  local repo="$1" slug="$2" wt
  wt="$(expected_wt "$repo" "$slug")"
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
}

printf 'do the task\n' > "$TMP/prompt"
: > "$TMP/timeout.log"

echo "Running Test a: fetch sees a remote commit absent from the on-disk tracking ref and dies..."
REPO_A="$TMP/repo-a"; REMOTE_A="$TMP/remote-a.git"
init_remote_repo "$REPO_A" "$REMOTE_A" || fail "could not initialize repo A"
base_a="$(git -C "$REPO_A" rev-parse HEAD)"
advance_remote "$REMOTE_A" "$TMP/updater-a" || fail "could not advance remote A"
[ "$(git -C "$REPO_A" rev-parse origin/main)" = "$base_a" ] || fail "case a requires a stale on-disk tracking ref"
run_dispatch "$TMP/out-a" freshFetch "$REPO_A"
[ "$RUN_RC" -eq 2 ] || { cat "$TMP/out-a"; fail "stale fetched base should die with rc 2, got $RUN_RC"; }
grep -q "DISPATCH_BASE_STALE .*comparison=fetched" "$TMP/out-a" || { cat "$TMP/out-a"; fail "fetched remote staleness should be reported"; }
grep -q '^5s git fetch --quiet origin refs/heads/main:refs/remotes/origin/main$' "$TMP/timeout.log" || { cat "$TMP/timeout.log"; fail "fetch must be wrapped in a five-second timeout"; }
echo "Test a PASS"

echo "Running Test b: failed fetch is visible, last-fetched, and non-fatal..."
REPO_B="$TMP/repo-b"; REMOTE_B="$TMP/remote-b.git"
init_remote_repo "$REPO_B" "$REMOTE_B" || fail "could not initialize repo B"
git -C "$REPO_B" remote set-url origin "$TMP/does-not-exist.git"
run_dispatch "$TMP/out-b" failedFetch "$REPO_B"
[ "$RUN_RC" -eq 0 ] || { cat "$TMP/out-b"; fail "fetch failure should not stop dispatch, got $RUN_RC"; }
grep -q 'DISPATCH_BASE_FETCH .*status=failed' "$TMP/out-b" || { cat "$TMP/out-b"; fail "fetch failure should emit a visible note"; }
grep -q 'DISPATCH_BASE_TRACKING .*status=not-behind comparison=last-fetched' "$TMP/out-b" || { cat "$TMP/out-b"; fail "fetch failure must use last-fetched comparison label"; }
remove_wt "$REPO_B" failedFetch
echo "Test b PASS"

echo "Running Test c: successful fetch on a current base reports fetched..."
REPO_C="$TMP/repo-c"; REMOTE_C="$TMP/remote-c.git"
init_remote_repo "$REPO_C" "$REMOTE_C" || fail "could not initialize repo C"
run_dispatch "$TMP/out-c" currentFetch "$REPO_C"
[ "$RUN_RC" -eq 0 ] || { cat "$TMP/out-c"; fail "current fetched base should dispatch, got $RUN_RC"; }
grep -q 'DISPATCH_BASE_TRACKING .*status=not-behind comparison=fetched' "$TMP/out-c" || { cat "$TMP/out-c"; fail "successful fetch should report comparison=fetched"; }
! grep -q 'DISPATCH=error:' "$TMP/out-c" || { cat "$TMP/out-c"; fail "current fetched base should not die"; }
remove_wt "$REPO_C" currentFetch
echo "Test c PASS"

echo "Running Test d: origin/branch fallback runs without configured upstream..."
REPO_D="$TMP/repo-d"; REMOTE_D="$TMP/remote-d.git"
init_repo "$REPO_D" || fail "could not initialize repo D"
git init -q --bare "$REMOTE_D"
git -C "$REPO_D" remote add origin "$REMOTE_D"
git -C "$REPO_D" push -q origin main
[ -z "$(git -C "$REPO_D" for-each-ref --format='%(upstream:short)' refs/heads/main)" ] || fail "case d requires no configured upstream"
run_dispatch "$TMP/out-d" fallbackOrigin "$REPO_D"
[ "$RUN_RC" -eq 0 ] || { cat "$TMP/out-d"; fail "origin fallback should dispatch, got $RUN_RC"; }
grep -q 'DISPATCH_BASE_TRACKING .*tracking_ref=origin/main status=not-behind comparison=fetched' "$TMP/out-d" || { cat "$TMP/out-d"; fail "origin/main fallback should run the check"; }
! grep -q 'status=no-upstream' "$TMP/out-d" || { cat "$TMP/out-d"; fail "origin/main fallback must not report no-upstream"; }
remove_wt "$REPO_D" fallbackOrigin
echo "Test d PASS"

echo "Running Test e: --allow-stale-base overrides fetched staleness..."
REPO_E="$TMP/repo-e"; REMOTE_E="$TMP/remote-e.git"
init_remote_repo "$REPO_E" "$REMOTE_E" || fail "could not initialize repo E"
advance_remote "$REMOTE_E" "$TMP/updater-e" || fail "could not advance remote E"
run_dispatch "$TMP/out-e" allowedStale "$REPO_E" --allow-stale-base
[ "$RUN_RC" -eq 0 ] || { cat "$TMP/out-e"; fail "--allow-stale-base should override stale base, got $RUN_RC"; }
grep -q 'DISPATCH_BASE_STALE .*comparison=fetched' "$TMP/out-e" || { cat "$TMP/out-e"; fail "allowed stale base should still be reported"; }
remove_wt "$REPO_E" allowedStale
echo "Test e PASS"

echo "Running Test f: detached base_ref=HEAD carve-out skips cleanly..."
REPO_F="$TMP/repo-f"
init_repo "$REPO_F" || fail "could not initialize repo F"
git -C "$REPO_F" checkout -q --detach
run_dispatch "$TMP/out-f" detachedHead "$REPO_F" --base HEAD
[ "$RUN_RC" -eq 0 ] || { cat "$TMP/out-f"; fail "detached HEAD base should dispatch, got $RUN_RC"; }
grep -q 'DISPATCH_BASE_TRACKING base_ref=HEAD status=no-upstream' "$TMP/out-f" || { cat "$TMP/out-f"; fail "detached HEAD should skip tracking cleanly"; }
! grep -q 'git fetch' "$TMP/out-f" || { cat "$TMP/out-f"; fail "detached HEAD carve-out should not fetch"; }
remove_wt "$REPO_F" detachedHead
echo "Test f PASS"

echo "ALL TESTS PASSED SUCCESSFULLY"
