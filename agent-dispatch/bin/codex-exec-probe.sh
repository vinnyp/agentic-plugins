#!/usr/bin/env bash
# Source-able shell-tool readiness probe. The last stdout line is the reason;
# diagnostics stay on stderr. Subshell traps cannot overwrite the caller's traps.
codex_exec_probe() (
  local codex_bin="${CODEX_BIN:-codex}"
  local probe_timeout="${CODEX_EXEC_PROBE_TIMEOUT-75s}"
  local timeout_bin dir="" rc nonce digest digest_bin digest_command child="" cache owner_mode
  if ! [[ "$probe_timeout" =~ ^[1-9][0-9]*[smh]?$ ]]; then
    printf '%s\n' "codex exec probe: invalid timeout '$probe_timeout'; using 75s" >&2
    probe_timeout=75s
  fi
  trap '[ -z "$dir" ] || rm -rf "$dir"' EXIT
  # Bash 3.2 can unwind locals before EXIT on a signal: clean up here too.
  trap '[ -z "$child" ] || { kill -TERM "$child" 2>/dev/null; wait "$child"; }; [ -z "$dir" ] || rm -rf "$dir"; exit 130' INT
  trap '[ -z "$child" ] || { kill -TERM "$child" 2>/dev/null; wait "$child"; }; [ -z "$dir" ] || rm -rf "$dir"; exit 143' TERM
  trap '[ -z "$child" ] || { kill -TERM "$child" 2>/dev/null; wait "$child"; }; [ -z "$dir" ] || rm -rf "$dir"; exit 129' HUP
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
  if command -v shasum >/dev/null 2>&1; then
    digest_bin=shasum
  elif command -v sha256sum >/dev/null 2>&1; then
    digest_bin=sha256sum
  else
    printf '%s\n' 'codex exec probe: no shasum/sha256sum — cannot probe'
    return 2
  fi
  case "${XDG_CACHE_HOME:-}" in
    /*) cache="$XDG_CACHE_HOME/agent-dispatch" ;;
    *) cache="$HOME/.cache/agent-dispatch" ;;
  esac
  # Only the agent-dispatch parent needs private creation permissions.
  # shellcheck disable=SC2174
  if ! mkdir -p -m 700 "$cache"; then
    printf '%s\n' 'codex exec probe: cannot create cache directory'
    return 2
  fi
  owner_mode="$(stat -c '%u %a' "$cache" 2>/dev/null)" ||
    owner_mode="$(stat -f '%u %Lp' "$cache")"
  local owner mode
  read -r owner mode <<< "$owner_mode"
  if [ "$owner" != "$(id -u)" ] || ! [[ "$mode" =~ ^[0-7]{3,4}$ ]] ||
     (( (8#$mode & 8#022) != 0 )); then
    printf '%s\n' "codex exec probe: cache must be owned by current user and not group/world-writable; run: chmod 700 '$cache'"
    return 2
  fi
  find "$cache" -name 'codex-probe.*' -type d -mmin +1440 -prune -exec rm -rf {} +
  if ! dir="$(mktemp -d "$cache/codex-probe.XXXXXX")"; then
    printf '%s\n' 'codex exec probe: cannot create probe directory'
    return 2
  fi
  if ! git -C "$dir" init -q; then
    printf '%s\n' 'codex exec probe: cannot initialize probe repository'
    return 2
  fi
  if [ "$digest_bin" = shasum ]; then
    digest_command='shasum -a 256'
  else
    digest_command=sha256sum
  fi
  nonce="CODEX_PROBE_$$_${RANDOM}_${RANDOM}"
  if ! printf '%s\n' "$nonce" > "$dir/nonce.in" ||
     ! printf '%s\n' "Using only your shell tool, run exactly: $digest_command nonce.in > nonce.out" > "$dir/.prompt"; then
    printf '%s\n' 'codex exec probe: cannot write probe inputs'
    return 2
  fi
  if [ "$digest_bin" = shasum ]; then
    digest="$(shasum -a 256 "$dir/nonce.in")" || return 2
  else
    digest="$(sha256sum "$dir/nonce.in")" || return 2
  fi
  digest="${digest%% *}"
  # A regular file avoids waiting on a leaked helper holding a capture pipe open.
  "$timeout_bin" -k 10s "$probe_timeout" "$codex_bin" exec --dangerously-bypass-approvals-and-sandbox -C "$dir" - < "$dir/.prompt" > "$dir/.probe.out" 2>&1 &
  child=$!
  wait "$child"
  rc=$?
  child=""
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
  if [ -f "$dir/nonce.out" ] && [ "$(awk 'NR == 1 { print $1; exit }' "$dir/nonce.out")" = "$digest" ]; then
    printf '%s\n' 'codex exec probe: shell tool hashed the nonce — OK' >&2
    printf '%s\n' 'codex exec probe: OK'
    return 0
  fi
  tail -5 "$dir/.probe.out" >&2
  if grep -qiE 'usage limit|rate limit(ed)?|too many requests|you.?ve (hit|reached) your|reached (the|your) (usage|rate) limit|quota (exceeded|reached)|resets? (at|in)|try again (after|in|later)|limit will reset' "$dir/.probe.out"; then
    printf '%s\n' "codex exec usage/rate limit (rc=$rc): $(tail -1 "$dir/.probe.out")"
  elif [ "$rc" -ne 0 ]; then
    printf '%s\n' "codex exec failed (rc=$rc): $(tail -1 "$dir/.probe.out")"
  else
    printf '%s\n' "codex shell tool did not execute (rc=$rc)"
  fi
  return 1
)
