#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# shellcheck source=agent-dispatch/test/conformance/repo-state-cli-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-cli-fixture.sh"
setup_mode
fixture
d=$(outdir)
compare_pair "$d"
export PATH="$NOTIMER:$PATH"
for mode in snapshot compare; do
  rc=0
  started=$SECONDS
  if [ "$mode" = snapshot ]; then
    DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
    [ "$rc" = 3 ] || fail "snapshot rc=$rc"
    [ "$(first_line "$d/file")" = unreadable ] || fail 'snapshot readable'
  else
    DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli compare "$d/before" "$d/after" > "$d/out" 2> "$d/err" || rc=$?
    [ "$rc" = 2 ] || fail "compare rc=$rc"
    [ "$(cat "$d/out")" = 'state: compare could not complete (setup failed or no completion recorded)' ] || fail 'compare did not fail closed'
  fi
  [ "$((SECONDS - started))" -le 5 ] || fail 'deadline exceeded'
  survivors; no_state_dir "$d"; no_bound_dir
done
echo 'PASS: snapshot and compare bounded without timer'
