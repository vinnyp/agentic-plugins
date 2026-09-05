#!/usr/bin/env bash
# run-tests.sh — canonical aggregate gate for agent-dispatch.
set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

shopt -s nullglob
suites=("$SCRIPT_DIR"/test-*.sh)
for legacy_suite in "$ROOT"/test/*.sh; do
  suites+=("$legacy_suite")
done
shopt -u nullglob

if [ "${#suites[@]}" -eq 0 ]; then
  echo "run-tests.sh: ERROR: discovered 0 test suites matching $SCRIPT_DIR/test-*.sh or $ROOT/test/*.sh"
  exit 1
fi

sorted_suites=()
while IFS= read -r suite || [ -n "$suite" ]; do
  sorted_suites+=("$suite")
done <<EOF
$(printf '%s\n' "${suites[@]}" | sort)
EOF
suites=("${sorted_suites[@]}")

passed=0
failed=0

for suite in "${suites[@]}"; do
  name="$(basename "$suite")"
  echo "RUN  $name"
  if bash "$suite"; then
    echo "PASS $name"
    passed=$((passed + 1))
  else
    rc=$?
    echo "FAIL $name (exit $rc)"
    failed=$((failed + 1))
    echo
    echo "Summary: $passed passed, $failed failed, ${#suites[@]} total"
    echo "run-tests.sh: failing suite: $name"
    exit "$rc"
  fi
done

echo
echo "Summary: $passed passed, $failed failed, ${#suites[@]} total"

# The test/ suites join behavioral execution above. Like bin/test-*.sh,
# test suites do not join this entrypoint-only shellcheck set; CI shellchecks every
# *.sh repository-wide in its dedicated lint step.
shellcheck_targets=()
for candidate in "$SCRIPT_DIR"/*; do
  [ -f "$candidate" ] || continue
  [ -x "$candidate" ] || continue
  case "$(basename "$candidate")" in
    test-*.sh) continue ;;
  esac
  shellcheck_targets+=("$candidate")
done

if command -v shellcheck >/dev/null 2>&1; then
  if [ "${#shellcheck_targets[@]}" -gt 0 ]; then
    echo "RUN  shellcheck --severity=warning"
    if shellcheck --severity=warning "${shellcheck_targets[@]}"; then
      echo "PASS shellcheck --severity=warning (${#shellcheck_targets[@]} entrypoints)"
    else
      rc=$?
      echo "FAIL shellcheck --severity=warning (exit $rc)"
      exit "$rc"
    fi
  else
    echo "run-tests.sh: NOTICE: no non-test executable entrypoints found for shellcheck"
  fi
else
  echo "run-tests.sh: NOTICE: shellcheck not found; skipping shellcheck --severity=warning"
fi
