#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
check_key core.hooksPath '/x?token=SECRET' 2
! grep -q SECRET "$TMP/changes" || fail 'query secret leaked'
echo 'PASS: query token redaction'
