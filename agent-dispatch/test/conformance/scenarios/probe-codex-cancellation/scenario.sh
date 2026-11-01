#!/usr/bin/env bash
set -euo pipefail
fail() { echo "FAIL: $*"; exit 1; }
mkdir "$SCN_TMP/tools"
export PROBE_PID_FILE="$SCN_TMP/stub-pid" PROBE_DIR_FILE="$SCN_TMP/stub-dir"
cat > "$SCN_TMP/tools/codex" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) echo 'codex stub'; exit 0 ;;
  login) echo 'Logged in'; exit 0 ;;
esac
echo "$4" > "$PROBE_DIR_FILE"
echo $$ > "$PROBE_PID_FILE"
exec /bin/sleep 12
SH
chmod +x "$SCN_TMP/tools/codex"
for signal in INT TERM HUP; do
  rm -f "$PROBE_PID_FILE" "$PROBE_DIR_FILE"
  PATH="$SCN_TMP/tools:$PATH" CODEX_EXEC_PROBE_TIMEOUT=20s perl -e '$SIG{INT}="DEFAULT"; $SIG{HUP}=$SIG{TERM}="DEFAULT"; setpgrp(0,0) or die; exec @ARGV' bash "$IMPL_BIN/coding-preflight.sh" codex </dev/null > "$SCN_TMP/out" 2> "$SCN_TMP/err" &
  pid=$!
  deadline=$((SECONDS + 5))
  while [ ! -s "$PROBE_PID_FILE" ]; do
    [ "$SECONDS" -lt "$deadline" ] || fail "$signal: stub did not publish its PID before deadline"
    /bin/sleep 0.1
  done
  stub=$(cat "$PROBE_PID_FILE")
  probe_dir=$(cat "$PROBE_DIR_FILE")
  [ -d "$probe_dir" ] || fail "$signal: recorded probe directory absent before signal: $probe_dir"
  kill -"$signal" -- "-$pid"
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  case "$signal" in INT) [ "$rc" = 130 ] || fail "INT: expected 130, got $rc" ;; TERM) [ "$rc" = 143 ] || fail "TERM: expected 143, got $rc" ;; HUP) [ "$rc" = 129 ] || fail "HUP: expected 129, got $rc" ;; esac
  deadline=$((SECONDS + 5))
  while kill -0 "$stub" 2>/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || fail "$signal: child survived process-group cancellation deadline"
    /bin/sleep 0.1
  done
  # Probe cleanup follows child exit, so give directory removal its own deadline.
  deadline=$((SECONDS + 5))
  while [ -e "$probe_dir" ]; do
    [ "$SECONDS" -lt "$deadline" ] || fail "$signal: probe directory survived cleanup deadline: $probe_dir"
    /bin/sleep 0.1
  done
done
echo 'PASS: codex INT, TERM and HUP to the process group clean child and probe'
