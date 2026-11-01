#!/usr/bin/env bash
set -eu
# shellcheck disable=SC2034 # Shared fixture input.
id=capture-alias-cleanup
# shellcheck source=agent-dispatch/test/conformance/capture-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/capture-fixture.sh"
