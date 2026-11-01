#!/usr/bin/env bash
set -eu
# shellcheck disable=SC2034 # Shared fixture inputs.
id=worker-unknown
# shellcheck disable=SC2034
runtime=unknown
# shellcheck disable=SC2034
mode=edit
# shellcheck source=agent-dispatch/test/conformance/worker-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/worker-fixture.sh"
