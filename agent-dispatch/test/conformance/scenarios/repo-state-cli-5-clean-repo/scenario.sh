#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# shellcheck source=agent-dispatch/test/conformance/repo-state-cli-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-cli-fixture.sh"
export CASE_MODE=timeout
  set -eu; setup_mode
  declare d started
  fixture; d=$(outdir)
  started=$SECONDS
  cli snapshot "$R" "$d/cli"
  [ $((SECONDS - started)) -lt 45 ] || fail 'clean snapshot too slow'
  cli snapshot "$R" "$d/direct"
  [ "$(cut -f1 "$d/cli" | tr '\n' ' ')" = "$(cut -f1 "$d/direct" | tr '\n' ' ')" ] || fail 'line kinds or order differ from the library snapshot'
  "$REAL_GIT" -C "$R" config 'url.https://u:p@example.invalid/.insteadOf' x
  "$REAL_GIT" -C "$R" config remote.origin.pushurl 'https://user:secret@example.invalid/repo'
  cli snapshot "$R" "$d/one"
  cli snapshot "$R" "$d/two"
  rc_is 0 cli compare "$d/one" "$d/two"
  survivors; no_state_dir "$d"; no_bound_dir

echo "PASS: case_5_clean_repo"
