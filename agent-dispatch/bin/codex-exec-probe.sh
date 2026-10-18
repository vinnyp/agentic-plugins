#!/usr/bin/env bash
# Source-able shell-tool readiness probe. The last stdout line is the reason;
# diagnostics stay on stderr. Subshell traps cannot overwrite the caller's traps.
codex_exec_probe() (
  local codex_bin="${CODEX_BIN:-codex}"
  local probe_timeout="${CODEX_EXEC_PROBE_TIMEOUT:-120s}"
  local timeout_bin dir="" rc nonce
  trap 'rm -rf "$dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

  if ! command -v "$codex_bin" >/dev/null 2>&1; then
    printf '%s\n' "codex exec probe: '$codex_bin' not found — cannot probe"
    return 2
  fi
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
  else
    printf '%s\n' 'codex exec probe: no timeout/gtimeout — install coreutils to bound the probe'
    return 2
  fi
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/agent-dispatch"
  if ! mkdir -p "$cache" || ! dir="$(mktemp -d "$cache/codex-probe.XXXXXX")"; then
    printf '%s\n' 'codex exec probe: cannot create cache directory'
    return 2
  fi
  if ! git -C "$dir" init -q; then
    printf '%s\n' 'codex exec probe: cannot initialize probe repository'
    return 2
  fi
  nonce="CODEX_PROBE_$$_${RANDOM}_${RANDOM}"
  if ! printf '%s\n' "$nonce" > "$dir/nonce.in" ||
     ! printf '%s\n' 'Using only your shell tool (do not use file-read, file-write or patch tools), run exactly this command in the working directory, then reply DONE: cp nonce.in nonce.out' > "$dir/.prompt"; then
    printf '%s\n' 'codex exec probe: cannot write probe inputs'
    return 2
  fi
  # A regular file avoids waiting on a leaked helper holding a capture pipe open.
  "$timeout_bin" -k 10s "$probe_timeout" "$codex_bin" exec --dangerously-bypass-approvals-and-sandbox -C "$dir" - < "$dir/.prompt" > "$dir/.probe.out" 2>&1
  rc=$?
  if grep -q 'code-mode host' "$dir/.probe.out"; then
    tail -5 "$dir/.probe.out" >&2
    printf '%s\n' "codex shell tool cannot reach its code-mode host — common after a codex upgrade; run 'codex-code-mode-host --help' once to warm it, and check macOS quarantine/Gatekeeper on the codex cask binaries"
    return 1
  fi
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    tail -5 "$dir/.probe.out" >&2
    printf '%s\n' "codex exec probe timed out after $probe_timeout (rc=$rc) — codex or its shell helper hung; check codex-code-mode-host / Gatekeeper, or raise CODEX_EXEC_PROBE_TIMEOUT"
    return 1
  fi
  if [ -f "$dir/nonce.out" ] && cmp -s "$dir/nonce.in" "$dir/nonce.out"; then
    printf '%s\n' 'codex exec probe: shell tool copied the nonce — OK' >&2
    printf '%s\n' 'codex exec probe: OK'
    return 0
  fi
  tail -5 "$dir/.probe.out" >&2
  printf '%s\n' "codex shell tool did not execute (rc=$rc)"
  return 1
)
