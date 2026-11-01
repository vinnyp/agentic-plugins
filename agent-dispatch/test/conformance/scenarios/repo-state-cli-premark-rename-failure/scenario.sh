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
  mkdir "$d/bin"
  printf '#!/bin/sh\nexit 1\n' > "$d/bin/mv"
  chmod +x "$d/bin/mv"
  # The pre-mark is by rename only: when it cannot be made, nothing is written
  # through a symlink or opened at the output path.
  printf sentinel > "$d/sentinel"
  ln -s "$d/sentinel" "$d/link"
  PATH="$d/bin:$SHIMS:$PATH" "$BIN/repo-state-check" snapshot "$R" "$d/link" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail 'failed rename was accepted'
  [ "$(cat "$d/sentinel")" = sentinel ] || fail 'failed pre-mark wrote through a symlink'
  # A regular file sharing its inode with another path is never opened for writing.
  ln "$d/sentinel" "$d/hard"
  rc=0
  PATH="$d/bin:$SHIMS:$PATH" "$BIN/repo-state-check" snapshot "$R" "$d/hard" 2> "$d/err" || rc=$?
  [ "$rc" = 3 ] || fail 'failed rename on a regular file was accepted'
  [ "$(cat "$d/sentinel")" = sentinel ] || fail 'failed pre-mark wrote through a hard link'
  no_state_dir "$d"; no_bound_dir

echo "PASS: case_premark_rename_failure"
