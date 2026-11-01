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
  mkfifo "$R/.git/FETCH_HEAD" "$R/.git/escape"$'\033'
  cli snapshot "$R" "$d/file" 2> "$d/err" || rc=$?
  [ "$rc" = 0 ] || fail "expected 0, got $rc"
  grep -q 'repo-state-check: baseline contains special files:.*FETCH_HEAD' "$d/err" || fail 'baseline warning missing'
  [ "$(first_line "$d/file")" = repo ] || fail 'not a snapshot'
  ! LC_ALL=C grep -q $'\033' "$d/err" || fail 'raw escape in stderr'
  grep -Fq '\x1b' "$d/err" || fail 'escaped filename missing' 
  survivors; no_state_dir "$d"; no_bound_dir

echo "PASS: case_9_healthy_special_file"
