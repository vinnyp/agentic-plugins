#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# shellcheck source=agent-dispatch/test/conformance/repo-state-cli-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-cli-fixture.sh"
export CASE_MODE=timeout
  set -eu; setup_mode
  declare d sig pid rc started
  fixture; d=$(outdir)
  /bin/sleep 60 &
  bystander=$!
  trap 'kill "$bystander" 2>/dev/null || true; wait "$bystander" 2>/dev/null || true' EXIT
  for sig in TERM INT; do
    rc=0
    PATH="$SLOW:$SHIMS:$PATH" DISPATCH_SNAPSHOT_TIMEOUT_SECS=20 \
      perl -e '$SIG{INT}=$SIG{TERM}=$SIG{HUP}="DEFAULT"; exec @ARGV' \
      "$BIN/repo-state-check" snapshot "$R" "$d/file" 2> "$d/err" &
    pid=$!
    /bin/sleep 1
    started=$SECONDS
    ps -p "$pid" -o command= | grep -qF "$RUN_ID" || fail 'untagged CLI'
    kill -"$sig" "$pid"
    wait "$pid" || rc=$?
    case "$sig:$rc" in TERM:143|INT:130) ;; *) fail "signal $sig returned $rc" ;; esac
    [ $((SECONDS - started)) -le 2 ] || fail 'signal handling deferred'
    [ "$(first_line "$d/file")" = unreadable ] || fail 'signal left readable output'
    survivors
    no_state_dir "$d"; no_bound_dir
  done
  kill -0 "$bystander" || fail 'cleanup killed the bystander'

echo "PASS: case_cli_signals"
