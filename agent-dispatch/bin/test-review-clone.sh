#!/usr/bin/env bash
set -euo pipefail
BIN=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-clone-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf -- "$TMP"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX
export GIT_CONFIG_GLOBAL="$TMP/global" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n name = Test\n email = test@example.invalid\n[filter "lfs"]\n clean = x\n' > "$GIT_CONFIG_GLOBAL"
# shellcheck source=agent-dispatch/bin/lib/review-clone.sh
. "$BIN/lib/review-clone.sh"
expect_rc() {
  local want=$1 rc=0
  shift
  "$@" 2>"$TMP/error" || rc=$?
  [ "$rc" = "$want" ] || { cat "$TMP/error"; echo "expected $want, got $rc" >&2; exit 1; }
  if [ "$want" = 3 ] || [ "$want" = 4 ]; then
    [ -n "$REVIEW_CLONE_REASON" ]
    [ "$(wc -l < "$TMP/error" | tr -d ' ')" = 1 ] || { echo "unexpected stderr for $*"; cat "$TMP/error"; exit 1; }
  fi
}
refs() { git -C "$1" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags refs/remotes | sed '\|^refs/remotes/origin/HEAD |d'; }
mkdir "$TMP/p"
src="$TMP/src"
git init -q -b main "$src"
echo first > "$src/file"
git -C "$src" add file
git -C "$src" commit -qm first
git clone -q --bare "$src" "$TMP/origin"
git -C "$src" remote add origin "$TMP/origin"
git -C "$src" fetch -q origin
git -C "$src" remote set-head origin main
echo second >> "$src/file"
git -C "$src" commit -qam second
git -C "$src" tag sample
git -C "$src" checkout -qb feature
echo third >> "$src/file"
git -C "$src" commit -qam third
echo stash >> "$src/file"
git -C "$src" stash -q
git -C "$src" notes add -m note
cp "$src/.git/config" "$TMP/config"
git -C "$src" for-each-ref > "$TMP/refs"
dest="$TMP/p/dispatch-review-wt.A"
expect_rc 0 review_clone_build "$src" "$dest"
[ "$REVIEW_CLONE_SHA" = "$(git -C "$src" rev-parse HEAD)" ]
[ -d "$dest/.git" ] && [ ! -e "$dest/.git/objects/info/alternates" ]
[[ $(ls -ld "$dest") = drwx------* ]]
[ "$(git -C "$dest" rev-list --count main..feature)" = 1 ]
[ "$(git -C "$dest" rev-list --count origin/main..main)" = 1 ]
[ "$(refs "$src")" = "$(refs "$dest")" ]
old=$(git -C "$dest" rev-parse origin/main)
if git -C "$dest" fetch origin 2>/dev/null; then exit 1; fi
[ "$old" = "$(git -C "$dest" rev-parse origin/main)" ]
if git -C "$dest" push origin HEAD:refs/heads/x 2>/dev/null; then exit 1; fi
cmp "$src/.git/config" "$TMP/config"
git -C "$src" for-each-ref > "$TMP/refs-after"
cmp "$TMP/refs" "$TMP/refs-after"
git -C "$src" checkout -q main
git -C "$src" worktree add -q "$TMP/linked" feature
expect_rc 0 review_clone_build "$TMP/linked" "$TMP/p/dispatch-review-wt.linked"
[ "$(git -C "$TMP/p/dispatch-review-wt.linked" rev-parse HEAD)" = "$(git -C "$src" rev-parse feature)" ]
for bad in "" relative "$dest" "$TMP/p/other"; do expect_rc 3 review_clone_build "$src" "$bad"; done
git init -q "$TMP/unborn"
expect_rc 4 review_clone_build "$TMP/unborn" "$TMP/p/dispatch-review-wt.fail"
[[ $REVIEW_CLONE_REASON = *HEAD* ]]
[ ! -e "$TMP/p/dispatch-review-wt.fail" ]
for mode in filter lfs attributes partial promisor info; do
  case "$mode" in
    filter) git -C "$src" config filter.x.clean x ;;
    lfs) mkdir "$src/.git/lfs" ;;
    attributes) echo '* filter=x' > "$src/.gitattributes"; git -C "$src" add .gitattributes; git -C "$src" commit -qm attributes ;;
    partial) git -C "$src" config extensions.partialclone origin ;;
    promisor) git -C "$src" config remote.origin.promisor true ;;
    info) echo '* filter=x' > "$src/.git/info/attributes" ;;
  esac
  expect_rc 4 review_clone_build "$src" "$TMP/p/dispatch-review-wt.fail"
  [ ! -e "$TMP/p/dispatch-review-wt.fail" ]
  case "$mode" in
    filter) git -C "$src" config --unset filter.x.clean ;;
    lfs) rmdir "$src/.git/lfs" ;;
    attributes) git -C "$src" rm -q .gitattributes; git -C "$src" commit -qm remove-attributes ;;
    partial) git -C "$src" config --unset extensions.partialclone ;;
    promisor) git -C "$src" config --unset remote.origin.promisor ;;
    info) rm "$src/.git/info/attributes" ;;
  esac
done
ln -s "$dest" "$TMP/p/dispatch-review-wt.symlink"
mkdir "$TMP/p/other"
for bad in "$TMP/p/dispatch-review-wt.symlink" "$dest/" "$TMP/p/other"; do
  expect_rc 3 review_clone_guarded_rm "$TMP/p" "$bad"
  [ -e "$bad" ]
  expect_rc 3 "$BIN/review-clone.sh" --remove "$TMP/p" "$bad"
  [ -e "$bad" ]
done
expect_rc 3 review_clone_guarded_rm "$TMP" "$dest"
[ -d "$dest" ]
expect_rc 3 "$BIN/review-clone.sh" --remove "$TMP" "$dest"
expect_rc 0 review_clone_guarded_rm "$TMP/p" "$dest"
[ ! -e "$dest" ]
expect_rc 0 "$BIN/review-clone.sh" --remove "$TMP/p" "$TMP/p/dispatch-review-wt.linked"
ln -s "$BIN/review-clone.sh" "$TMP/cli"
expect_rc 0 "$TMP/cli" "$src" "$dest"
expect_rc 64 "$TMP/cli"
echo 'PASS review-clone'
