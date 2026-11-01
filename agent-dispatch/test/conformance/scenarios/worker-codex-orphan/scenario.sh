#!/usr/bin/env bash
set -eu
# shellcheck disable=SC2034 # Shared fixture inputs.
id=worker-codex-orphan
# shellcheck disable=SC2034
runtime=codex
# shellcheck disable=SC2034
mode=edit
# shellcheck source=agent-dispatch/test/conformance/worker-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)/worker-fixture.sh"
