# shellcheck shell=bash
# Use the Perl helper only without either GNU timer; resolve it while sourcing
# so later directory changes cannot change the helper path.
_timeout_source=${BASH_SOURCE[0]}
case "$_timeout_source" in */*) _timeout_dir=${_timeout_source%/*} ;; *) _timeout_dir=. ;; esac
_DISPATCH_TIMEOUT_HELPER=$(CDPATH='' cd -P -- "$_timeout_dir" && pwd)/portable-timeout
unset _timeout_source _timeout_dir

dispatch_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    printf '%s\n' timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    printf '%s\n' gtimeout
  elif [ -x "$_DISPATCH_TIMEOUT_HELPER" ] && perl -MPOSIX -MTime::HiRes -e 1 >/dev/null 2>&1; then
    printf '%s\n' "$_DISPATCH_TIMEOUT_HELPER"
  else
    return 1
  fi
}
