#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
check_key core.hooksPath '/x?token=SECRET' 2
! grep -q SECRET "$TMP/changes" || fail 'query secret leaked'
grep -Fxq 'config core.hookspath (local:file:.git/config): (absent) -> /x?<redacted>' "$TMP/changes" || fail 'hooksPath query redaction differs'
check_key 'url.https://example.invalid/?sig=SECRET.insteadof' example 2
! grep -q SECRET "$TMP/changes" || fail 'key query secret leaked'
grep -Fq '?<redacted>' "$TMP/changes" || fail 'key query redaction absent'
grep -Fxq 'config url.https://example.invalid/?<redacted> (local:file:.git/config): (absent) -> <changed>' "$TMP/changes" || fail 'key query redaction value differs'
echo 'PASS: query token and key redaction'
