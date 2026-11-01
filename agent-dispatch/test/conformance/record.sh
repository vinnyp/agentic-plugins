#!/usr/bin/env bash
# Explicitly invoked real-agent capture; tests supply stubs on PATH.
# agy-under-TMPDIR recording is the smoke check's job, not record.sh's.
# All agent work happens in a disposable fixture under the conformance root.
set -eu
umask 077
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bin=$(CDPATH='' cd "$here/../../bin" && pwd -P)
# shellcheck source=../../bin/lib/timeout-bin.sh
. "$bin/lib/timeout-bin.sh"
timer=$(dispatch_timeout_bin) || exit 1
[ "$#" -eq 2 ] || { echo 'usage: record.sh <codex|agy|claude> <name>' >&2; exit 1; }
runtime=$1
name=$2
case "$runtime" in codex|agy|claude) ;; *) exit 1 ;; esac
case "$name" in ''|.|..|*[!a-zA-Z0-9_-]*) exit 1 ;; esac
root=${DISPATCH_CONFORMANCE_ROOT:-$HOME/.cache/agent-dispatch-conformance}
mkdir -p "$root"
root=$(CDPATH='' cd -- "$root" && pwd -P)
tmp_root=$(CDPATH='' cd -- "${TMPDIR:-/tmp}" && pwd -P)
case "$root/" in "$tmp_root/"*) echo 'conformance root must be outside TMPDIR' >&2; exit 1 ;; esac
work=$(mktemp -d "$root/record.XXXXXX")
[ -n "$work" ] || exit 1
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$work/repo" "$work/staging"
git -C "$work/repo" init -q
printf 'Public recording fixture.\n' > "$work/repo/README.md"
git -C "$work/repo" add README.md
git -C "$work/repo" -c commit.gpgsign=false -c core.hooksPath=/dev/null -c user.name='Fixture Author' -c user.email='fixture@example.invalid' commit -qm 'Initial fixture'
prompt='Read README.md and reply with exactly: fixture ready. Do not change files or run other commands.'
rc=0
(
  cd "$work/repo"
  case "$runtime" in
    codex) "$timer" -k 1 "${DISPATCH_CONFORMANCE_TIMEOUT:-20}" codex exec --sandbox read-only -C "$work/repo" - <<< "$prompt" ;;
    agy) "$timer" -k 1 "${DISPATCH_CONFORMANCE_TIMEOUT:-20}" agy --dangerously-skip-permissions --add-dir "$work/repo" <<< "$prompt" ;;
    claude) "$timer" -k 1 "${DISPATCH_CONFORMANCE_TIMEOUT:-20}" claude --permission-mode plan --print "$prompt" ;;
  esac
) > "$work/staging/stdout" 2> "$work/staging/stderr" || rc=$?
printf '%s\n' "$rc" > "$work/staging/rc"
bash "$here/scrub.sh" "$work/staging" || { echo 'recording refused by scrubber' >&2; exit 1; }
# Publish only scrubbed files. Refuse to overwrite an existing recording.
mkdir -p "$here/recordings/$runtime"
destination=$here/recordings/$runtime/$name
mkdir "$destination" || exit 1
cp "$work/staging/stdout" "$work/staging/stderr" "$work/staging/rc" "$destination/"
