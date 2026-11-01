#!/usr/bin/env bash
set -eu
id=edit-signal-changes-worktree
mode=signal-changes
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/edit-fixture.sh"
python3 "$here/edit-signal.py"
