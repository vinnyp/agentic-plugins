#!/usr/bin/env bash
set -eu
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-memory-data.XXXXXX")
[ -n "$TASK_TMP" ] || exit 1
trap 'rm -rf "$TASK_TMP"' EXIT
mkdir "$TASK_TMP/bin" "$TASK_TMP/state" "$TASK_TMP/repo"
git -C "$TASK_TMP/repo" init -q
git -C "$TASK_TMP/repo" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m initial
printf review > "$TASK_TMP/brief"
TIMER=$(command -v timeout || command -v gtimeout)
export SOURCE_REPO="$TASK_TMP/repo" REAL_MEMORY_GIT
REAL_MEMORY_GIT=$(command -v git)
cat > "$TASK_TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *' for-each-ref '*) if [ -p "$SOURCE_REPO/.git/objects/info/alternates" ]; then sleep 60; fi ;;
esac
exec "$REAL_MEMORY_GIT" "$@"
STUB
chmod +x "$TASK_TMP/bin/git"
cat > "$TASK_TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
for state in "$TMPDIR"/dispatch-review-state.*; do
  [ -d "$state" ] || continue
  printf forged > "$state/before"
  mkfifo "$state/after" "$state/changes" "$state/after-changes"
done
case "$TEST_MODE" in
  drift) git -C "$SOURCE_REPO" config core.hooksPath /changed ;;
  alternates) mkfifo "$SOURCE_REPO/.git/objects/info/alternates" ;;
esac
STUB
chmod +x "$TASK_TMP/bin/claude"
for mode in clean drift alternates; do
  expected=10
  [ "$mode" != clean ] || expected=0
  rc=0
  (cd "$SOURCE_REPO" && PATH="$TASK_TMP/bin:$PATH" TMPDIR="$TASK_TMP/state" TEST_MODE="$mode" DISPATCH_SNAPSHOT_TIMEOUT_SECS=15 "$TIMER" -k 1 90 "$SELF_DIR/dispatch-worker" --runtime claude --review --brief "$TASK_TMP/brief") > "$TASK_TMP/out" 2> "$TASK_TMP/err" || rc=$?
  [ "$rc" = "$expected" ] || { cat "$TASK_TMP/err"; echo "FAIL: planted $mode verdict expected $expected got $rc"; exit 1; }
  case "$mode" in
    drift) grep -q 'config core.hookspath' "$TASK_TMP/err"; git -C "$SOURCE_REPO" config --unset core.hooksPath ;;
    alternates) grep -q 'nonregular .*objects/info/alternates' "$TASK_TMP/err" || { echo 'FAIL: timed-out snapshot lost nonregular path'; exit 1; }; rm "$SOURCE_REPO/.git/objects/info/alternates" ;;
  esac
done
echo 'review verdict memory and planted FIFO paths PASS'
