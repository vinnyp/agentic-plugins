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
  mkfifo "$R/.git/objects/info/alternates"
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail "expected 3, got $rc"
  [ "$(first_line "$d/file")" = unreadable ] || fail 'file not unreadable'
  grep -q $'^unsafe\t.*objects/info/alternates' "$d/file" || fail 'unsafe line missing'
  grep -q 'repo-state-check: snapshot timed out; special files found in git metadata:.*objects/info/alternates' "$d/err" || fail 'message (a) missing'
  survivors; no_state_dir "$d"; no_bound_dir

echo "PASS: case_slow_alternates_fifo"
