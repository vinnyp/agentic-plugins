#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# shellcheck source=agent-dispatch/test/conformance/repo-state-cli-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-cli-fixture.sh"
export CASE_MODE=timeout
  set -eu; setup_mode
  declare d pid rc=0
  fixture; d=$(outdir)
  cli snapshot "$R" "$d/file"
  [ "$(first_line "$d/file")" = repo ] || fail 'valid file missing'
  env PATH="$SLOW:$SHIMS:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=3 "$BIN/repo-state-check" snapshot "$R" "$d/file" 2> /dev/null &
  pid=$!
  /bin/sleep 1
  ps -p "$pid" -o command= | grep -qF "$RUN_ID" || fail 'untagged CLI'
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(first_line "$d/file")" = unreadable ] || fail 'killed CLI left a stale snapshot readable'
  survivors 9   # limit 3 + 5 kill grace + 1
  # SIGKILL cannot run cleanup; these temporary paths belong only to this case.
  declare orphan
  for orphan in "$TMPDIR"/repo-state-bound.* "$TMPDIR"/repo-state-cli.* "$d"/.repo-state-out.*; do
    [ ! -e "$orphan" ] || rm -rf "$orphan"
  done
  no_bound_dir
  no_state_dir "$d"
  cli snapshot "$R" "$d/file"
  [ "$(first_line "$d/file")" = repo ] || fail 'valid file missing (second)'
  cli snapshot relative "$d/file" 2> /dev/null || rc=$?
  [ "$rc" = 3 ] || fail "relative repo expected 3, got $rc"
  [ "$(first_line "$d/file")" = unreadable ] || fail 'relative repo left a stale snapshot'
  no_state_dir "$d"; no_bound_dir

echo "PASS: case_8_external_kill"
