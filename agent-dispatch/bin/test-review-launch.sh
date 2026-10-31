#!/usr/bin/env bash
set -eu
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SELF_DIR/lib/timeout-bin.sh"
# shellcheck source=lib/test-env-reset.sh
. "$SELF_DIR/lib/test-env-reset.sh"
reset_dispatch_env
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-launch.XXXXXX")
[ -n "$TASK_TMP" ] || exit 1
trap 'rm -rf "$TASK_TMP"' EXIT
mkdir "$TASK_TMP/bin" "$TASK_TMP/repo"
git -C "$TASK_TMP/repo" init -q
git -C "$TASK_TMP/repo" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m initial
printf 'Review source\n' > "$TASK_TMP/brief"
for runtime in codex agy claude; do
  printf '#!/usr/bin/env bash\nprintf launched > "$LAUNCH_MARKER"\n' > "$TASK_TMP/bin/$runtime"
  chmod +x "$TASK_TMP/bin/$runtime"
done
REAL_GIT=$(command -v git)
TIMER=$(dispatch_timeout_bin) || { echo "FAIL: no usable timer" >&2; exit 1; }
export LAUNCH_MARKER="$TASK_TMP/launched"
export REAL_GIT RUN_ID="review-launch-$$-$RANDOM" RUN_PID_FILE="$TASK_TMP/pids"
: > "$RUN_PID_FILE"
cat > "$TASK_TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$RUN_PID_FILE"
exec -a "tagged-$RUN_ID" "$REAL_GIT" "$@"
STUB
chmod +x "$TASK_TMP/bin/git"
assert_reaped() {
  while IFS= read -r tagged_pid; do
    if ps -p "$tagged_pid" -o command= 2>/dev/null | grep -Fq "tagged-$RUN_ID"; then
      echo 'FAIL: launch left a tagged git process'; exit 1
    fi
  done < "$RUN_PID_FILE"
}
fifo_cases=0
for runtime in codex agy claude; do
  for metadata in objects/info/alternates config HEAD; do
    fixture="$TASK_TMP/repo/.git/$metadata"
    saved="$TASK_TMP/saved"
    existed=0
    if [ -f "$fixture" ]; then mv "$fixture" "$saved"; existed=1; fi
    mkfifo "$fixture"
    probe_rc=0
    "$TIMER" -k 1 1 "$REAL_GIT" -C "$TASK_TMP/repo" rev-parse --absolute-git-dir >/dev/null 2>&1 || probe_rc=$?
    if [ "$probe_rc" = 124 ]; then
      fifo_cases=$((fifo_cases + 1))
      rc=0
      (cd "$TASK_TMP/repo" && PATH="$TASK_TMP/bin:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 "$TIMER" -k 1 8 "$SELF_DIR/dispatch-worker" --review --runtime "$runtime" --brief "$TASK_TMP/brief") > "$TASK_TMP/out" 2> "$TASK_TMP/err" || rc=$?
      [ "$rc" = 3 ] || { cat "$TASK_TMP/err"; echo "FAIL: $runtime $metadata rc=$rc"; exit 1; }
      grep -q 'launch-time git setup timed out' "$TASK_TMP/err"
      grep -q 'DISPATCH_SNAPSHOT_TIMEOUT_SECS' "$TASK_TMP/err"
      grep -q 'skipped(not-launched) original_rc=3' "$TASK_TMP/err"
      [ ! -e "$LAUNCH_MARKER" ] || exit 1
    else
      echo "SKIP: real git does not block on $metadata ($runtime)"
    fi
    assert_reaped
    rm "$fixture"
    if [ "$existed" = 1 ]; then mv "$saved" "$fixture"; fi
  done
done
[ "$fifo_cases" -gt 0 ] || { echo 'FAIL: every launch FIFO case skipped'; exit 1; }
# Unwritable temporary storage must fail before runtime allocation.
mkdir "$TASK_TMP/readonly"
chmod 500 "$TASK_TMP/readonly"
for runtime in codex agy claude; do
  rc=0
  (cd "$TASK_TMP/repo" && TMPDIR="$TASK_TMP/readonly" PATH="$TASK_TMP/bin:$PATH" "$SELF_DIR/dispatch-worker" --review --runtime "$runtime" --brief "$TASK_TMP/brief") > "$TASK_TMP/out" 2> "$TASK_TMP/err" || rc=$?
  [ "$rc" = 3 ] || { echo "FAIL: $runtime temporary storage rc=$rc"; exit 1; }
  grep -q 'launch-time git setup could not complete' "$TASK_TMP/err"
  [ ! -e "$LAUNCH_MARKER" ] || exit 1
done
chmod 700 "$TASK_TMP/readonly"
# A timeout in the before snapshot must never launch the runtime.
export REAL_GIT
cat > "$TASK_TMP/bin/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in *' status '*) sleep 10 ;; esac
exec "$REAL_GIT" "$@"
STUB
chmod +x "$TASK_TMP/bin/git"
rc=0
(cd "$TASK_TMP/repo" && PATH="$TASK_TMP/bin:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 "$TIMER" -k 1 8 "$SELF_DIR/dispatch-worker" --review --runtime codex --brief "$TASK_TMP/brief") > "$TASK_TMP/out" 2> "$TASK_TMP/err" || rc=$?
[ "$rc" = 3 ] || { echo "FAIL: before snapshot timeout rc=$rc"; exit 1; }
grep -q 'skipped(not-launched) original_rc=3' "$TASK_TMP/err"
[ ! -e "$LAUNCH_MARKER" ] || exit 1
assert_reaped
echo 'review launch FIFO matrix and allocation/before-snapshot failures PASS' 
