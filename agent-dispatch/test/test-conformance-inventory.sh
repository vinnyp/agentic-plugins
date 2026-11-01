#!/usr/bin/env bash
set -eu
here=$(cd "$(dirname "$0")" && pwd)
contract=$here/conformance/contract
plugin=$(cd "$here/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/conformance-inventory-test.XXXXXX")
[ -n "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
[ -f "$contract/inventory.sh" ] || fail 'inventory.sh missing'
bash "$contract/inventory.sh" > "$tmp/actual"
cmp -s "$contract/inventory.tsv" "$tmp/actual" || fail 'inventory differs from committed inventory.tsv'
cp "$plugin/docs/commands.md" "$tmp/commands.md"
printf '\n## `coding-dispatch.sh`\n\n`--fake-inventory-flag` regression sentinel\n' >> "$tmp/commands.md"
bash "$contract/inventory.sh" --docs "$tmp/commands.md" > "$tmp/changed"
if cmp -s "$contract/inventory.tsv" "$tmp/changed"; then
  fail 'fake documentation flag was not detected'
fi
grep -q 'flag.*--fake-inventory-flag' "$tmp/changed" || fail 'fake flag row missing'
# One-way coverage: implementation additions must be represented in the contract.
coverage() {
  local checked_bin=$1
for command in $(awk -F '\t' 'NR>1 {print $1}' "$tmp/actual" | LC_ALL=C sort -u); do
  perl -ne '
    while (/(?:^\s*|\bin\s+|;;\s*)((?:--[a-zA-Z0-9-]+|-[a-zA-Z])(?:\|(?:--[a-zA-Z0-9-]+|-[a-zA-Z]))*)\)/g) {
      my $arms=$1; while ($arms =~ /(--[a-zA-Z0-9-]+)/g) {print "flag\t$1\n";}
    }
    while (/\[\s*"?\$1"?\s*(?:=|==)\s*["\x27]?(--[a-zA-Z0-9-]+)/g) {print "flag\t$1\n";}
    while (/\bexit\s+([0-9]+)\b/g) {print "exit\t$1\n";}
  ' "$checked_bin/$command" | LC_ALL=C sort -u > "$tmp/required"
  awk -F '\t' -v command="$command" '$1==command {print $2 "\t" $3}' "$tmp/actual" | LC_ALL=C sort -u > "$tmp/listed"
  while IFS= read -r row; do
    grep -Fqx -- "$row" "$tmp/listed" || { echo "$command missing $row" >&2; return 1; }
  done < "$tmp/required"
done
}
coverage "$plugin/bin" || fail 'implementation coverage'
mkdir "$tmp/bin"
cp "$plugin/bin/"* "$tmp/bin/" 2>/dev/null || :
printf '\nexit 77\n' >> "$tmp/bin/coding-dispatch.sh"
if coverage "$tmp/bin" > "$tmp/coverage-log" 2>&1; then fail 'fake exit 77 accepted'; fi
grep -q 'missing.*77' "$tmp/coverage-log" || fail 'fake exit diagnostic'
cp "$plugin/bin/coding-dispatch.sh" "$tmp/bin/coding-dispatch.sh"
printf '\nif [ "$1" = "--fake-if-flag" ]; then :; fi\n' >> "$tmp/bin/coding-dispatch.sh"
if coverage "$tmp/bin" > "$tmp/coverage-log" 2>&1; then fail 'fake if flag accepted'; fi
grep -q 'fake-if-flag' "$tmp/coverage-log" || fail 'if flag diagnostic'
for name in AND JSON HEAD XXXXXX; do
  if awk -F '\t' -v name="$name" '$2=="env" && $3==name {found=1} END {exit !found}' "$tmp/actual"; then fail "spurious env $name"; fi
done
for name in RUNTIME MODEL TIMEOUT; do
  awk -F '\t' -v name="$name" '$1=="dispatch-worker" && $2=="env" && $3==name {ok=1} END {exit !ok}' "$tmp/actual" || fail "missing $name"
done
if awk -F '\t' '$1=="agent-dispatch-doctor" && $2=="env" && $3=="AGY_MODEL" {found=1} END {exit !found}' "$tmp/actual"; then
  fail 'environment table attributed to wrong command'
fi
printf 'PASS conformance inventory and documentation drift\n'
