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
cli snapshot "$R" "$d/file"
export PATH="$NOTIMER:$PATH"
for mode in snapshot compare; do
  rc=0
  if [ "$mode" = snapshot ]; then
    DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
    [ "$rc" = 3 ] || fail "snapshot rc=$rc"
    [ "$(first_line "$d/file")" = unreadable ] || fail 'snapshot readable'
  else
    DISPATCH_SNAPSHOT_TIMEOUT_SECS=1 slow_cli compare "$d/before" "$d/after" > "$d/out" 2> "$d/err" || rc=$?
    [ "$rc" = 2 ] || fail "compare rc=$rc"
    [ "$(wc -l < "$d/out" | tr -d ' ')" = 1 ] || fail 'compare output is not one line'
    grep -Eq '^state: compare (timed out|could not complete \(.+\))$' "$d/out" || fail 'compare did not fail closed'
  fi
  survivors; no_state_dir "$d"; no_bound_dir
done
echo 'PASS: snapshot and compare refuse a timer that reports success without running'
