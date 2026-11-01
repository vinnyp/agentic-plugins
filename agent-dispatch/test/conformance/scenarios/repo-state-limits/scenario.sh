#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"

fixture
for value in 0 00 abc '' 86401 999999 18446744073709551676; do
  DISPATCH_SNAPSHOT_TIMEOUT_SECS="$value" "$BIN/repo-state-check" snapshot "$R" "$TMP/snapshot" 2> "$TMP/err"
  grep -Fxq 'repo-state-check: invalid DISPATCH_SNAPSHOT_TIMEOUT_SECS; using 60' "$TMP/err"
  DISPATCH_SNAPSHOT_TIMEOUT_SECS="$value" "$BIN/repo-state-check" compare "$TMP/snapshot" "$TMP/snapshot" > "$TMP/out" 2> "$TMP/err"
  grep -Fxq 'repo-state-check: invalid DISPATCH_SNAPSHOT_TIMEOUT_SECS; using 60' "$TMP/err"
done
for value in 08 010 86400; do
  DISPATCH_SNAPSHOT_TIMEOUT_SECS="$value" "$BIN/repo-state-check" snapshot "$R" "$TMP/snapshot" 2> "$TMP/err"
  [ ! -s "$TMP/err" ]
done

echo "PASS: repo-state-limits"
