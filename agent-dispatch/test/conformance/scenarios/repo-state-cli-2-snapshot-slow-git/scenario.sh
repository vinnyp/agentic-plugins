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
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail "expected 3, got $rc"
  [ "$(first_line "$d/file")" = unreadable ] || fail 'file not unreadable'
  ! grep -q '^unsafe' "$d/file" || fail 'unexpected unsafe line'
  grep -Fq "repo-state-check: snapshot timed out; no special file found in $R/.git; cause unknown (if the repo is large, raise DISPATCH_SNAPSHOT_TIMEOUT_SECS and the Bash tool timeout)" "$d/err" || fail 'message (b) missing'
  survivors; no_state_dir "$d"; no_bound_dir

echo "PASS: case_2_snapshot_slow_git"
