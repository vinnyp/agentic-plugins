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
# Invalid rows must report their specific validation failure.
for row in $'bin/test-a.sh\tskip' $'bin/test-a.sh\tskip\tx\textra' $'bin/test-a.sh\tbogus\tx' $'bin/test-a.sh\tskip\t'; do
  fixture
  printf '%s\n' "$row" > "$TASK_TMP/manifest"
  check 1
  message='invalid manifest row:'
  case "$row" in *bogus*) message='unknown manifest kind: bogus' ;; esac
  grep -Fq "$message" "$TASK_TMP/out" || { echo 'FAIL missing validation message'; exit 1; }
done
fixture
printf 'bin/test-a.sh\tskip\t^SKIP: tmux not installed$\n' > "$TASK_TMP/manifest"
printf 'prefix SKIP: tmux not installed suffix\n' >> "$TASK_TMP/run/bin__test-a.sh.log"
check 1
# Full-line matching must also reject an unanchored substring pattern.
printf 'bin/test-a.sh\tskip\tSKIP: tmux not installed\n' > "$TASK_TMP/manifest"
check 1
fixture
printf 'bin/test-a.sh\tskip\t^SKIP: tmux missing$' > "$TASK_TMP/manifest"
printf 'SKIP: tmux missing\n' >> "$TASK_TMP/run/bin__test-a.sh.log"
check 0
printf 'bin/test-a.sh\trequire\tmissing line' > "$TASK_TMP/manifest"
check 1
printf 'bin/test-a.sh\tbogus\tx' > "$TASK_TMP/manifest"
check 1
grep -Fq 'unknown manifest kind: bogus' "$TASK_TMP/out" || exit 1
while IFS= read -r row || [ -n "$row" ]; do
  case "$row" in ''|'#'*) continue ;; esac
  fields=$(printf '%s\n' "$row" | awk -F '\t' '{print NF}')
  [ "$fields" = 3 ] || { echo 'FAIL manifest fields'; exit 1; }
  IFS=$'\t' read -r suite kind pattern <<< "$row"
  [ -n "$pattern" ] || exit 1
  case "$kind" in skip|require) ;; *) exit 1 ;; esac
  [ -f "$SELF_DIR/../$suite" ] || { echo "FAIL unknown suite $suite"; exit 1; }
done < "$SELF_DIR/lib/stock-skip-manifest.txt"
mkdir -p "$TASK_TMP/gate/lib" "$TASK_TMP/gate-run" "$TASK_TMP/timers"
cp "$SELF_DIR/run-stock-gate.sh" "$TASK_TMP/gate/run-stock-gate.sh"
: > "$TASK_TMP/gate/lib/stock-skip-manifest.txt"
cat > "$TASK_TMP/gate/run-tests.sh" <<'STUB'
#!/bin/bash
touch "$STUB_MARK.tests"
printf 'Run dir: %s/gate-run\n' "$HOME"
exit "$STUB_TESTS_RC"
STUB
cat > "$TASK_TMP/gate/audit-test-skips.sh" <<'STUB'
#!/bin/bash
touch "$STUB_MARK.audit"
exit "$STUB_AUDIT_RC"
STUB
printf '#!/bin/bash\nexit 0\n' > "$TASK_TMP/timers/timeout"
chmod +x "$TASK_TMP/timers/timeout"
path="$TASK_TMP/timers:/usr/bin:/bin"
rc=0
env -i HOME="$TASK_TMP" TMPDIR="$TASK_TMP" PATH="$path" STUB_MARK="$TASK_TMP/refusal" STUB_TESTS_RC=0 STUB_AUDIT_RC=0 /bin/bash "$TASK_TMP/gate/run-stock-gate.sh" > "$TASK_TMP/gate-out" 2>&1 || rc=$?
[ "$rc" = 1 ] && grep -Fxq 'stock gate: timeout must not resolve' "$TASK_TMP/gate-out" && [ ! -e "$TASK_TMP/refusal.tests" ] || { cat "$TASK_TMP/gate-out"; echo 'FAIL stock gate refusal'; exit 1; }
echo 'stock gate refusal PASS'
path=/usr/bin:/bin
if env -i PATH="$path" /bin/bash -c '
  [ "${BASH_VERSINFO[0]}" = 3 ] || exit 1
  for timer in timeout gtimeout; do
    ! command -v "$timer" >/dev/null 2>&1 || exit 1
  done
  for utility in perl shasum git jq; do
    command -v "$utility" >/dev/null 2>&1 || exit 1
  done
'; then
  for statuses in 0:0 1:0 0:1; do
    IFS=: read -r tests_rc audit_rc <<< "$statuses"
    mark="$TASK_TMP/status-$tests_rc-$audit_rc"
    rc=0
    env -i HOME="$TASK_TMP" TMPDIR="$TASK_TMP" PATH="$path" STUB_MARK="$mark" STUB_TESTS_RC="$tests_rc" STUB_AUDIT_RC="$audit_rc" /bin/bash "$TASK_TMP/gate/run-stock-gate.sh" > "$TASK_TMP/gate-out" 2>&1 || rc=$?
    if [ "$statuses" = 0:0 ]; then
      [ "$rc" = 0 ] || { cat "$TASK_TMP/gate-out"; echo 'FAIL stock gate success'; exit 1; }
    else
      [ "$rc" != 0 ] || { echo "FAIL stock gate status $statuses"; exit 1; }
    fi
    [ "$statuses" != 1:0 ] || [ -f "$mark.audit" ] || { echo 'FAIL stock gate audit missing'; exit 1; }
  done
  echo 'stock gate fixtures PASS'
else
  echo 'stock gate fixtures SKIP (not a stock host)'
fi
echo 'audit-test-skips fixtures and real manifest PASS'
