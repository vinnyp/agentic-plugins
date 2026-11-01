#!/usr/bin/env bash
set -eu
mkdir -p "$SCN_TMP/tools"
for utility in bash dirname readlink awk grep head sed cat; do
  ln -s "$(command -v "$utility")" "$SCN_TMP/tools/$utility"
done
cat > "$SCN_TMP/tools/agy" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = models ] || exit 98
printf 'gemini-3.8-flash-medium\tCoding\ngemini-4-argon-high\tReview\n'
STUB
chmod +x "$SCN_TMP/tools/agy"
rc=0
PATH="$SCN_TMP/tools" "$IMPL_BIN/coding-preflight.sh" agy > "$SCN_TMP/out" 2> "$SCN_TMP/err" || rc=$?
[ "$rc" -eq 0 ]
grep -q '^PREFLIGHT=ok$' "$SCN_TMP/out"
grep -q 'prompt-form probe could not run' "$SCN_TMP/err"
echo 'PASS: unavailable timer is advisory'
rm "$SCN_TMP/tools/agy"
for runtime in agy codex; do
  rc=0
  PATH="$SCN_TMP/tools" "$IMPL_BIN/coding-preflight.sh" "$runtime" > "$SCN_TMP/out" 2> "$SCN_TMP/err" || rc=$?
  [ "$rc" -eq 1 ]
  grep -q "^PREFLIGHT=error: $runtime binary not found" "$SCN_TMP/out"
  echo "PASS: missing $runtime binary refused"
done
