#!/usr/bin/env bash
# test-review-pin.sh — acceptance tests for review-pin.sh.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SELF_DIR/lib/timeout-bin.sh"
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

# ---------------------------------------------------------------------------
# Test 10: bare invocation through an absolute symlink can find its helpers.
# ---------------------------------------------------------------------------
REPO10="$TMP/repo10"; new_repo "$REPO10"
mkdir "$TMP/bin10"
ln -s "$RP" "$TMP/bin10/review-pin.sh"
bash "$RP" pin "$REPO10" >"$TMP/out10_pin" 2>&1 || { cat "$TMP/out10_pin"; fail "setup pin for symlink failed"; }
PATH="$TMP/bin10:$PATH" review-pin.sh status "$REPO10" >"$TMP/out10_status" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out10_status"; fail "bare via symlink should exit 0, got $rc"; }
echo "test bare via symlink PASS"

# ---------------------------------------------------------------------------
# Test 11: the second link in a symlink chain resolves relative to its directory.
# ---------------------------------------------------------------------------
mkdir "$TMP/bin11" "$TMP/links11"
ln -s "$SELF_DIR" "$TMP/links11/source"
ln -s "source/review-pin.sh" "$TMP/links11/review-pin.sh"
ln -s "$TMP/links11/review-pin.sh" "$TMP/bin11/review-pin.sh"
PATH="$TMP/bin11:$PATH" review-pin.sh status "$REPO10" >"$TMP/out11_status" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out11_status"; fail "relative symlink chain should exit 0, got $rc"; }
echo "test relative symlink chain PASS"

# ---------------------------------------------------------------------------
# Test 12: release through the link removes the pinned marker.
# ---------------------------------------------------------------------------
marker10="$(marker_for "$REPO10")"
PATH="$TMP/bin10:$PATH" review-pin.sh release "$REPO10" >"$TMP/out12_release" 2>&1
rc=$?
[ "$rc" -eq 0 ] || { cat "$TMP/out12_release"; fail "release via symlink should exit 0, got $rc"; }
[ ! -e "$marker10" ] || fail "release via symlink did not remove marker"
echo "test release via symlink PASS"

# Resolved-marker mode does not consult git and records the invoking process.
mkdir "$TMP/no-git"
cat > "$TMP/no-git/git" <<'STUB'
#!/usr/bin/env bash
printf called > "$PIN_GIT_CALLED"
exit 99
STUB
chmod +x "$TMP/no-git/git"
export PIN_GIT_CALLED="$TMP/git-called"
PATH="$TMP/no-git:$PATH" bash -c 'printf "%s\n" "$$" > "$1"; exec bash "$2" pin --marker "$3" --sha abc' _ "$TMP/pin-pid" "$RP" "$TMP/direct-marker" > "$TMP/direct.out" 2>&1
[ "$?" = 0 ] || fail 'resolved marker pin failed'
[ ! -e "$PIN_GIT_CALLED" ] || fail 'resolved marker mode ran git'
grep -q "^pid=$(cat "$TMP/pin-pid")$" "$TMP/direct-marker" || fail 'marker pid is not the invoking script pid'
for args in '--marker' '--sha' '--marker x' '--marker x --sha' '--sha abc'; do
  # Intentional token splitting for invalid argument combinations.
  # shellcheck disable=SC2086
  bash "$RP" pin $args > "$TMP/usage.out" 2>&1
  [ "$?" = 2 ] || fail "invalid resolved marker arguments accepted: $args"
done
bash "$RP" pin --marker "$TMP/missing-sha" --sha --label > "$TMP/usage.out" 2>&1
[ "$?" = 2 ] || fail 'option accepted as missing sha value'
bash "$RP" pin --marker "$TMP/unused" --sha "" > "$TMP/usage.out" 2>&1
[ "$?" = 2 ] || fail 'empty sha accepted'
for op in status release; do
  bash "$RP" "$op" "$NOREPO6" > "$TMP/nonrepo.out" 2>&1
  [ "$?" = 2 ] || fail "$op outside repo must exit 2"
done
mkdir "$TMP/unborn"
git -C "$TMP/unborn" init -q
bash "$RP" pin "$TMP/unborn" > "$TMP/unborn.out" 2>&1
[ "$?" = 2 ] || fail 'unborn HEAD must exit 2'
grep -q 'could not resolve HEAD' "$TMP/unborn.out" || fail 'unborn HEAD diagnostic missing'
TIMER=$(dispatch_timeout_bin) || { echo "FAIL: no usable timer" >&2; exit 1; }
[ -n "$TIMER" ] && "$TIMER" 1 true || fail "timer unavailable"
mkfifo "$REPO3/.git/objects/info/alternates"
probe_rc=0
"$TIMER" -k 1 1 git -C "$REPO3" rev-parse --verify HEAD > /dev/null 2>&1 || probe_rc=$?
if [ "$probe_rc" = 124 ]; then
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 "$TIMER" -k 1 10 bash "$RP" pin "$REPO3" > "$TMP/fifo.out" 2>&1
  [ "$?" = 3 ] || fail 'standalone FIFO pin must exit 3 within bound'
  grep -q 'git setup timed out' "$TMP/fifo.out" || fail 'standalone FIFO timeout diagnostic missing'
else
  echo 'SKIP: real git does not block on alternates for pin'
fi
rm "$REPO3/.git/objects/info/alternates"
echo 'resolved marker, usage, nonrepo, unborn and bounded FIFO pin PASS'
