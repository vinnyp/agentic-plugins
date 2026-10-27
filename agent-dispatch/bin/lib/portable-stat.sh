#!/usr/bin/env bash
# Source only. Probe on every source; inherited dialect hints are untrusted.
if stat --version >/dev/null 2>&1; then _PSTAT_DIALECT=gnu; else _PSTAT_DIALECT=bsd; fi
pstat_mode() {
  local mode
  if [ "$_PSTAT_DIALECT" = gnu ]; then
    mode=$(stat -c %a "$1") || return
    printf '%o\n' "$((8#$mode & 0777))"
  else
    stat -f %Lp "$1"
  fi
}
pstat_mtime() {
  if [ "$_PSTAT_DIALECT" = gnu ]; then stat -c %Y "$1"; else stat -f %m "$1"; fi
}
pstat_uid() {
  if [ "$_PSTAT_DIALECT" = gnu ]; then stat -c %u "$1"; else stat -f %u "$1"; fi
}
