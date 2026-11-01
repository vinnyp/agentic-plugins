# shellcheck shell=bash
set -eu
: "${id:?}" "${runtime:?}" "${mode:?}"
here=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$SCN_REPO" "$SCN_TMP/bin"
git -C "$SCN_REPO" init -q -b main
printf 'base\n' > "$SCN_REPO/tracked.txt"
git -C "$SCN_REPO" add .
git -C "$SCN_REPO" -c user.name=Conformance -c user.email=conformance@example.invalid commit -qm fixture
printf 'Review tracked.txt.\n' > "$SCN_TMP/brief"
export STUB_RECORDING="$here/scenarios/$id/recording"
export WORKER_CASE="$id" WORKER_REPLAY="$here/stubs" WORKER_SOURCE="$SCN_REPO"
cat > "$SCN_TMP/bin/runtime-stub" <<'STUB'
#!/usr/bin/env bash
set -eu
runtime=${0##*/}
case "${1:-}" in models|agent) exec bash "$WORKER_REPLAY/$runtime" "$@" ;; esac
case "$WORKER_CASE" in
  *-drift) printf '\n[conformance]\n\tdrift = true\n' >> "$WORKER_SOURCE/.git/config" ;;
  *-orphan) printf '{"status":"complete","files_written":[]}' > "$WORKER_SOURCE/_coding-result.json" ;;
  *-child-env) printf 'CODING_DISPATCH_CHILD_ENV=%s\n' "${CODING_DISPATCH_CHILD_ENV-unset}" ;;
esac
rc=0
bash "$WORKER_REPLAY/$runtime" "$@" || rc=$?
case "$WORKER_CASE" in *-timeout) sleep 3 ;; esac
exit "$rc"
STUB
for command in codex agy claude; do
  cp "$SCN_TMP/bin/runtime-stub" "$SCN_TMP/bin/$command"
  chmod +x "$SCN_TMP/bin/$command"
done
export PATH="$SCN_TMP/bin:$PATH"
export KILL_AFTER=1s
flags=(--runtime "$runtime" --brief "$SCN_TMP/brief" --workdir "$SCN_REPO" --timeout 5s)
[ "$mode" != review ] || flags+=(--review)
case "$id" in
  *-dirty|*-allow-env)
    printf 'dirty\n' >> "$SCN_REPO/tracked.txt"
    git -C "$SCN_REPO" diff --quiet && exit 99
    ;;
esac
case "$id" in
  *-allow-dirty) flags+=(--allow-dirty) ;;
  *-allow-env) export DISPATCH_ALLOW_DIRTY=1 ;;
  *-timeout) flags+=(--timeout 1s) ;;
  *-dep) flags+=(--require-dep example.invalid/required --module-dir "$SCN_REPO") ;;
  *-review|*-edit) flags+=(--model 'fixture model' --ceremony) ;;
  *-evidence-off) export DISPATCH_REVIEW_REQUIRE_EVIDENCE=0 ;;
  *-floor-env) export DISPATCH_MIN_REVIEW_BYTES=10 ;;
  *-child-env) export CODING_DISPATCH_CHILD_ENV=fixture ;;
  *-env)
    export RUNTIME="$runtime" MODEL='fixture model' WORKDIR="$SCN_REPO" TIMEOUT=5s REVIEW=1 CEREMONY=1
    export DISPATCH_REVIEW_WT_DIR="$SCN_TMP/reviews" REVIEW_OUTFILE="$SCN_TMP/review.md"
    flags=(--brief "$SCN_TMP/brief")
    ;;
  *-recall) flags+=(--recall-project synthetic --no-recall --network) ;;
  *-help) flags=(--help) ;;
esac
[ "$runtime" != agy ] || flags+=(--agent fixture-reviewer)
cd "$SCN_REPO"
"$IMPL_BIN/dispatch-worker" "${flags[@]}"
