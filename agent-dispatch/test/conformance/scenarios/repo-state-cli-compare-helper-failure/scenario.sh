#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# shellcheck source=agent-dispatch/test/conformance/repo-state-cli-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-cli-fixture.sh"
export CASE_MODE=timeout
  set -eu; setup_mode
  declare d rc=0 real_awk
  fixture; d=$(outdir)
  cli snapshot "$R" "$d/before"
  printf '#!/bin/sh\nexit 0\n' > "$R/.git/hooks/pre-commit"
  chmod +x "$R/.git/hooks/pre-commit"
  cli snapshot "$R" "$d/after"
  rc_is 2 cli compare "$d/before" "$d/after" > "$d/baseline-out"
  real_awk=$(command -v awk)
  mkdir "$d/bin"
  cat > "$d/bin/awk" <<'AWK'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in *hasold*|*nmax*) kill -KILL $$ ;; esac
done
exec "$REAL_AWK" "$@"
AWK
  chmod +x "$d/bin/awk"
  REAL_AWK=$real_awk PATH="$d/bin:$SHIMS:$PATH" "$BIN/repo-state-check" compare "$d/before" "$d/after" > "$d/out" 2> "$d/err" || rc=$?
  case "$rc" in 2|3) ;; *) fail "a dying helper gave compare status $rc" ;; esac
  grep -Eq '^state: ' "$d/out" || fail 'a dying helper left no state line'
  survivors; no_bound_dir

echo "PASS: case_compare_helper_failure"
