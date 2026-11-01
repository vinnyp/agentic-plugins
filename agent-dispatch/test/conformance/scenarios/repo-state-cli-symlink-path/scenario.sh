#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# shellcheck source=agent-dispatch/test/conformance/repo-state-cli-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-cli-fixture.sh"
export CASE_MODE=timeout
  set -eu; setup_mode
  declare d
  fixture; d=$(outdir)
  mkfifo "$R/.git/FETCH_HEAD"
  ln -s "$R" "$d/repo"
  cli snapshot "$d/repo" "$d/file" 2> "$d/err"
  [ "$(grep -c '^unsafe' "$d/file")" = 1 ] || fail 'duplicate unsafe path'
  no_bound_dir

echo "PASS: case_symlink_path"
