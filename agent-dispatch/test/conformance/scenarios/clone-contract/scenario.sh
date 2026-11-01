#!/usr/bin/env bash
set -euo pipefail
BIN=$IMPL_BIN
TMP=$SCN_TMP
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX
export GIT_CONFIG_GLOBAL="$TMP/global" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n name = Test\n email = test@example.invalid\n[filter "lfs"]\n clean = x\n' > "$GIT_CONFIG_GLOBAL"
# Invoke only the published command; stdout carries the resolved commit.
clone() {
  "$BIN/review-clone.sh" "$@" > "$TMP/clone-output"
}
expect_rc() {
  local want=$1 rc=0
  shift
  "$@" 2>"$TMP/error" || rc=$?
  [ "$rc" = "$want" ] || { cat "$TMP/error"; echo "expected $want, got $rc" >&2; exit 1; }
  if [ "$want" = 3 ] || [ "$want" = 4 ]; then
    grep -q '^review-clone: .' "$TMP/error"
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
cp "$src/.git/config" "$TMP/config-before"
git -C "$src" for-each-ref > "$TMP/refs"
dest="$TMP/p/dispatch-review-wt.A"
expect_rc 0 clone "$src" "$dest"
[ "$(cat "$TMP/clone-output")" = "$dest $(git -C "$src" rev-parse HEAD)" ]
[ -d "$dest/.git" ] && [ ! -e "$dest/.git/objects/info/alternates" ]
[[ $(ls -ld "$dest") = drwx------* ]]
[ "$(git -C "$dest" rev-list --count main..feature)" = 1 ]
[ "$(git -C "$dest" rev-list --count origin/main..main)" = 1 ]
[ "$(refs "$src")" = "$(refs "$dest")" ]
[ "$(git -C "$dest" symbolic-ref refs/remotes/origin/HEAD)" = "$(git -C "$src" symbolic-ref refs/remotes/origin/HEAD)" ]
[ "$(git -C "$dest" remote get-url --push origin)" = "$dest/.git/review-clone-disabled-remote" ]
old=$(git -C "$dest" rev-parse origin/main)
if git -C "$dest" fetch origin 2>/dev/null; then exit 1; fi
[ "$old" = "$(git -C "$dest" rev-parse origin/main)" ]
if git -C "$dest" push origin HEAD:refs/heads/x 2>/dev/null; then exit 1; fi
cmp "$src/.git/config" "$TMP/config-before"
git -C "$src" for-each-ref > "$TMP/refs-after"
cmp "$TMP/refs" "$TMP/refs-after"
empty="$TMP/p/dispatch-review-wt.empty"
mkdir -m 700 "$empty"
expect_rc 0 clone "$src" "$empty"
mkdir -m 755 "$TMP/p/dispatch-review-wt.public"
expect_rc 3 clone "$src" "$TMP/p/dispatch-review-wt.public"
[ -d "$TMP/p/dispatch-review-wt.public" ]
mkdir -m 700 "$TMP/p/dispatch-review-wt.nonempty"
echo occupied > "$TMP/p/dispatch-review-wt.nonempty/file"
expect_rc 3 clone "$src" "$TMP/p/dispatch-review-wt.nonempty"
ln -s "$empty" "$TMP/p/dispatch-review-wt.link"
expect_rc 3 clone "$src" "$TMP/p/dispatch-review-wt.link"
mkdir "$TMP/nonrepo"
expect_rc 3 clone "$TMP/nonrepo" "$TMP/p/dispatch-review-wt.nonrepo"
echo '# filter=lfs' > "$src/.gitattributes"
git -C "$src" add .gitattributes
git -C "$src" commit -qm comment-attributes
expect_rc 0 clone "$src" "$TMP/p/dispatch-review-wt.comment"
echo '*.bin filter=lfs' > "$src/.gitattributes"
git -C "$src" add .gitattributes
git -C "$src" commit -qm filter-attributes
expect_rc 4 clone "$src" "$TMP/p/dispatch-review-wt.filter"
git -C "$src" rm -q .gitattributes
git -C "$src" commit -qm remove-test-attributes
for directory in 'a"b' $'a\tb'; do
  mkdir "$src/$directory"
  echo '*.bin filter=lfs' > "$src/$directory/.gitattributes"
  git -C "$src" add "$directory/.gitattributes"
  git -C "$src" commit -qm unusual-attributes
  expect_rc 4 clone "$src" "$TMP/p/dispatch-review-wt.unusual"
  git -C "$src" rm -q "$directory/.gitattributes"
  git -C "$src" commit -qm remove-unusual-attributes
done
printf '# filter=lfs\n' > "$src/.git/info/attributes"
expect_rc 0 clone "$src" "$TMP/p/dispatch-review-wt.info-comment"
{
  printf '*.bin filter=lfs\n'
  awk 'BEGIN {for (i=0; i<60000; i++) print "# padding"}'
} > "$src/.git/info/attributes"
[ "$(wc -c < "$src/.git/info/attributes")" -ge 600000 ]
expect_rc 4 clone "$src" "$TMP/p/dispatch-review-wt.info-large"
rm "$src/.git/info/attributes"
# Move a ref at Git's observable boundary after the first mirror fetch.
# Only this invocation sees the wrapper; all setup and verification use real Git.
mkdir "$TMP/tools"
real_git=$(command -v git)
export CLONE_REAL_GIT="$real_git" CLONE_SOURCE="$src" CLONE_MOVED="$TMP/ref-moved"
cat > "$TMP/tools/git" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = -C ] && [ "${2:-}" = "$CLONE_SOURCE" ] &&
   [ "${3:-}" = for-each-ref ] && [ ! -e "$CLONE_MOVED" ]; then
  "$CLONE_REAL_GIT" -C "$CLONE_SOURCE" tag concurrent-review
  : > "$CLONE_MOVED"
fi
exec "$CLONE_REAL_GIT" "$@"
SH
chmod +x "$TMP/tools/git"
PATH="$TMP/tools:$PATH" expect_rc 0 clone "$src" "$TMP/p/dispatch-review-wt.retry"
[ -f "$TMP/ref-moved" ]
[ "$(refs "$src")" = "$(refs "$TMP/p/dispatch-review-wt.retry")" ]
git -C "$src" checkout -q main
git -C "$src" worktree add -q "$TMP/linked" feature
expect_rc 0 clone "$TMP/linked" "$TMP/p/dispatch-review-wt.linked"
[ "$(git -C "$TMP/p/dispatch-review-wt.linked" rev-parse HEAD)" = "$(git -C "$src" rev-parse feature)" ]
for bad in "" relative "$dest" "$TMP/p/other"; do expect_rc 3 clone "$src" "$bad"; done
git init -q "$TMP/unborn"
expect_rc 4 clone "$TMP/unborn" "$TMP/p/dispatch-review-wt.fail"
grep -q HEAD "$TMP/error"
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
  expect_rc 4 clone "$src" "$TMP/p/dispatch-review-wt.fail"
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
  expect_rc 3 "$BIN/review-clone.sh" --remove "$TMP/p" "$bad"
  [ -e "$bad" ]
done
expect_rc 3 "$BIN/review-clone.sh" --remove "$TMP" "$dest"
[ -d "$dest" ]
expect_rc 0 "$BIN/review-clone.sh" --remove "$TMP/p" "$dest"
[ ! -e "$dest" ]
expect_rc 0 "$BIN/review-clone.sh" --remove "$TMP/p" "$TMP/p/dispatch-review-wt.linked"
ln -s "$BIN/review-clone.sh" "$TMP/cli"
usage='usage: review-clone.sh <source-worktree> <dest> [<sha>] | --remove <parent> <path>'
expect_rc 0 "$TMP/cli" --help > "$TMP/output"
[ "$(cat "$TMP/output")" = "$usage" ]
expect_rc 0 "$TMP/cli" -h > "$TMP/output"
[ "$(cat "$TMP/output")" = "$usage" ]
expect_rc 0 "$TMP/cli" "$src" "$dest" > "$TMP/output"
[ "$(cat "$TMP/output")" = "$dest $(git -C "$src" rev-parse HEAD)" ]
expect_rc 64 "$TMP/cli"
[ "$(cat "$TMP/error")" = "$usage" ]
echo 'PASS: clone isolation, refs, convergence, destinations, filters, removal and symlink CLI'
