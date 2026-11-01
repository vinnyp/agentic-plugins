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
  compare_pair "$d"
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli compare "$d/before" "$d/after" > "$d/out" 2> "$d/err" || rc=$?
  [ "$rc" = 2 ] || fail "expected 2, got $rc"
  [ "$(cat "$d/out")" = 'state: compare timed out' ] || fail 'compare output is not exactly the timeout line'
  survivors; no_state_dir "$d"; no_bound_dir

echo "PASS: case_4_compare_slow_git"
