#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"

fixture
# Fixed, finite concurrent calls; wait for every child before returning.
workers=''
for worker in 1 2 3 4 5 6 7 8; do
  (
    # shellcheck disable=SC2034 # Fixed finite repetition.
    for attempt in 1 2 3 4 5; do
      rc=0
      "$BIN/review-pin.sh" status "$R" > "$TMP/parallel-$worker" 2>&1 || rc=$?
      [ "$rc" = 1 ] || { cat "$TMP/parallel-$worker"; exit 1; }
    done
  ) &
  workers="$workers $!"
done
failed=0
for worker in $workers; do wait "$worker" || failed=1; done
[ "$failed" = 0 ] || fail 'concurrent status failed'

echo "PASS: repo-state-parallel-pin"
