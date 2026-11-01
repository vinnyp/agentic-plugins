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
  mkfifo "$d/fifo"
  cli snapshot "$R" "$d/fifo"
  [ -f "$d/fifo" ] && [ ! -L "$d/fifo" ] || fail 'FIFO output not replaced'
  [ "$(first_line "$d/fifo")" = repo ] || fail 'FIFO output is not a snapshot'
  mkfifo "$d/fifo2"
  cli snapshot relative "$d/fifo2" 2> /dev/null || rc=$?
  [ "$rc" = 3 ] || fail "relative repo expected 3, got $rc"
  [ -f "$d/fifo2" ] && [ ! -L "$d/fifo2" ] || fail 'rejected FIFO output not replaced'
  [ "$(cat "$d/fifo2")" = unreadable ] || fail 'pre-mark missing'
  mkdir "$d/dir"
  rc=0; cli snapshot "$R" "$d/dir" 2> /dev/null || rc=$?
  [ "$rc" = 3 ] || fail "directory output expected 3, got $rc"
  [ -z "$(ls -A "$d/dir")" ] || fail 'a file was written into the output directory'
  printf sentinel > "$d/sentinel"
  ln -s "$d/sentinel" "$d/link"
  cli snapshot "$R" "$d/link"
  [ "$(cat "$d/sentinel")" = sentinel ] || fail 'symlink target modified'
  [ -f "$d/link" ] && [ ! -L "$d/link" ] || fail 'symlink output not replaced'
  survivors; no_state_dir "$d"; no_bound_dir

echo "PASS: case_13_hostile_output_path"
