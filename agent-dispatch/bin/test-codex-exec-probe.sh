#!/usr/bin/env bash
. "${BASH_SOURCE[0]%/*}/lib/timeout-bin.sh"
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
# Execute only the command requested by the probe.
sed -i.bak 's/^Using only your shell tool, run exactly: //' "$LOG.stdin"
cd "$4" || exit 91
case "$BEHAVIOR" in
  copy) bash -e "$LOG.stdin" ;;
  wrong) echo wrong > nonce.out ;;
  empty) : ;;
  failure) echo bad request; exit 42 ;;
  limit) echo "usage limit reached"; exit 1 ;;
  term) echo "$$" > "$LOG.pid"; exec sleep 30 ;;
  host) echo 'timed out negotiating with the code-mode host' ;;
  host-copy) echo 'timed out negotiating with the code-mode host'; shasum -a 256 nonce.in > nonce.out ;;
  host-sleep) echo 'timed out negotiating with the code-mode host'; sleep 10 ;;
  sleep) sleep 10 ;;
esac
STUB
chmod +x "$TMP/bin/codex"
REAL_TIMEOUT=$(dispatch_timeout_bin) || { echo "FAIL: no usable timer" >&2; exit 1; }
REAL_TIMEOUT=$(command -v "$REAL_TIMEOUT") || exit 1
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
# 3s (widened from 1s for parallel runs): the copy stub must finish inside it; the sleep stubs (10s) must exceed it.
export CODEX_BIN="$TMP/bin/codex" CODEX_EXEC_PROBE_TIMEOUT=3s
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
  grep -q '^-k 10s 3s ' "$LOG.timeout" || fail 'timeout argv'
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
for bound in "" 0 0s -1 0.2s nonsense 6s 6m 6h 6; do
  export CODEX_EXEC_PROBE_TIMEOUT="$bound"
  codex_exec_probe > "$TMP/out" 2> "$TMP/err" || fail "bound $bound"
  case "$bound" in
    6*) expected="$bound" ;;
    *) expected=75s; grep -q 'invalid timeout' "$TMP/err" || fail 'invalid note' ;;
  esac
  grep -q "^-k 10s $expected " "$LOG.timeout" || fail "bound argv $bound"
done
unset CODEX_EXEC_PROBE_TIMEOUT
codex_exec_probe > "$TMP/out" 2> "$TMP/err" || fail 'default timeout'
grep -q '^-k 10s 75s ' "$LOG.timeout" || fail 'default timeout argv'
export CODEX_EXEC_PROBE_TIMEOUT=3s
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
# Signals target the function subshell; only its bounded child is signalled.
for signal in TERM HUP; do
  probe_launcher=()
  if command -v perl >/dev/null 2>&1; then
    probe_launcher=("$(command -v perl)" -e '$SIG{HUP}="DEFAULT"; exec @ARGV')
  elif [ "$signal" = HUP ]; then
    echo "SKIP HUP signal reset requires perl"
    continue
  fi
  export BEHAVIOR=term CODEX_EXEC_PROBE_TIMEOUT=60s
  rm -f "$LOG.pid"
  ${probe_launcher[@]+"${probe_launcher[@]}"} bash -c '. "$1"; codex_exec_probe; exit $?' _ "$BIN_DIR/codex-exec-probe.sh" > "$TMP/out" 2> "$TMP/err" &
  launcher=$!
  # The function is a subshell of this launcher.
  for ((i=0; i<300; i++)); do
    [ ! -f "$LOG.pid" ] || break
    sleep 0.05
  done
  [ -f "$LOG.pid" ] || fail "$signal stub not started"
  probe_pid="$(ps -o ppid= -p "$(ps -o ppid= -p "$(cat "$LOG.pid")" | tr -d ' ')" | tr -d ' ')"
  signal_start=$SECONDS
  kill -"$signal" "$probe_pid"
  wait "$launcher"
  rc=$?
  expected=143
  [ "$signal" != HUP ] || expected=129
  [ "$rc" -eq "$expected" ] || fail "$signal status: $rc"
  # KEPT: stub sleeps 30s under a 60s cap; <=5s proves the signal stops the child promptly.
  [ "$((SECONDS - signal_start))" -le 5 ] || fail "$signal exceeded 5s"
  ! kill -0 "$(cat "$LOG.pid")" 2>/dev/null || fail "$signal left child"
  [ ! -e "$(cat "$LOG.dir")" ] || fail "$signal left directory"
done
# A private PATH exposes exactly one digest tool, and no codex binary.
mkdir -p "$TMP/isolated-bin" "$HOME/.local/bin"
cp "$TMP/bin/codex" "$HOME/.local/bin/codex"
for utility in bash cat sed mkdir stat id find mktemp git grep tail awk head tr dirname readlink rm perl; do
  ln -s "$(command -v "$utility")" "$TMP/isolated-bin/$utility"
done
ln -s "$TMP/bin/timeout" "$TMP/isolated-bin/timeout"
export BEHAVIOR=copy
for digest_tool in shasum sha256sum; do
  digest_path="$(command -v "$digest_tool" || true)"
  if [ -z "$digest_path" ]; then
    digest_path="$TMP/sha256sum"
    printf '#!/bin/bash\nexec "%s" -a 256 "$@"\n' "$(command -v shasum)" > "$digest_path"
    chmod +x "$digest_path"
  fi
  ln -s "$digest_path" "$TMP/isolated-bin/$digest_tool"
  PATH="$TMP/isolated-bin" bash "$BIN_DIR/coding-preflight.sh" codex > "$TMP/out" 2> "$TMP/err"
  rc=$?
  [ "$rc" -eq 0 ] || fail "off-PATH codex / $digest_tool preflight: $(cat "$TMP/err")"
  grep -q '^CODEX_EXEC_PROBE=ok$' "$TMP/out" || fail 'off-PATH probe did not run'
  grep -qFx "CODING_BIN=$HOME/.local/bin/codex" "$TMP/out" || fail 'fallback binary not selected'
  case "$digest_tool" in
    shasum) command_text='shasum -a 256' ;;
    sha256sum) command_text=sha256sum ;;
  esac
  grep -qFx "$command_text nonce.in > nonce.out" "$LOG.stdin" || fail "digest prompt: $digest_tool"
  rm "$TMP/isolated-bin/$digest_tool"
done
echo 'ALL PASS: codex exec probe and preflight'
