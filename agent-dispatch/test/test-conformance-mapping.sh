#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/conformance-mapping.XXXXXX")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[ -f "$here/conformance/check-mapping.sh" ] || fail 'check-mapping.sh missing'
mkdir -p "$work/test/conformance/scenarios/sample"
cp "$here/conformance/check-mapping.sh" "$work/test/conformance/"
check=$work/test/conformance/check-mapping.sh
printf '# case: named check\n' > "$work/test/sample.sh"
printf 'probe sample-check stub\n' > "$work/test/conformance/live-smoke.sh"
printf 'id,scope,encodes_environmental_knowledge,text\r\nA,in,Y,"synthetic, quoted"\r\nB,out,Y,ignored\r\nC,in,N,ignored\r\n' > "$work/census.csv"
header() { printf 'census_id\tkind\tref\thow\n' > "$work/test/conformance/targets.tsv"; }
row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4-observed result changes}" >> "$work/test/conformance/targets.tsv"; }
run() {
  expected=$1; count=$2; shift 2
  rc=0
  bash "$check" "$work/census.csv" "$@" > "$work/output" 2>&1 || rc=$?
  [ "$rc" = "$expected" ] || fail "expected status $expected, got $rc"
  grep -qx "unmapped targets: $count" "$work/output" || fail 'missing unmapped count'
}
header; run 1 1
row A scenario absent; run 1 0
header; row A prose 'a written explanation'; run 1 0
header; row A scenario sample; run 0 0
run 1 1 --extra B
row B test 'test/sample.sh#named check'; run 0 0 --extra B
run 1 1 --extra B,C
row C smoke sample-check; run 0 0 --extra B,C
header; row A test 'test/sample.sh#absent check'; run 1 0
header; row A test 'test/absent.sh#named check'; run 1 0
header; row A test test/sample.sh; run 1 0
header; row A smoke absent-check; run 1 0
header; row A scenario ../sample; run 1 0
header; row A scenario sample; row B prose ignored; run 1 0
# Missing and whitespace-only explanations must be rejected.
header; row A scenario sample ''; run 1 1
header; row A scenario sample '   '; run 1 1
# Input failures still report a count without echoing external census contents.
printf 'wrong,header\nsynthetic,only\n' > "$work/census.csv"
run 1 0
printf 'PASS conformance mapping\n'
