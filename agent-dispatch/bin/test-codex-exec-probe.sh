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
  copy) cp nonce.in nonce.out ;;
  wrong) echo wrong > nonce.out ;;
  empty) : ;;
  host) echo 'timed out negotiating with the code-mode host' ;;
  host-copy) echo 'timed out negotiating with the code-mode host'; cp nonce.in nonce.out ;;
  host-sleep) echo 'timed out negotiating with the code-mode host'; sleep 2 ;;
  sleep) sleep 2 ;;
esac
STUB
chmod +x "$TMP/bin/codex"
# shellcheck disable=SC1091
. "$BIN_DIR/codex-exec-probe.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
export CODEX_BIN="$TMP/bin/codex" CODEX_EXEC_PROBE_TIMEOUT=0.2s
for behavior in copy wrong empty host host-copy host-sleep sleep missing; do
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
  dir="$(cat "$LOG.dir")"
  [ "$(cat "$LOG")" = "exec --dangerously-bypass-approvals-and-sandbox -C $dir -" ] || fail argv
  case "$dir" in "$XDG_CACHE_HOME"/agent-dispatch/codex-probe.*) : ;; *) fail 'cache location' ;; esac
  case "$dir" in "$TMPDIR"/*) fail 'probe in TMPDIR' ;; esac
  [ -f "$LOG.git" ] || fail 'no git repository'
  grep -q 'cp nonce.in nonce.out' "$LOG.stdin" || fail prompt
  [ ! -e "$dir" ] || fail cleanup
  case "$behavior" in
    host*) grep -q 'cannot reach its code-mode host' "$TMP/out" || fail 'host reason' ;;
    sleep) grep -q 'timed out after.*rc=124' "$TMP/out" || fail 'timeout reason' ;;
    wrong|empty) grep -q 'did not execute' "$TMP/out" || fail 'missing nonce reason' ;;
  esac
done
for behavior in copy host skip; do
  export BEHAVIOR="$behavior"
  rm -f "$LOG"
  unset CODING_PREFLIGHT_CODEX_PROBE
  [ "$behavior" != skip ] || export CODING_PREFLIGHT_CODEX_PROBE=0
  bash "$BIN_DIR/coding-preflight.sh" codex > "$TMP/out" 2> "$TMP/err"
  rc=$?
  grep -q '^login status$' "$LOG" || fail 'login not checked'
  if [ "$behavior" = host ]; then
    [ "$rc" -eq 1 ] && grep -q '^PREFLIGHT=error:.*code-mode host' "$TMP/out" || fail 'preflight host failure'
  else
    [ "$rc" -eq 0 ] && grep -q '^PREFLIGHT=ok$' "$TMP/out" || fail 'preflight success'
  fi
  count="$(grep -c '^exec ' "$LOG" || true)"
  if [ "$behavior" = skip ]; then
    [ "$count" -eq 0 ] && grep -q skipped "$TMP/err" || fail skip
  else
    [ "$count" -eq 1 ] || fail 'exec count'
  fi
done
echo 'ALL PASS: codex exec probe and preflight'
