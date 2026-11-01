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
for signal in TERM HUP; do
  rm -f "$PROBE_PID_FILE"
  PATH="$SCN_TMP/tools:$PATH" CODEX_EXEC_PROBE_TIMEOUT=3s bash "$IMPL_BIN/coding-preflight.sh" codex </dev/null > "$SCN_TMP/out" 2> "$SCN_TMP/err" &
  pid=$!
  deadline=$((SECONDS + 5))
  while [ ! -s "$PROBE_PID_FILE" ]; do
    [ "$SECONDS" -lt "$deadline" ]
    /bin/sleep 0.1
  done
  stub=$(cat "$PROBE_PID_FILE")
  kill -"$signal" "$pid"
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  case "$signal" in TERM) [ "$rc" = 143 ] ;; HUP) [ "$rc" = 129 ] ;; esac
  kill -0 "$stub" 2>/dev/null
  # Observe the timer's cleanup without ever signalling the discovered stub PID.
  deadline=$((SECONDS + 15))
  while kill -0 "$stub" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ]
    /bin/sleep 0.1
  done
done
echo 'PASS: TERM and HUP to the preflight PID leave codex running until the probe timer (vinnyp/foundry#277)'
