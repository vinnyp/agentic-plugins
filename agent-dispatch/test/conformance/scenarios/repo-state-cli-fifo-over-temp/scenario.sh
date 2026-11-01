#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# shellcheck source=agent-dispatch/test/conformance/repo-state-cli-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-cli-fixture.sh"
export CASE_MODE=timeout
  set -eu; setup_mode
  declare d rc=0
  fixture; d=$(outdir)
  mkdir "$d/bin"
  cat > "$d/bin/git" <<'SHIM'
#!/usr/bin/env bash
echo $$ >> "$RUN_PID_FILE"
case " $* " in
  *' worktree list '*)
    for t in "$OUTDIR"/.repo-state-out.*; do
      [ -f "$t" ] || continue
      rm -f "$t"; mkfifo "$t"
    done ;;
esac
exec -a "tagged-$RUN_ID" "$REAL_GIT" "$@"
SHIM
  chmod +x "$d/bin/git"
  OUTDIR=$d PATH="$d/bin:$SHIMS:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=20 \
    "$BIN/repo-state-check" snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 0 ] || fail "temporary planting changed snapshot status $rc"
  [ "$(first_line "$d/file")" = repo ] || fail 'temporary planting changed snapshot output'
  survivors; no_state_dir "$d"; no_bound_dir

echo "PASS: case_fifo_over_temp"
