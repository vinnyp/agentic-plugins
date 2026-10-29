#!/usr/bin/env bash
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/test-dispatch-worker-lib.sh
. "$SELF_DIR/lib/test-dispatch-worker-lib.sh"
set -e
install_cfg_agy_stub
repo="$TMP/source"
make_git_repo "$repo"
rc=0
run_cfg_review "$repo" || rc=$?
[ "$rc" = 0 ] || { echo "FAIL: healthy clone returned $rc"; exit 1; }
mkdir "$TMP/slow-clone"
export REAL_CLONE_GIT
REAL_CLONE_GIT=$(command -v git)
cat > "$TMP/slow-clone/git" <<'STUB'
#!/usr/bin/env bash
case "$1" in clone) sleep 10 ;; esac
exec "$REAL_CLONE_GIT" "$@"
STUB
chmod +x "$TMP/slow-clone/git"
rc=0
PATH="$TMP/slow-clone:$PATH" DISPATCH_CLONE_TIMEOUT_SECS=3 run_cfg_review "$repo" || rc=$?
[ "$rc" = 3 ] || { echo "FAIL: clone timeout returned $rc"; exit 1; }
grep -qF 'skipped(not-launched) original_rc=3' "$TMP/cfg.err"
! grep -q 'running non-hermetically' "$TMP/cfg.err"
assert_no_review_residue
echo 'review clone timeout refuses launch PASS'
