#!/usr/bin/env bash
# Run and audit the complete gate with stock macOS tools.
set -uo pipefail
BIN=$(CDPATH='' cd "$(dirname "$0")" && pwd)
bad=0
for timer in timeout gtimeout; do
  if command -v "$timer" >/dev/null 2>&1; then echo "stock gate: $timer must not resolve"; bad=1; fi
done
if [ "${BASH_VERSINFO[0]}" != 3 ]; then echo 'stock gate: requires Bash 3'; bad=1; fi
for utility in perl shasum git jq; do
  if ! command -v "$utility" >/dev/null 2>&1; then echo "stock gate: missing $utility"; bad=1; fi
done
[ "$bad" = 0 ] || exit 1
output=$(mktemp "${TMPDIR:-/tmp}/stock-gate.XXXXXX") || exit 1
[ -n "$output" ] || exit 1
trap 'rm -f "$output"' EXIT
RUN_TESTS_KEEP_LOGS=1 bash "$BIN/run-tests.sh" 2>&1 | tee "$output"
rc=${PIPESTATUS[0]}
rundir=$(sed -n 's/^Run dir: //p' "$output" | tail -n 1)
[ -n "$rundir" ] && [ -d "$rundir" ] || exit 1
audit_rc=0
bash "$BIN/audit-test-skips.sh" "$rundir" "$BIN/lib/stock-skip-manifest.txt" || audit_rc=$?
[ "$rc" = 0 ] && [ "$audit_rc" = 0 ]
