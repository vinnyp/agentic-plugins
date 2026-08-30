#!/usr/bin/env bash
# test-review-pin.sh — acceptance tests for review-pin.sh.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
# shellcheck disable=SC1091
. "$SELF_DIR/lib/test-env-reset.sh"
reset_dispatch_env  # neutralize any operator-exported dispatch vars before the suite runs
RP="$SELF_DIR/review-pin.sh"
fail() { echo "FAIL: $1"; exit 1; }

new_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'base\n' > "$repo/tracked.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
}

marker_for() {
  local workdir="$1"
  printf '%s/review-pinned\n' "$(git -C "$workdir" rev-parse --absolute-git-dir)"
}

# ---------------------------------------------------------------------------
# Test 1: pin then status -> exit 0, output contains the pinned SHA.
# ---------------------------------------------------------------------------
REPO1="$TMP/repo1"; new_repo "$REPO1"
sha1="$(git -C "$REPO1" rev-parse HEAD)"
bash "$RP" pin "$REPO1" --label "review one" >"$TMP/out1_pin" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out1_pin"; fail "pin should exit 0, got $rc"; }
bash "$RP" status "$REPO1" >"$TMP/out1_status" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out1_status"; fail "status should exit 0 for active pin, got $rc"; }
grep -q "sha=$sha1" "$TMP/out1_status" || { cat "$TMP/out1_status"; fail "status should contain pinned SHA"; }
echo "test pin then status reports pinned SHA PASS"

# ---------------------------------------------------------------------------
# Test 2: pin on an already-pinned tree -> exit 2 and marker byte-identical.
# ---------------------------------------------------------------------------
REPO2="$TMP/repo2"; new_repo "$REPO2"
bash "$RP" pin "$REPO2" --label "first" >"$TMP/out2_first" 2>&1 || { cat "$TMP/out2_first"; fail "setup pin failed"; }
marker2="$(marker_for "$REPO2")"
before2="$(cat "$marker2")"
bash "$RP" pin "$REPO2" --label "second" >"$TMP/out2_second" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out2_second"; fail "second pin should exit 2, got $rc"; }
[ "$(cat "$marker2")" = "$before2" ] || fail "existing marker was overwritten by second pin"
echo "test duplicate active pin exits 2 and preserves marker bytes PASS"

# ---------------------------------------------------------------------------
# Test 3: release on an absent pin -> exit 0.
# ---------------------------------------------------------------------------
REPO3="$TMP/repo3"; new_repo "$REPO3"
bash "$RP" release "$REPO3" >"$TMP/out3" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out3"; fail "release absent pin should exit 0, got $rc"; }
echo "test release absent pin is idempotent PASS"

# ---------------------------------------------------------------------------
# Test 4: pin marker must not dirty git status.
# ---------------------------------------------------------------------------
REPO4="$TMP/repo4"; new_repo "$REPO4"
bash "$RP" pin "$REPO4" >"$TMP/out4" 2>&1 || { cat "$TMP/out4"; fail "pin for clean-status test failed"; }
[ -z "$(git -C "$REPO4" status --porcelain)" ] || fail "pin marker dirtied git status"
echo "test pin marker is invisible to git status PASS"

# ---------------------------------------------------------------------------
# Test 5: linked worktree marker is private to the linked worktree git-dir.
# ---------------------------------------------------------------------------
MAIN5="$TMP/main5"; new_repo "$MAIN5"
LINK5="$TMP/link5"
git -C "$MAIN5" worktree add -q "$LINK5" -b review-link
bash "$RP" pin "$LINK5" --label "linked" >"$TMP/out5_pin" 2>&1 || { cat "$TMP/out5_pin"; fail "linked worktree pin failed"; }
bash "$RP" status "$LINK5" >"$TMP/out5_link_status" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out5_link_status"; fail "linked worktree status should see its pin, got $rc"; }
bash "$RP" status "$MAIN5" >"$TMP/out5_main_status" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out5_main_status"; fail "main checkout status should not see linked pin, got $rc"; }
echo "test linked worktree pin is not shared with main checkout PASS"

# ---------------------------------------------------------------------------
# Test 6: pin invoked outside a git repo -> exit 2.
# ---------------------------------------------------------------------------
NOREPO6="$TMP/not-a-repo"; mkdir -p "$NOREPO6"
bash "$RP" pin "$NOREPO6" >"$TMP/out6" 2>&1
rc=$?
[ "$rc" -eq 2 ] || { cat "$TMP/out6"; fail "pin outside git repo should exit 2, got $rc"; }
grep -qi "not a git repo" "$TMP/out6" || { cat "$TMP/out6"; fail "non-repo failure should be clear"; }
echo "test pin outside git repo exits 2 PASS"

# ---------------------------------------------------------------------------
# Test 7: stale pin status -> exit 1, mentions stale, removes marker.
# ---------------------------------------------------------------------------
REPO7="$TMP/repo7"; new_repo "$REPO7"
marker7="$(marker_for "$REPO7")"
sha7="$(git -C "$REPO7" rev-parse HEAD)"
old7="$(($(date +%s) - 1000))"
{
  printf 'sha=%s\n' "$sha7"
  printf 'pinned_at=%s\n' "$old7"
  printf 'pid=12345\n'
  printf 'label=old\n'
} > "$marker7"
DISPATCH_REVIEW_PIN_TTL_SECS=1 bash "$RP" status "$REPO7" >"$TMP/out7" 2>&1
rc=$?
[ "$rc" -eq 1 ] || { cat "$TMP/out7"; fail "stale status should exit 1, got $rc"; }
grep -qi "stale" "$TMP/out7" || { cat "$TMP/out7"; fail "stale status should mention stale"; }
[ ! -e "$marker7" ] || fail "stale marker was not removed"
echo "test stale status removes marker and exits 1 PASS"

# ---------------------------------------------------------------------------
# Test 8: very large TTL keeps a non-stale pin active.
# ---------------------------------------------------------------------------
REPO8="$TMP/repo8"; new_repo "$REPO8"
bash "$RP" pin "$REPO8" >"$TMP/out8_pin" 2>&1 || { cat "$TMP/out8_pin"; fail "pin for TTL test failed"; }
DISPATCH_REVIEW_PIN_TTL_SECS=999999999 bash "$RP" status "$REPO8" >"$TMP/out8_status" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out8_status"; fail "large TTL active status should exit 0, got $rc"; }
echo "test large TTL leaves non-stale pin active PASS"

# ---------------------------------------------------------------------------
# Test 9: pin from a different cwd still writes into the workdir git-dir.
# ---------------------------------------------------------------------------
REPO9="$TMP/repo9"; new_repo "$REPO9"
marker9="$(marker_for "$REPO9")"
CALLER9="$TMP/caller9"; mkdir -p "$CALLER9"
(
  cd "$CALLER9" || exit 1
  bash "$RP" pin "$REPO9" --label "different cwd" >"$TMP/out9_pin" 2>&1
)
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out9_pin"; fail "pin from different cwd should exit 0, got $rc"; }
[ -f "$marker9" ] || fail "pin from different cwd did not write marker into workdir git-dir"
[ ! -e "$CALLER9/.git/review-pinned" ] || fail "pin from different cwd wrote marker under caller cwd"
bash "$RP" status "$REPO9" >"$TMP/out9_status" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out9_status"; fail "status should see pin created from different cwd, got $rc"; }
echo "test pin from different cwd writes into workdir git-dir PASS"
