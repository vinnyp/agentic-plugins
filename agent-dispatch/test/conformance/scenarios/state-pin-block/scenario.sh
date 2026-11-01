#!/usr/bin/env bash
set -eu
# shellcheck disable=SC2034 # Shared fixture input.
id=state-pin-block
# shellcheck source=agent-dispatch/test/conformance/state-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/state-fixture.sh"
