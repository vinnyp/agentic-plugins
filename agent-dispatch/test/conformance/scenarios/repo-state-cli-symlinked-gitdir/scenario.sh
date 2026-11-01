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
  mv "$R/.git" "$d/realgit"
  ln -s "$d/realgit" "$R/.git"
  mkfifo "$d/realgit/FETCH_HEAD"
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail "expected 3, got $rc"
  ! grep -q '^unsafe' "$d/file" || fail 'a symlinked .git was followed'
  grep -Fq 'pre-sweep skipped (.git is not a directory)' "$d/err" || fail 'skip message missing'
  survivors; no_state_dir "$d"; no_bound_dir

echo "PASS: case_symlinked_gitdir"
