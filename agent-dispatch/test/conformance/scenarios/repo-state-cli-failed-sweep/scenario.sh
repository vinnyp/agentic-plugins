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
  mkdir "$R/.git/inaccessible"; chmod 000 "$R/.git/inaccessible"
  # A failing find shim also makes this deterministic under privileged accounts.
  mkdir "$d/bin"
  command -v find > "$d/real-find"
  cat > "$d/bin/find" <<'FIND'
#!/usr/bin/env bash
"$REAL_FIND" "$@"
exit 1
FIND
  chmod +x "$d/bin/find"
  mkfifo "$R/.git/objects/info/alternates"
  REAL_FIND=$(cat "$d/real-find") PATH="$d/bin:$SLOW:$SHIMS:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 \
    "$BIN/repo-state-check" snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  chmod 700 "$R/.git/inaccessible"
  [ "$rc" = 3 ] || fail 'failed sweep did not fail closed'
  grep -Fxq "repo-state-check: snapshot timed out; pre-sweep failed; special files found so far: $R/.git/objects/info/alternates; cause unknown" "$d/err" || { cat "$d/err" >&2; fail 'failed sweep message missing'; }
  grep -q '^unsafe' "$d/file" || fail 'partial sweep discarded'
  ! grep -q 'pre-sweep skipped' "$d/err" || fail 'failed sweep reported skipped'
  survivors; no_bound_dir
  # With nothing found, the plain message stays.
  rm "$R/.git/objects/info/alternates"
  rc=0
  REAL_FIND=$(cat "$d/real-find") PATH="$d/bin:$SLOW:$SHIMS:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 \
    "$BIN/repo-state-check" snapshot "$R" "$d/file2" 2> "$d/err2" || rc=$?
  [ "$rc" = 3 ] || fail 'failed sweep (none found) did not fail closed'
  grep -Fxq 'repo-state-check: snapshot timed out; pre-sweep failed; cause unknown' "$d/err2" || { cat "$d/err2" >&2; fail 'plain failed sweep message missing'; }
  survivors; no_bound_dir

echo "PASS: case_failed_sweep"
