# shellcheck shell=bash
# Additional capture cases use only synthetic workers and disposable repositories.
set -eu
: "${id:?}"
# shellcheck disable=SC2034 # Consumed by sourced fixture.
mode=empty
# shellcheck source=agent-dispatch/test/conformance/edit-fixture.sh
source "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/edit-fixture.sh"
observe() {
  local rc=0
  "$@" > "$SCN_TMP/output" 2>&1 || rc=$?
  sed 's/^PID=/pid=/' "$SCN_TMP/output"
  printf 'observed_rc=%s\n' "$rc"
  observed_rc=$rc
}
case "$id" in
  capture-agy-done)
    cat > "$SCN_TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'Done. All requested work is complete.\n'
STUB
    chmod +x "$SCN_TMP/bin/agy"
    export AGY_MODEL=fixture-model
    observe "$IMPL_BIN/coding-dispatch.sh" agy "$SCN_REPO" "$SCN_TMP/brief" true
    [ "$observed_rc" = 1 ]
    grep -q 'DISPATCH=fail: empty diff' "$SCN_TMP/output"
    ! grep -q 'DISPATCH=ok' "$SCN_TMP/output"
    # Exercise the actual phase consumer's routing, rather than infer it from rc.
    observe "$IMPL_BIN/coding-build-phase.sh" agy "$SCN_TMP/plan" "$SCN_REPO" 1 --build-cmd true
    [ "$observed_rc" = 1 ]
    grep -q 'PHASE=stopped-at:1' "$SCN_TMP/output"
    grep -q 'Opus takes this task' "$SCN_TMP/output"
    ! grep -q 'PHASE=ok\|PHASE=blocked-unavailable' "$SCN_TMP/output"
    ;;
  capture-scope-cleanup|capture-alias-cleanup)
    export EDIT_MODE=edit
    if [ "$id" = capture-scope-cleanup ]; then
      observe "$IMPL_BIN/coding-dispatch.sh" --allow-path other.txt codex "$SCN_REPO" "$SCN_TMP/brief" true
      [ "$observed_rc" = 1 ]
      grep -q 'scope gate' "$SCN_TMP/output"
      [ "$(cat "$SCN_REPO/tracked.txt")" = base ]
    else
      observe "$IMPL_BIN/coding-dispatch.sh" --worktree codex "$SCN_REPO" "$SCN_TMP/brief" true
      [ "$observed_rc" = 0 ]
      python3 - "$SCN_TMP/output" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'DISPATCH=ok worktree_ns=(\S+) worktree=(\S+)', s)
assert m and m[1] == m[2], 'deprecated worktree alias must equal worktree_ns'
PY
    fi
    [ -z "$(find "$TMPDIR" -name 'coding-dispatch-brief.*' -print)" ]
    echo 'injected prompt removed'
    ;;
  capture-shared-config)
    cat > "$SCN_TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -eu
wd=$PWD
while [ "$#" -gt 0 ]; do
  if [ "$1" = -C ]; then wd=$2; shift 2; else shift; fi
done
cat >/dev/null
[ -f "$wd/.git" ]
common=$(git -C "$wd" rev-parse --path-format=absolute --git-common-dir)
printf '\n[conformance]\n sharedWorkerWrite = true\n' >> "$common/config"
printf 'worker edit\n' >> "$wd/tracked.txt"
STUB
    observe "$IMPL_BIN/coding-dispatch.sh" --worktree codex "$SCN_REPO" "$SCN_TMP/brief" true
    [ "$observed_rc" = 0 ]
    grep -q 'sharedWorkerWrite = true' "$SCN_REPO/.git/config"
    echo 'known-defect vinnyp/foundry#239: shared config write accepted'
    ;;
  capture-limit-file)
    printf 'Selected model is at capacity\n' > "$SCN_TMP/document"
    cat > "$SCN_TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
cat "$SCN_TMP/document"
STUB
    observe "$IMPL_BIN/coding-dispatch.sh" codex "$SCN_REPO" "$SCN_TMP/brief" true
    [ "$observed_rc" = 6 ]
    grep -q 'agent unavailable' "$SCN_TMP/output"
    echo 'known-defect vinnyp/foundry#263: printed file mistaken for service limit'
    ;;
  capture-review-collision)
    cat > "$SCN_TMP/bin/agy" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  models) printf 'fixture-model\tFixture\n' ;;
  agent) printf 'fixture-reviewer\n' ;;
  *) echo 'unexpected reviewer launch' >&2; exit 97 ;;
esac
STUB
    chmod +x "$SCN_TMP/bin/agy"
    printf 'retain existing bytes\n' > "$SCN_TMP/existing"
    ln -s "$SCN_TMP/existing" "$SCN_TMP/review.md"
    export REVIEW_OUTFILE="$SCN_TMP/review.md"
    observe "$IMPL_BIN/dispatch-worker" --runtime agy --model fixture-model --agent fixture-reviewer --review --brief "$SCN_TMP/brief" --workdir "$SCN_REPO"
    [ "$observed_rc" = 3 ]
    [ -L "$REVIEW_OUTFILE" ]
    [ "$(cat "$SCN_TMP/existing")" = 'retain existing bytes' ]
    grep -q 'review output must be a regular file' "$SCN_TMP/output"
    echo 'predictable output symlink and target retained; failure status=3'
    ;;
  capture-no-setsid)
    mkdir "$SCN_TMP/portable"
    # Copy the available command namespace while deliberately excluding setsid.
    for dir in ${PATH//:/ }; do
      for tool in "$dir"/*; do
        name=${tool##*/}
        [ "$name" != setsid ] || continue
        [ -x "$tool" ] && [ ! -d "$tool" ] || continue
        [ -e "$SCN_TMP/portable/$name" ] || ln -s "$tool" "$SCN_TMP/portable/$name"
      done
    done
    export PATH="$SCN_TMP/portable"
    ! command -v setsid >/dev/null 2>&1
    parent_sid=$(python3 -c 'import os; print(os.getsid(0))')
    observe "$IMPL_BIN/run-long-gate.sh" --cmd "python3 -c 'import os; print(\"detached=\" + str(os.getsid(0) != $parent_sid))'" --log "$SCN_TMP/short.log" --workdir "$SCN_REPO"
    [ "$observed_rc" = 0 ]
    "$IMPL_BIN/run-long-gate.sh" --wait --log "$SCN_TMP/short.log" --timeout-secs 5 --poll-secs 1
    grep -qx 'detached=True' "$SCN_TMP/short.log"
    cat "$SCN_TMP/short.log"
    echo 'setsid absent; detached finite command completed'
    ;;
esac
