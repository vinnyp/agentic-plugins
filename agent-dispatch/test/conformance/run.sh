#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
impl='' out='' only=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo 'missing option value' >&2; exit 2; }
  case "$1" in --impl) impl=$2 ;; --out) out=$2 ;; --only) only=$2 ;; *) exit 2 ;; esac
  shift 2
done
[ -d "$impl" ] && [ -n "$out" ] || { echo 'usage: run.sh --impl <dir> --out <dir> [--only <prefix>]' >&2; exit 2; }
IMPL_BIN=$(CDPATH='' cd -P -- "$impl" && pwd)
recording=${STUB_RECORDING:-}
root=${DISPATCH_CONFORMANCE_ROOT:-$HOME/.cache/agent-dispatch-conformance}
mkdir -p "$root"
root=$(CDPATH='' cd -P -- "$root" && pwd)
find "$root" -type d -name 'run.*' -mtime +1 -prune -exec rm -rf {} \;
run=$(mktemp -d "$root/run.XXXXXX")
[ -n "$run" ] || exit 1
trap 'rm -rf "$run"' EXIT
trap 'exit 130' INT
trap 'echo "conformance runner terminated" >&2; exit 143' TERM
mkdir "$run/tools"
for command in bash git jq perl python3; do
  location=$(command -v "$command") || { echo "missing tool: $command" >&2; exit 1; }
  ln -s "$location" "$run/tools/$command"
  [ "$command" != bash ] || bash_bin=$location
done
scenario_path=$IMPL_BIN:$here/stubs:$run/tools:/usr/bin:/bin
# shellcheck source=../../bin/lib/timeout-bin.sh
source "$here/../../bin/lib/timeout-bin.sh"
timer=$(dispatch_timeout_bin) || { echo 'no scenario timer available' >&2; exit 1; }
timer=$(command -v "$timer")
if [ -d "$out" ] && [ -n "$(ls -A "$out")" ]; then
  echo 'output directory must be empty' >&2; exit 1
fi
mkdir -p "$out"
out=$(CDPATH='' cd -- "$out" && pwd)
failed=0
executed=0
while IFS="$(printf '\t')" read -r golden_id rest; do
  case "$golden_id" in id|'') continue ;; esac
  [ -f "$here/scenarios/$golden_id/scenario.sh" ] || { echo "orphan golden: $golden_id" >&2; exit 1; }
done < "$here/goldens.tsv"
for scenario in "$here"/scenarios/*/scenario.sh; do
  [ -f "$scenario" ] || continue
  id=${scenario%/scenario.sh}; id=${id##*/}
  case "$id" in "$only"*) ;; *) continue ;; esac
  executed=$((executed + 1))
  row=$(awk -F '\t' -v id="$id" '$1 == id {print; n++} END {if(n != 1) exit 1}' "$here/goldens.tsv") || { echo "missing or duplicate golden: $id" >&2; exit 1; }
  # Preserve the empty issue column while validating the complete row.
  printf '%s\n' "$row" | awk -F '\t' 'NF == 5 && ($2 == "preserve" || ($2 == "known-defect" && $3 != "")) && $4 ~ /^[1-9][0-9]*$/ && $5 ~ /^[01]$/ {ok=1} END {exit !ok}' || { echo "invalid golden: $id" >&2; exit 1; }
  budget=$(printf '%s\n' "$row" | awk -F '\t' '{print $4}')
  retry=$(printf '%s\n' "$row" | awk -F '\t' '{print $5}')
  mkdir -p "$out/$id"
  printf '%s\n' "$IMPL_BIN" > "$out/$id/impl_bin"
  printf '%s\n' "$run" > "$out/$id/run_dir"
  attempt=0
  while :; do
    SCN_TMP=$run/$id/tmp
    SCN_REPO=$SCN_TMP/repo
    export SCN_TMP SCN_REPO
    [ -n "$SCN_TMP" ] || exit 1
    mkdir -p "$SCN_TMP/home" "$SCN_TMP/tmp" "$SCN_TMP/cache" "$SCN_TMP/config" "$SCN_TMP/data" "$SCN_TMP/state" "$SCN_TMP/runtime"
    printf '%s\n' "$SCN_TMP" > "$out/$id/scn_tmp"
    : > "$SCN_TMP/home/gitconfig"
    : > "$SCN_TMP/argv"
    for input in "$out/$id"/stdin.*; do
      [ ! -f "$input" ] || rm "$input"
    done
    rc=0
    env -i PATH="$scenario_path" HOME="$SCN_TMP/home" TMPDIR="$SCN_TMP/tmp" \
      XDG_CACHE_HOME="$SCN_TMP/cache" XDG_CONFIG_HOME="$SCN_TMP/config" \
      XDG_DATA_HOME="$SCN_TMP/data" XDG_STATE_HOME="$SCN_TMP/state" XDG_RUNTIME_DIR="$SCN_TMP/runtime" \
      GIT_CONFIG_GLOBAL="$SCN_TMP/home/gitconfig" GIT_CONFIG_NOSYSTEM=1 LC_ALL=C \
      GIT_AUTHOR_NAME=Conformance GIT_AUTHOR_EMAIL=conformance@example.invalid \
      GIT_COMMITTER_NAME=Conformance GIT_COMMITTER_EMAIL=conformance@example.invalid \
      GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
      IMPL_BIN="$IMPL_BIN" SCN_TMP="$SCN_TMP" SCN_REPO="$SCN_REPO" STUB_RECORDING="$recording" \
      "$timer" -k 1 "$budget" "$bash_bin" -c '
        "$1" "$2"
        status=$?
        printf "%s\n" "$status" > "$SCN_TMP/scenario-rc"
        exit "$status"
      ' conformance "$bash_bin" "$scenario" </dev/null > "$out/$id/stdout" 2> "$out/$id/stderr" || rc=$?
    timed_out=0
    if [ ! -f "$SCN_TMP/scenario-rc" ]; then
      case "$rc" in
        124|137) timed_out=1 ;;
        *) echo "scenario timer failed (rc=$rc)" >&2; exit 1 ;;
      esac
    fi
    printf '%s\n' "$rc" > "$out/$id/rc"
    cp "$SCN_TMP/argv" "$out/$id/argv"
    for input in "$SCN_TMP"/stdin.*; do
      [ ! -f "$input" ] || cp "$input" "$out/$id/"
    done
    rm -rf "$SCN_TMP"
    SCN_TMP=''
    if [ "$timed_out" = 1 ] && [ "$retry" = 1 ] && [ "$attempt" = 0 ]; then
      echo "retry $id (rc=$rc)" >&2
      printf 'retry %s (rc=%s)\n' "$id" "$rc" >> "$out/$id/retry.log"
      attempt=1
      continue
    fi
    break
  done
  # Nonzero application exits are observations; timeout is a harness failure.
  if [ "$timed_out" = 1 ]; then : > "$out/$id/harness-timeout"; failed=1; fi
done
[ "$executed" -gt 0 ] || { echo 'no scenarios executed' >&2; exit 1; }
exit "$failed"
