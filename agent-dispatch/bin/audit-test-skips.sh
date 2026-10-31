#!/usr/bin/env bash
# Audit kept suite logs against the stock environment contract.
set -uo pipefail
if [ "$#" != 2 ] || [ ! -r "$2" ]; then
  echo 'usage: audit-test-skips.sh <rundir> <manifest>' >&2
  exit 2
fi
rundir=$1 manifest=$2 violations=0
bad() { printf 'audit-test-skips: %s\n' "$*"; violations=1; }
[ -d "$rundir" ] || bad 'missing run directory'
if [ ! -f "$rundir/suites" ] || [ ! -s "$rundir/suites" ]; then
  bad 'missing or empty suites'
  exit 1
fi
while IFS= read -r row || [ -n "$row" ]; do
  case "$row" in ''|'#'*) continue ;; esac
  IFS=$'\t' read -r suite kind pattern extra <<< "$row"
  if [ -z "$suite" ] || [ -z "$pattern" ] || [ -n "${extra:-}" ]; then bad "invalid manifest row: $row"; fi
  case "$kind" in skip|require) ;; *) bad "unknown manifest kind: $kind" ;; esac
done < "$manifest"
while :; do
  suite=''
  if IFS= read -r -d '' suite; then
    :
  elif [ -n "$suite" ]; then
    bad 'unterminated suite entry'
  else
    break
  fi
  key=${suite//\//__}
  log="$rundir/$key.log"
  [ -f "$log" ] || bad "$suite: missing log"
  if [ ! -f "$rundir/$key.rc" ] || ! awk 'NR != 1 || $0 != "0" {bad=1} END {exit (NR != 1 || bad)}' "$rundir/$key.rc"; then
    bad "$suite: missing or unsuccessful rc"
  fi
  for suffix in why leader-rc; do
    [ ! -e "$rundir/$key.$suffix" ] || bad "$suite: unexpected $suffix"
  done
  [ -f "$log" ] || continue
  while IFS= read -r line || [ -n "$line" ]; do
    for notice in 'no timeout/gtimeout binary' UNBOUNDED 'no timeout binary' "no 'timeout'/'gtimeout'" 'SKIPPING (cannot bound' 'probe is unbounded'; do
      case "$line" in *"$notice"*) bad "$suite: degraded notice: $line" ;; esac
    done
    if printf '%s\n' "$line" | grep -Eq '(^|[^[:alnum:]_])(SKIP|SKIPPED)([^[:alnum:]_]|$)'; then
      allowed=0
      while IFS=$'\t' read -r owner kind pattern || [ -n "$owner$kind$pattern" ]; do
        [ "$owner" = "$suite" ] && [ "$kind" = skip ] || continue
        if printf '%s\n' "$line" | grep -Exq -- "$pattern"; then allowed=1; break; fi
      done < "$manifest"
      [ "$allowed" = 1 ] || bad "$suite: unapproved skip: $line"
    fi
  done < "$log"
done < "$rundir/suites"
while IFS=$'\t' read -r owner kind pattern || [ -n "$owner$kind$pattern" ]; do
  [ "$kind" = require ] || continue
  key=${owner//\//__}
  grep -Fq -- "$pattern" "$rundir/$key.log" 2>/dev/null || bad "$owner: missing required line: $pattern"
done < "$manifest"
exit "$violations"
