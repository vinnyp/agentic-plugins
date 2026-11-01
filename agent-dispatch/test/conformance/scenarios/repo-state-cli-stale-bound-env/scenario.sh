#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# shellcheck source=agent-dispatch/test/conformance/repo-state-cli-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-cli-fixture.sh"
export CASE_MODE=timeout
  set -eu; setup_mode
  declare d pid rc=0
  d=$(outdir); mkdir "$d/sentinel-dir"
  # A sleep the test starts, in its own process group.
  set -m
  bash -c 'exec -a "tagged-sleep-$RUN_ID" /bin/sleep 60' &
  pid=$!
  set +m
  echo "$pid tagged-sleep-$RUN_ID" >> "$RUN_PID_FILE"
  REPO_STATE_BOUND_PID=$pid REPO_STATE_BOUND_WATCHDOG=$pid REPO_STATE_BOUND_PRIVATE="$d/sentinel-dir" \
    "$BIN/repo-state-check" --help > /dev/null || rc=$?
  [ "$rc" = 0 ] || { kill "$pid" 2>/dev/null || true; fail "--help exited $rc"; }
  [ -d "$d/sentinel-dir" ] || { kill "$pid" 2>/dev/null || true; fail 'stale private variable removed a directory'; }
  kill -0 "$pid" 2>/dev/null || fail 'stale pid variable killed a process group'
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  survivors; no_bound_dir

echo "PASS: case_stale_bound_env"
