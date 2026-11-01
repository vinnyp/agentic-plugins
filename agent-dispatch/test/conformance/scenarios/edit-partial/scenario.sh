#!/usr/bin/env bash
set -eu
id=edit-partial
mode=empty
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
mkdir "$SCN_REPO/bin"
printf "# agent-dispatch-run-tests: partial runs exit 4\n" > "$SCN_REPO/bin/run-tests.sh"
git -C "$SCN_REPO" add .
git -C "$SCN_REPO" -c user.name=Conformance -c user.email=conformance@example.invalid commit -qm runner
"$IMPL_BIN/coding-dispatch.sh" codex "$SCN_REPO" "$SCN_TMP/brief" "bash bin/run-tests.sh --only sample"
