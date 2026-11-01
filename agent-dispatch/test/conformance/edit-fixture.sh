# shellcheck shell=bash
# Shared fixture only; never sources implementation internals.
set -eu
: "${id:?}" "${mode:?}"
here=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$SCN_REPO" "$SCN_TMP/bin"
git -C "$SCN_REPO" init -q -b main
printf 'base\n' > "$SCN_REPO/tracked.txt"
printf '_coding-result.json\n' > "$SCN_REPO/.gitignore"
git -C "$SCN_REPO" add .
git -C "$SCN_REPO" -c user.name=Conformance -c user.email=conformance@example.invalid commit -qm fixture
printf 'Edit tracked.txt.\n' > "$SCN_TMP/brief"
printf '### Task 1: Edit\nModify tracked.txt.\n' > "$SCN_TMP/plan"
export STUB_RECORDING="$here/scenarios/$id/recording"
export EDIT_MODE=$mode EDIT_REPLAY="$here/stubs/codex"
cat > "$SCN_TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -eu
wd=$PWD
args=("$@")
while [ "$#" -gt 0 ]; do
  if [ "$1" = -C ]; then wd=$2; shift 2; else shift; fi
done
case "$EDIT_MODE" in
  task2) if [ ! -f "$SCN_TMP/task1" ]; then printf 'edited\n' >> "$wd/tracked.txt"; fi ;;
  noop*) printf '{"status":"complete","files_written":[]}' > "$wd/_coding-result.json" ;;
  empty|unavailable|exit124|timeout) ;;
  newdir) mkdir "$wd/new"; printf 'new\n' > "$wd/new/file.txt" ;;
  marker) printf '# MUT leftover\n' >> "$wd/tracked.txt" ;;
  signal-changes) printf 'partial\n' >> "$wd/tracked.txt"; : > "$SCN_TMP/ready"; sleep 2 ;;
  signal) : > "$SCN_TMP/ready"; sleep 2 ;;
  *) printf 'edited\n' >> "$wd/tracked.txt" ;;
esac
case "$EDIT_MODE" in
  timeout) sleep 3 ;;
  exit124) exit 124 ;;
  committed) git -C "$wd" add tracked.txt; git -C "$wd" -c user.name=Conformance -c user.email=conformance@example.invalid commit -qm worker ;;
  task2) if [ -f "$SCN_TMP/task1" ]; then exit 124; else : > "$SCN_TMP/task1"; fi ;;
esac
exec bash "$EDIT_REPLAY" "${args[@]}"
STUB
chmod +x "$SCN_TMP/bin/codex"
# A pin's age must not depend on crossing a wall-clock second.
case "$id" in
  *refused)
    cat > "$SCN_TMP/bin/date" <<'DATE'
#!/usr/bin/env bash
if [ "$#" = 1 ] && [ "$1" = +%s ]; then printf '1700000000\n'; else exec /bin/date "$@"; fi
DATE
    chmod +x "$SCN_TMP/bin/date"
    ;;
esac
export EDIT_PYTHON
EDIT_PYTHON=$(command -v python3)
cat > "$SCN_TMP/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
if [ "$#" = 1 ] && [ "$1" = --version ]; then
  printf 'Python fixture\n'
else
  exec "$EDIT_PYTHON" "$@"
fi
PYTHON
chmod +x "$SCN_TMP/bin/python3"
export PATH="$SCN_TMP/bin:$PATH"
export CODING_DISPATCH_TIMEOUT=5s
flags=()
gate=true
case "$id" in
  *worktree*|edit-signal) flags+=(--worktree) ;;
esac
case "$id" in
  edit-build-fail*) gate=false ;;
  edit-scope) flags+=(--allow-path other.txt) ;;
  edit-newdir) flags+=(--allow-path new/file.txt) ;;
  edit-fm4) flags+=(--require-file missing.txt) ;;
  edit-noop-present) flags+=(--require-file tracked.txt) ;;
  edit-noop-missing) flags+=(--require-file missing.txt) ;;
  edit-noop-build) gate=false ;;
esac

: "$gate"
