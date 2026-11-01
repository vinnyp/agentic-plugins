#!/usr/bin/env bash
set -eu
# shellcheck disable=SC2034 # Shared fixture inputs.
id=worker-claude-timeout
# shellcheck disable=SC2034
runtime=claude
# shellcheck disable=SC2034
mode=review
# shellcheck source=agent-dispatch/test/conformance/worker-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/worker-fixture.sh"
