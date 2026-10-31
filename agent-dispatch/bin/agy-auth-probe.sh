#!/usr/bin/env bash
# Source-able agy OAuth freshness probe; retains successful output for model checks.

_probe_source=${BASH_SOURCE[0]}
case "$_probe_source" in */*) _probe_dir=${_probe_source%/*} ;; *) _probe_dir=. ;; esac
# shellcheck disable=SC1091
. "$_probe_dir/lib/timeout-bin.sh"
unset _probe_source _probe_dir

agy_auth_probe() {
  AGY_AUTH_PROBE_OUTPUT=""
  local agy_bin="${AGY_BIN:-agy}"
  local output rc timeout_bin output_file

  timeout_bin=""
  timeout_bin=$(dispatch_timeout_bin) || timeout_bin=""

  output_file="$(mktemp)" || return 2
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" -k 2s 5s "$agy_bin" models </dev/null >"$output_file" 2>&1
    rc=$?
  else
    printf '%s\n' 'agy auth probe: no timeout binary — probe is unbounded; no perl helper was usable either' >&2
    "$agy_bin" models </dev/null >"$output_file" 2>&1
    rc=$?
  fi
  output="$(cat "$output_file")"
  rm -f "$output_file"

  if [ "$rc" -eq 0 ]; then
    # shellcheck disable=SC2034  # consumed by sourcing callers
    AGY_AUTH_PROBE_OUTPUT="$output"
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
