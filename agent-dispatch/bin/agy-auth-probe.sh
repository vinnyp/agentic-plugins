#!/usr/bin/env bash
# Source-able agy OAuth freshness probe. Defines agy_auth_probe only.

agy_auth_probe() {
  local agy_bin="${AGY_BIN:-agy}"
  local output rc timeout_bin

  timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  fi

  if [ -n "$timeout_bin" ]; then
    output="$("$timeout_bin" 5s "$agy_bin" models </dev/null 2>&1)"
    rc=$?
  else
    printf '%s\n' 'agy auth probe: no timeout binary — probe is unbounded' >&2
    output="$("$agy_bin" models </dev/null 2>&1)"
    rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    printf '%s\n' 'agy auth probe healthy' >&2
    return 0
  fi

  if [ "$rc" -eq 124 ]; then
    printf '%s\n' 'agy auth probe timed out — proceeding' >&2
    return 2
  fi

  if printf '%s\n' "$output" | grep -qiE 'sign in to|not logged into antigravity|launch the cli without arguments|invalid_grant|oauth2|cannot fetch token|expired or revoked'; then
    printf '%s\n' "agy authentication required — re-authenticate agy: run \`agy\` and sign in" >&2
    return 7
  fi

  if printf '%s\n' "$output" | grep -qiE 'dial|connection refused|no such host|network|timeout|temporar|unreachable|EOF'; then
    printf '%s\n' 'agy auth probe inconclusive: network error — proceeding' >&2
    return 2
  fi

  printf '%s\n' 'agy auth probe inconclusive — proceeding' >&2
  return 2
}
