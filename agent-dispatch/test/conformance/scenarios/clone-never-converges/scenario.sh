#!/usr/bin/env bash
set -euo pipefail
mkdir "$SCN_TMP/src" "$SCN_TMP/tools"
src="$SCN_TMP/src"
git -C "$src" init -q
git -C "$src" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial --allow-empty
export CLONE_SOURCE="$src" CLONE_REAL_GIT CLONE_FIRST CLONE_OTHER CLONE_FETCHES="$SCN_TMP/fetches"
CLONE_FIRST=$(git -C "$src" rev-parse HEAD)
tree=$(git -C "$src" rev-parse 'HEAD^{tree}')
CLONE_OTHER=$(git -C "$src" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree -p HEAD -m alternate "$tree")
git -C "$src" tag churn "$CLONE_FIRST"
: > "$CLONE_FETCHES"
CLONE_REAL_GIT=$(command -v git)
cat > "$SCN_TMP/tools/git" <<'SH'
#!/usr/bin/env bash
set -eu
"$CLONE_REAL_GIT" "$@"
case " $* " in
  *' fetch --quiet --no-tags --prune --update-head-ok '*)
    current=$("$CLONE_REAL_GIT" -C "$CLONE_SOURCE" rev-parse refs/tags/churn)
    next=$CLONE_FIRST
    [ "$current" != "$CLONE_FIRST" ] || next=$CLONE_OTHER
    "$CLONE_REAL_GIT" -C "$CLONE_SOURCE" update-ref refs/tags/churn "$next"
    echo fetch >> "$CLONE_FETCHES"
    ;;
esac
SH
chmod +x "$SCN_TMP/tools/git"
dest="$SCN_TMP/dispatch-review-wt.churn"
rc=0
PATH="$SCN_TMP/tools:$PATH" "$IMPL_BIN/review-clone.sh" "$src" "$dest" > "$SCN_TMP/out" 2> "$SCN_TMP/err" || rc=$?
[ "$rc" = 4 ]
[ "$(cat "$SCN_TMP/err")" = 'review-clone: dirty checkout or mismatched refs' ]
[ ! -e "$dest" ]
[ "$(wc -l < "$CLONE_FETCHES" | tr -d ' ')" = 3 ]
echo 'PASS: never converging refs refused and destination removed'
