#!/usr/bin/env bash
# Hermetic probe and preflight coverage; never invokes a provider binary.
set -uo pipefail
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$BIN_DIR/lib/test-env-reset.sh"
reset_dispatch_env
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CACHE_HOME="$TMP/cache" TMPDIR="$TMP/tmp"
mkdir -p "$TMP/bin" "$TMPDIR"
export PATH="$TMP/bin:$PATH" LOG="$TMP/calls"
unset CODEX_SANDBOX CODEX_SESSION_ID
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG"
case "$1" in
  --version) echo 'codex stub'; exit 0 ;;
  login) echo 'Logged in'; exit 0 ;;
esac
[ "$#" -eq 5 ] && [ "$1" = exec ] &&
  [ "$2" = --dangerously-bypass-approvals-and-sandbox ] &&
  [ "$3" = -C ] && [ "$5" = - ] || exit 90
printf '%s\n' "$4" > "$LOG.dir"
[ -d "$4/.git" ] && echo git > "$LOG.git"
cat > "$LOG.stdin"
cd "$4" || exit 91
case "$BEHAVIOR" in
  copy) shasum -a 256 nonce.in > nonce.out ;;
  wrong) echo wrong > nonce.out ;;
  empty) : ;;
  failure) echo bad request; exit 42 ;;
  limit) echo "usage limit reached"; exit 1 ;;
  term) echo "$$" > "$LOG.pid"; exec sleep 30 ;;
  host) echo 'timed out negotiating with the code-mode host' ;;
  host-copy) echo 'timed out negotiating with the code-mode host'; shasum -a 256 nonce.in > nonce.out ;;
  host-sleep) echo 'timed out negotiating with the code-mode host'; sleep 3 ;;
  sleep) sleep 3 ;;
esac
STUB
chmod +x "$TMP/bin/codex"
REAL_TIMEOUT="$(command -v timeout || command -v gtimeout)"
export REAL_TIMEOUT
cat > "$TMP/bin/timeout" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$LOG.timeout"
exec "$REAL_TIMEOUT" "$@"
SHIM
chmod +x "$TMP/bin/timeout"
# shellcheck disable=SC1091
. "$BIN_DIR/codex-exec-probe.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
export CODEX_BIN="$TMP/bin/codex" CODEX_EXEC_PROBE_TIMEOUT=1s
for behavior in copy wrong empty host host-copy host-sleep sleep failure limit missing; do
  export BEHAVIOR="$behavior"
  rm -f "$LOG" "$LOG.dir" "$LOG.git" "$LOG.stdin"
  expected=1
  [ "$behavior" != copy ] || expected=0
  [ "$behavior" != missing ] || expected=2
  (
    trap 'echo survived > "$LOG.trap"' EXIT
    [ "$behavior" != missing ] || CODEX_BIN="$TMP/missing"
    codex_exec_probe
  ) > "$TMP/out" 2> "$TMP/err"
  rc=$?
  [ "$rc" -eq "$expected" ] || fail "$behavior: rc=$rc expected=$expected"
  [ -f "$LOG.trap" ] || fail 'caller EXIT trap lost'
  rm "$LOG.trap"
  if [ "$behavior" = missing ]; then
    [ ! -f "$LOG" ] || fail 'missing binary invoked'
    continue
  fi
  grep -q '^-k 10s 1s ' "$LOG.timeout" || fail 'timeout argv'
  dir="$(cat "$LOG.dir")"
  [ "$(cat "$LOG")" = "exec --dangerously-bypass-approvals-and-sandbox -C $dir -" ] || fail argv
  case "$dir" in "$XDG_CACHE_HOME"/agent-dispatch/codex-probe.*) : ;; *) fail 'cache location' ;; esac
  case "$dir" in "$TMPDIR"/*) fail 'probe in TMPDIR' ;; esac
  [ -f "$LOG.git" ] || fail 'no git repository'
  grep -q 'shasum -a 256 nonce.in > nonce.out' "$LOG.stdin" || fail prompt
  [ ! -e "$dir" ] || fail cleanup
  case "$behavior" in
    host*) grep -q 'cannot reach its code-mode host' "$TMP/out" || fail 'host reason' ;;
    sleep) grep -q 'timed out after.*rc=124' "$TMP/out" || fail 'timeout reason' ;;
    failure) grep -q 'codex exec failed (rc=42): bad request' "$TMP/out" || fail 'failure reason' ;;
    limit) grep -q 'usage/rate limit' "$TMP/out" || fail 'limit reason' ;;
    wrong|empty) grep -q 'did not execute' "$TMP/out" || fail 'missing nonce reason' ;;
  esac
done
unset CODEX_BIN
for behavior in copy host skip inconclusive false; do
  export BEHAVIOR="$behavior"
  case "$behavior" in inconclusive|false) export BEHAVIOR=copy ;; esac
  rm -f "$LOG"
  unset CODING_PREFLIGHT_CODEX_PROBE
  [ "$behavior" != skip ] || export CODING_PREFLIGHT_CODEX_PROBE=0
  [ "$behavior" != false ] || export CODING_PREFLIGHT_CODEX_PROBE=false
  [ "$behavior" != inconclusive ] || chmod 777 "$XDG_CACHE_HOME/agent-dispatch"
  bash "$BIN_DIR/coding-preflight.sh" codex > "$TMP/out" 2> "$TMP/err"
  rc=$?
  grep -q '^login status$' "$LOG" || fail 'login not checked'
  if [ "$behavior" = host ]; then
    [ "$rc" -eq 1 ] || fail 'preflight failure rc'
    grep -q '^PREFLIGHT=error:.*code-mode host' "$TMP/out" || fail 'preflight host failure'
  else
    [ "$rc" -eq 0 ] || fail 'preflight success rc'
    grep -q '^PREFLIGHT=ok$' "$TMP/out" || fail 'preflight success'
  fi
  chmod 700 "$XDG_CACHE_HOME/agent-dispatch"
  case "$behavior" in
    copy|false) grep -q '^CODEX_EXEC_PROBE=ok$' "$TMP/out" || fail 'ok status' ;;
    skip|inconclusive) grep -q "^CODEX_EXEC_PROBE=$([ "$behavior" = skip ] && echo skipped || echo inconclusive)$" "$TMP/out" || fail 'status' ;;
  esac
  count="$(grep -c '^exec ' "$LOG" || true)"
  if [ "$behavior" = skip ] || [ "$behavior" = inconclusive ]; then
    [ "$count" -eq 0 ] || fail skip
  else
    [ "$count" -eq 1 ] || fail 'exec count'
  fi
done
# Invalid bounds must never disable timeout; valid integer units pass through.
export BEHAVIOR=copy
for bound in "" 0 0s -1 0.2s nonsense 2s 2m 2h 2; do
  export CODEX_EXEC_PROBE_TIMEOUT="$bound"
  codex_exec_probe > "$TMP/out" 2> "$TMP/err" || fail "bound $bound"
  case "$bound" in
    2*) expected="$bound" ;;
    *) expected=75s; grep -q 'invalid timeout' "$TMP/err" || fail 'invalid note' ;;
  esac
  grep -q "^-k 10s $expected " "$LOG.timeout" || fail "bound argv $bound"
done
unset CODEX_EXEC_PROBE_TIMEOUT
codex_exec_probe > "$TMP/out" 2> "$TMP/err" || fail 'default timeout'
grep -q '^-k 10s 75s ' "$LOG.timeout" || fail 'default timeout argv'
export CODEX_EXEC_PROBE_TIMEOUT=1s
# Ambient git state must not redirect init into a host repository.
git init -q "$TMP/host"
rm -f "$LOG.git"
export GIT_DIR="$TMP/host/.git" GIT_WORK_TREE="$TMP/host" GIT_INDEX_FILE="$TMP/host-index"
codex_exec_probe > "$TMP/out" 2> "$TMP/err" || fail 'ambient git'
[ ! -e "$TMP/host-index" ] || fail 'host index touched'
[ -f "$LOG.git" ] || fail 'ambient git redirected init'
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
# Relative cache roots are ignored; stale directories are pruned, fresh ones kept.
export HOME="$TMP/home" XDG_CACHE_HOME=relative-cache
mkdir -p "$HOME/.cache/agent-dispatch/codex-probe.stale" "$HOME/.cache/agent-dispatch/codex-probe.fresh"
touch -t 202001010000 "$HOME/.cache/agent-dispatch/codex-probe.stale"
codex_exec_probe > "$TMP/out" 2> "$TMP/err" || fail 'relative cache'
case "$(cat "$LOG.dir")" in "$HOME"/.cache/agent-dispatch/codex-probe.*) : ;; *) fail 'relative cache accepted' ;; esac
[ ! -d "$HOME/.cache/agent-dispatch/codex-probe.stale" ] || fail 'stale directory retained'
[ -d "$HOME/.cache/agent-dispatch/codex-probe.fresh" ] || fail 'fresh directory removed'
export XDG_CACHE_HOME="$TMP/cache"
# TERM targets the function subshell; only its bounded child is signalled.
export BEHAVIOR=term CODEX_EXEC_PROBE_TIMEOUT=60s
rm -f "$LOG.pid"
bash -c '. "$1"; codex_exec_probe; exit $?' _ "$BIN_DIR/codex-exec-probe.sh" > "$TMP/out" 2> "$TMP/err" &
launcher=$!
# The function is a subshell of this launcher.
for ((i=0; i<100; i++)); do
  [ ! -f "$LOG.pid" ] || break
  sleep 0.05
done
[ -f "$LOG.pid" ] || fail 'TERM stub not started'
probe_pid="$(ps -o ppid= -p "$(ps -o ppid= -p "$(cat "$LOG.pid")" | tr -d ' ')" | tr -d ' ')"
kill -TERM "$probe_pid"
wait "$launcher"
[ "$?" -eq 143 ] || fail 'TERM status'
! kill -0 "$(cat "$LOG.pid")" 2>/dev/null || fail 'TERM left child'
[ ! -e "$(cat "$LOG.dir")" ] || fail 'TERM left directory'
echo 'ALL PASS: codex exec probe and preflight'
