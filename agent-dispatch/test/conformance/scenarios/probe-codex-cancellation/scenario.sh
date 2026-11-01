#!/usr/bin/env bash
set -euo pipefail
mkdir "$SCN_TMP/tools"
export PROBE_PID_FILE="$SCN_TMP/stub-pid"
cat > "$SCN_TMP/tools/codex" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) echo 'codex stub'; exit 0 ;;
  login) echo 'Logged in'; exit 0 ;;
esac
echo $$ > "$PROBE_PID_FILE"
exec /bin/sleep 12
SH
chmod +x "$SCN_TMP/tools/codex"
failed=0
for signal in TERM HUP; do
  rm -f "$PROBE_PID_FILE"
  PATH="$SCN_TMP/tools:$PATH" CODEX_EXEC_PROBE_TIMEOUT=20s bash "$IMPL_BIN/coding-preflight.sh" codex > "$SCN_TMP/out" 2> "$SCN_TMP/err" &
  pid=$!
  deadline=$((SECONDS + 5))
  while [ ! -s "$PROBE_PID_FILE" ]; do
    [ "$SECONDS" -lt "$deadline" ]
    /bin/sleep 0.1
  done
  stub=$(cat "$PROBE_PID_FILE")
  deadline=$((SECONDS + 5))
  kill -"$signal" "$pid"
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  case "$signal" in TERM) [ "$rc" = 143 ] ;; HUP) [ "$rc" = 129 ] ;; esac
  if [ "$SECONDS" -gt "$deadline" ]; then
    echo "FAIL: $signal preflight exit exceeded five seconds"
    failed=1
  fi
  while kill -0 "$stub" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do
    /bin/sleep 0.1
  done
  if kill -0 "$stub" 2>/dev/null; then
    echo "FAIL: $signal left codex stub alive after five seconds"
    failed=1
  fi
  # The probe timer bounds failure cleanup too; never signal a discovered PID.
  cleanup_deadline=$((SECONDS + 15))
  while kill -0 "$stub" 2>/dev/null; do
    [ "$SECONDS" -lt "$cleanup_deadline" ]
    /bin/sleep 0.1
  done
  [ -z "$(find "$XDG_CACHE_HOME" -type d -name 'codex-probe.*')" ]
done
[ "$failed" = 0 ] || exit 1
echo 'PASS: codex TERM and HUP cancellation cleans child and probe'
