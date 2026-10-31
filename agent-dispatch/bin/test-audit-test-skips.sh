#!/usr/bin/env bash
# Synthetic kept runs exercise every audit refusal without running agents.
set -eu
SELF_DIR=$(CDPATH='' cd "$(dirname "$0")" && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/audit-skips.XXXXXX")
[ -n "$TASK_TMP" ] || exit 1
trap 'rm -rf "$TASK_TMP"' EXIT
printf 'bin/test-a.sh\tskip\t^SKIP: tmux missing$\nbin/test-a.sh\trequire\tfixture PASS\n' > "$TASK_TMP/manifest"
check() {
  local want=$1 rc=0
  bash "$SELF_DIR/audit-test-skips.sh" "$TASK_TMP/run" "$TASK_TMP/manifest" > "$TASK_TMP/out" 2>&1 || rc=$?
  [ "$rc" = "$want" ] || { cat "$TASK_TMP/out"; echo "FAIL audit expected $want got $rc"; exit 1; }
}
fixture() {
  rm -rf "$TASK_TMP/run"
  mkdir "$TASK_TMP/run"
  printf 'bin/test-a.sh\0' > "$TASK_TMP/run/suites"
  printf '0\n' > "$TASK_TMP/run/bin__test-a.sh.rc"
  printf 'fixture PASS\n' > "$TASK_TMP/run/bin__test-a.sh.log"
}
fixture; check 0
fixture; rm "$TASK_TMP/run/suites"; check 1
fixture; : > "$TASK_TMP/run/suites"; check 1
fixture; printf bin/test-a.sh > "$TASK_TMP/run/suites"; check 1
fixture; rm "$TASK_TMP/run/bin__test-a.sh.rc"; check 1
for status in leaked junk not-run 1 00 '0 ' '' $'0\n'; do
  fixture; printf '%s\n' "$status" > "$TASK_TMP/run/bin__test-a.sh.rc"; check 1
done
for suffix in why leader-rc; do
  fixture; : > "$TASK_TMP/run/bin__test-a.sh.$suffix"; check 1
done
fixture; rm "$TASK_TMP/run/bin__test-a.sh.log"; check 1
for line in 'mid-line SKIP unexpected' 'case SKIPPED' 'SKIP: tmux missing'; do
  fixture
  if [ "$line" = 'SKIP: tmux missing' ]; then
    printf 'bin/test-b.sh\0' >> "$TASK_TMP/run/suites"
    printf '0\n' > "$TASK_TMP/run/bin__test-b.sh.rc"
    printf '%s\n' "$line" > "$TASK_TMP/run/bin__test-b.sh.log"
  else
    printf '%s\n' "$line" >> "$TASK_TMP/run/bin__test-a.sh.log"
  fi
  check 1
done
fixture; printf 'dep-gate skip under --review\nSKIP: tmux missing\n' >> "$TASK_TMP/run/bin__test-a.sh.log"; check 0
for line in 'no timeout/gtimeout binary' UNBOUNDED 'no timeout binary' "no 'timeout'/'gtimeout'" 'SKIPPING (cannot bound' 'probe is unbounded'; do
  fixture; printf '%s\n' "$line" >> "$TASK_TMP/run/bin__test-a.sh.log"; check 1
done
fixture; : > "$TASK_TMP/run/bin__test-a.sh.log"; check 1
fixture
rm "$TASK_TMP/run/bin__test-a.sh.rc"
printf 'SKIPPED unexpected\nUNBOUNDED\n' > "$TASK_TMP/run/bin__test-a.sh.log"
check 1
[ "$(wc -l < "$TASK_TMP/out" | tr -d ' ')" = 4 ] || { echo 'FAIL audit stopped at first violation'; exit 1; }
while IFS= read -r row || [ -n "$row" ]; do
  case "$row" in ''|'#'*) continue ;; esac
  fields=$(printf '%s\n' "$row" | awk -F '\t' '{print NF}')
  [ "$fields" = 3 ] || { echo 'FAIL manifest fields'; exit 1; }
  IFS=$'\t' read -r suite kind pattern <<< "$row"
  [ -n "$pattern" ] || exit 1
  case "$kind" in skip|require) ;; *) exit 1 ;; esac
  [ -f "$SELF_DIR/../$suite" ] || { echo "FAIL unknown suite $suite"; exit 1; }
done < "$SELF_DIR/lib/stock-skip-manifest.txt"
echo 'audit-test-skips fixtures and real manifest PASS'
