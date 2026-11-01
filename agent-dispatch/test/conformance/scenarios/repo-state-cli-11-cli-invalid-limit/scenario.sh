#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# shellcheck source=agent-dispatch/test/conformance/repo-state-cli-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-cli-fixture.sh"
export CASE_MODE=timeout
  set -eu; setup_mode
  declare d started rc=0 value
  fixture; d=$(outdir)
  started=$SECONDS
  DISPATCH_SNAPSHOT_TIMEOUT_SECS=abc cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 0 ] || fail "expected 0, got $rc"
  grep -Fxq 'repo-state-check: invalid DISPATCH_SNAPSHOT_TIMEOUT_SECS; using 60' "$d/err" || fail 'warning text'
  [ $((SECONDS - started)) -lt 60 ] || fail 'too slow'
  started=$SECONDS
  cp "$d/file" "$d/copy"
  for value in abc 0; do
    rc=0
    env DISPATCH_SNAPSHOT_TIMEOUT_SECS="$value" PATH="$SHIMS:$PATH" "$BIN/repo-state-check" compare "$d/file" "$d/copy" > "$d/out" 2> "$d/err" || rc=$?
    [ "$rc" = 0 ] || fail "compare limit $value gave $rc"
    [ ! -s "$d/out" ] || fail 'clean compare produced output'
    grep -Fxq 'repo-state-check: invalid DISPATCH_SNAPSHOT_TIMEOUT_SECS; using 60' "$d/err" || fail 'compare warning text'
  done
  [ $((SECONDS - started)) -lt 60 ] || fail 'compare too slow'
  survivors; no_state_dir "$d"; no_bound_dir

echo "PASS: case_11_cli_invalid_limit"
