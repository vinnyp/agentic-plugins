#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
fixture
mkdir "$SCN_REPO"
git -C "$SCN_REPO" init -q -b main
git -C "$SCN_REPO" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial --allow-empty
printf 'Review this fixture.\n' > "$TMP/brief"
mkdir "$TMP/bin"
export REAL_GIT
REAL_GIT=$(command -v git)
export BOUND_MODE=snapshot
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -eu
cat >/dev/null
if [ "$BOUND_MODE" = compare ]; then
  "$REAL_GIT" -C "$SCN_REPO" -c user.name=Foreign -c user.email=foreign@example.invalid commit -qm foreign --allow-empty
fi
touch "$SCN_TMP/runtime-ran"
printf 'Fixture review completed.\n'
STUB
cat > "$TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
if [ -f "$SCN_TMP/runtime-ran" ]; then
  case "$BOUND_MODE:$*" in
    snapshot:*for-each-ref*|compare:*rev-list*|compare:*cat-file*) exec /bin/sleep 3 ;;
  esac
fi
exec "$REAL_GIT" "$@"
GIT
chmod +x "$TMP/bin/"*
rc=0
PATH="$TMP/bin:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 KILL_AFTER=1s   "$BIN/dispatch-worker" --runtime codex --review --workdir "$SCN_REPO" --brief "$TMP/brief" --timeout 5s > "$TMP/out" 2> "$TMP/err" || rc=$?
[ "$rc" = 10 ] || { cat "$TMP/out" "$TMP/err"; fail "worker bound returned $rc"; }
[ -f "$TMP/runtime-ran" ]
grep -Eq 'critical|unreadable|could not complete' "$TMP/out" "$TMP/err"
grep -q 'drift snapshot timed out' "$TMP/err"
[ ! -e "$SCN_REPO/.git/review-pinned" ]
echo "PASS: repo-state-worker-snapshot-bound"
