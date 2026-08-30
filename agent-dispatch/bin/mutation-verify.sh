#!/usr/bin/env bash
# mutation-verify.sh — copy-based mutation-verify pass for a single file.
#
# Why this exists (issue #115): a mutation-verify pass (revert the fix ->
# confirm the test goes RED -> restore) has THREE times been done with
# `git checkout -- <file>` on an UNCOMMITTED diff. That restores the last
# COMMITTED baseline — discarding the in-flight fix AND yielding a false
# "mutation-proof" pass. This helper is copy-based (mktemp snapshot, not
# git) so it is immune to commit state and does NOT need a clean tree.
#
# Usage:
#   mutation-verify.sh --file <path> --test-cmd <shell-command> \
#     (--mutate-sed <sed-expr> | --mutate-cmd <shell-command>)
#
# Exactly one of --mutate-sed / --mutate-cmd is required.
#
# Two-run behavior: --test-cmd is run TWICE. First, as a BASELINE against the
# UNMUTATED file — if that run does not pass, the instrument itself is
# invalid and the script aborts (exit 2) before ever mutating anything.
# Second, after mutation, to produce the actual verdict below.
#
# Verdict:
#   test-cmd exits NON-ZERO under the mutation (went RED) -> the test
#     genuinely isolates the fix -> exit 0.
#   test-cmd exits ZERO under the mutation (stayed GREEN)  -> false-green
#     test -> exit 1.
#   Bad args, missing file, a failing baseline, a no-op mutation, failed
#     applied-verification, or a failed restore -> exit 2.
#
# Applied-verification flags:
#   --expect-anchor <str> checks the original snapshot contains <str> before
#     mutation; missing anchors abort with exit 2.
#   --expect-marker <str> checks the mutated file contains <str> after
#     mutation; missing markers abort with exit 2.
#   --syntax-cmd <cmd> runs after mutation and before the test; non-zero exits
#     abort with exit 2. Example: --syntax-cmd "python -m py_compile path/to/file.py"
#
# --file is resolved to an ABSOLUTE path before snapshotting, and both
# --test-cmd and --mutate-cmd run inside a subshell, so a --test-cmd that
# does `cd` elsewhere cannot cause a restore to write to the wrong path.
#
# ABSOLUTE PROHIBITION: this script must NEVER invoke git in any form.
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: mutation-verify.sh --file <path> --test-cmd <shell-command> \
         [--expect-anchor <str>] [--expect-marker <str>] \
         [--syntax-cmd <shell-command>] [--cover-check <line-or-symbol>] \
         (--mutate-sed <sed-expr> | --mutate-cmd <shell-command>)

Exactly one of --mutate-sed or --mutate-cmd is required.

--test-cmd is run twice: once as a baseline against the unmutated file
(must pass, or the script aborts) and once under mutation.

--expect-anchor may be repeated and must be present in the original snapshot.
--expect-marker may be repeated and must be present in the mutated file.
--syntax-cmd runs after mutation and before the test, for example:
  --syntax-cmd "python -m py_compile path/to/file.py"
--cover-check runs the mutated Go test command with -coverprofile and
asserts the target line/function in --file had non-zero coverage.
Missing anchors, missing markers, and failing syntax commands exit 2.
EOF
}

file=""
test_cmd=""
mutate_sed=""
mutate_cmd=""
have_sed=0
have_cmd=0
expect_anchors=()
expect_markers=()
syntax_cmd=""
have_syntax=0
cover_check=""
have_cover_check=0

require_value() {
  # $1 = flag name, $2 = remaining arg count after the flag
  if [ "$2" -lt 2 ]; then
    echo "mutation-verify.sh: $1 requires a value" >&2
    usage
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --file) require_value "--file" "$#"; file="$2"; shift 2 ;;
    --test-cmd) require_value "--test-cmd" "$#"; test_cmd="$2"; shift 2 ;;
    --mutate-sed) require_value "--mutate-sed" "$#"; mutate_sed="$2"; have_sed=1; shift 2 ;;
    --mutate-cmd) require_value "--mutate-cmd" "$#"; mutate_cmd="$2"; have_cmd=1; shift 2 ;;
    --expect-anchor) require_value "--expect-anchor" "$#"; expect_anchors+=("$2"); shift 2 ;;
    --expect-marker) require_value "--expect-marker" "$#"; expect_markers+=("$2"); shift 2 ;;
    --syntax-cmd) require_value "--syntax-cmd" "$#"; syntax_cmd="$2"; have_syntax=1; shift 2 ;;
    --cover-check) require_value "--cover-check" "$#"; cover_check="$2"; have_cover_check=1; shift 2 ;;
    -h|--help) usage; exit 2 ;;
    *) echo "mutation-verify.sh: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$file" ] || [ -z "$test_cmd" ]; then
  echo "mutation-verify.sh: --file and --test-cmd are required" >&2
  usage
  exit 2
fi
if [ "$have_sed" -eq 0 ] && [ "$have_cmd" -eq 0 ]; then
  echo "mutation-verify.sh: exactly one of --mutate-sed or --mutate-cmd is required" >&2
  usage
  exit 2
fi
if [ "$have_sed" -eq 1 ] && [ "$have_cmd" -eq 1 ]; then
  echo "mutation-verify.sh: --mutate-sed and --mutate-cmd are mutually exclusive" >&2
  usage
  exit 2
fi
if [ ! -e "$file" ]; then
  echo "mutation-verify.sh: --file does not exist: $file" >&2
  exit 2
fi
if [ ! -f "$file" ]; then
  echo "mutation-verify.sh: --file is not a regular file: $file" >&2
  exit 2
fi

# Resolve --file to an ABSOLUTE path immediately, before snapshotting and
# before running anything that could change the shell's cwd. A relative
# --file combined with a --test-cmd/--mutate-cmd that `cd`s elsewhere would
# otherwise cause the later restore to write to the WRONG path, leaving the
# original file mutated while reporting success (issue #115 follow-up).
case "$file" in
  /*) : ;;
  *) file="$(pwd)/$file" ;;
esac

# Snapshot by COPY into a mktemp dir OUTSIDE the repo — immune to commit state.
snap_dir="$(mktemp -d "${TMPDIR:-/tmp}/mutation-verify.XXXXXX")" || {
  echo "mutation-verify.sh: failed to create snapshot dir" >&2
  exit 2
}
snap_file="$snap_dir/snapshot"
cp -p "$file" "$snap_file" || {
  echo "mutation-verify.sh: failed to snapshot $file" >&2
  rm -rf "$snap_dir"
  exit 2
}

# Restore-on-every-path bookkeeping. `restored` tracks whether a restore
# attempt has already run. `verify_restore`'s return code (NOT a stored
# flag) gates whether cleanup() is allowed to delete the snapshot (see
# BLOCKER 4: a failed restore must never lose the only surviving copy of
# the file).
restored=0
restore_file() {
  [ "$restored" -eq 1 ] && return 0
  restored=1
  cp -p "$snap_file" "$file"
}
verify_restore() {
  cmp -s "$snap_file" "$file"
}
# cleanup() itself must be idempotent: the INT/TERM handlers call it
# explicitly and then re-raise the signal, which fires the EXIT trap and
# calls it a SECOND time as the process actually terminates. Without this
# guard, the second call finds `snap_dir` already removed by the first and
# reports a spurious "RESTORE FAILED" for a run that actually succeeded.
cleanup_done=0
cleanup() {
  [ "$cleanup_done" -eq 1 ] && return 0
  cleanup_done=1
  restore_file
  if verify_restore; then
    rm -rf "$snap_dir"
  else
    echo "mutation-verify.sh: RESTORE FAILED — $file is not byte-identical to its snapshot. The ONLY surviving copy of the original content is kept at: $snap_file (in $snap_dir). Restore it by hand." >&2
  fi
}
# EXIT alone: a normal return (any exit code) always cleans up. INT/TERM get
# their OWN handlers that clean up and then re-raise the signal with the
# correct signal-derived status, instead of letting bash resume execution
# past the trap — see BLOCKER 3: without this, a Ctrl-C during --test-cmd
# left `test_rc` non-zero, which the script then reported as a false
# mutation-CAUGHT success (exit 0).
trap cleanup EXIT
trap 'cleanup; trap - INT; kill -s INT $$' INT
trap 'cleanup; trap - TERM; kill -s TERM $$' TERM

shell_quote() {
  printf '%q' "$1"
}

test_cmd_with_coverprofile() {
  # $1 = original test command, $2 = coverprofile path
  _cmd="$1"
  _profile="$(shell_quote "$2")"
  case "$_cmd" in
    *"go test "*)
      printf '%s\n' "${_cmd/go test /go test -coverprofile=$_profile }"
      ;;
    *"go test")
      printf '%s\n' "${_cmd/go test/go test -coverprofile=$_profile}"
      ;;
    *)
      return 1
      ;;
  esac
}

cover_check_executed() {
  # $1 = coverprofile path, $2 = absolute target file, $3 = line or function
  _profile="$1"
  _target_file="$2"
  _target="$3"
  _target_base="${_target_file##*/}"

  [ -s "$_profile" ] || return 1

  case "$_target" in
    *[!0-9]*)
      _cover_func_out="$snap_dir/cover-func.out"
      # Coupled to `go tool cover -func` columns: path, func, percent.
      ( cd "$(dirname "$_target_file")" && go tool cover -func="$_profile" ) > "$_cover_func_out" 2>/dev/null || return 1
      while IFS= read -r _line; do
        case "$_line" in
          total:*) continue ;;
          *:*) : ;;
          *) continue ;;
        esac
        _path_part="${_line%%:*}"
        [ "${_path_part##*/}" = "$_target_base" ] || continue
        _func_name="$(printf '%s\n' "$_line" | awk '{print $2}')"
        _percent="$(printf '%s\n' "$_line" | awk '{print $3}')"
        [ "$_func_name" = "$_target" ] || continue
        [ "$_percent" != "0.0%" ] && return 0
      done < "$_cover_func_out"
      return 1
      ;;
    *)
      while IFS= read -r _line; do
        case "$_line" in
          mode:*) continue ;;
          *:*) : ;;
          *) continue ;;
        esac
        _path_part="${_line%%:*}"
        [ "${_path_part##*/}" = "$_target_base" ] || continue
        _rest="${_line#*:}"
        _range="${_rest%% *}"
        _count="${_line##* }"
        _start="${_range%%,*}"
        _end="${_range#*,}"
        _start_line="${_start%%.*}"
        _end_line="${_end%%.*}"
        if [ "$_target" -ge "$_start_line" ] && [ "$_target" -le "$_end_line" ] && [ "$_count" -gt 0 ]; then
          return 0
        fi
      done < "$_profile"
      return 1
      ;;
  esac
}

# Baseline: run --test-cmd against the UNMUTATED file FIRST. If it does not
# pass here, the instrument itself is invalid (typo'd path, syntax error,
# already-broken suite) and reporting "mutation CAUGHT" later would be a
# false green inside the false-green detector. Run in a subshell so a `cd`
# inside test_cmd cannot leak into this script's cwd.
baseline_rc=0
( eval "$test_cmd" ) || baseline_rc=$?
if [ "$baseline_rc" -ne 0 ]; then
  echo "mutation-verify.sh: test-cmd does not pass before mutation (baseline exited $baseline_rc) — the instrument is invalid" >&2
  exit 2
fi

# Applied-verification, part 1 (applied-verification): assert every expected anchor is
# present in the ORIGINAL file before mutating. The post-hoc cmp check below only
# infers a zero-match from unchanged bytes, which a --mutate-cmd that writes
# something ELSE can slip past. Checking up front names the real defect.
for _a in ${expect_anchors[@]+"${expect_anchors[@]}"}; do
  if ! grep -F -q -- "$_a" "$snap_file"; then
    echo "mutation-verify.sh: ANCHOR NOT FOUND — expected anchor is absent from the unmutated $file: $_a" >&2
    echo "mutation-verify.sh: the mutation would target zero sites; fix the anchor, do not trust a verdict from this run" >&2
    exit 2
  fi
done

# Mutate.
if [ "$have_sed" -eq 1 ]; then
  # Read FROM the snapshot, write TO the file — sidesteps GNU-vs-BSD `sed -i`
  # portability entirely.
  if ! sed "$mutate_sed" "$snap_file" > "$file"; then
    echo "mutation-verify.sh: sed mutation command failed" >&2
    exit 2
  fi
else
  # Subshell: a --mutate-cmd that `cd`s must not change this script's cwd.
  if ! ( eval "$mutate_cmd" ); then
    echo "mutation-verify.sh: --mutate-cmd exited non-zero" >&2
    exit 2
  fi
fi

# Assert the mutation actually changed the file — a no-op mutation (sed
# matched nothing) must never be allowed to produce a bogus verdict.
if cmp -s "$snap_file" "$file"; then
  echo "mutation-verify.sh: mutation did not change $file (no-op mutation — the expression matched nothing); aborting before running the test" >&2
  exit 2
fi

# Applied-verification, part 2 (applied-verification): bytes changing is NOT evidence the
# INTENDED mutation landed. A semantically-wrong edit changes bytes, fails the test
# for an unrelated reason, and would be reported CAUGHT — a false pass inside the
# false-green detector.
for _m in ${expect_markers[@]+"${expect_markers[@]}"}; do
  if ! grep -F -q -- "$_m" "$file"; then
    echo "mutation-verify.sh: MARKER ABSENT — the file changed but the expected marker is not present after mutation: $_m" >&2
    echo "mutation-verify.sh: the edit did not land as intended; refusing to emit a caught/survived verdict" >&2
    exit 2
  fi
done

if [ "$have_syntax" -eq 1 ]; then
  syntax_rc=0
  ( eval "$syntax_cmd" ) || syntax_rc=$?
  if [ "$syntax_rc" -ne 0 ]; then
    echo "mutation-verify.sh: MUTATED FILE INVALID — --syntax-cmd exited $syntax_rc after mutation" >&2
    echo "mutation-verify.sh: a test failure here would be the wrong RED; refusing to emit a verdict" >&2
    exit 2
  fi
fi

# Run the test under mutation; capture its exit code without tripping -e
# (unset here, but be explicit). Subshell for the same cwd-isolation reason
# as the baseline run above — this is the path BLOCKER 1 exploited.
test_rc=0
cover_profile=""
if [ "$have_cover_check" -eq 1 ]; then
  cover_profile="$snap_dir/cover.out"
  cover_test_cmd="$(test_cmd_with_coverprofile "$test_cmd" "$cover_profile")" || {
    echo "mutation-verify.sh: --cover-check requires --test-cmd to contain a Go package test command (go test <package>)" >&2
    exit 2
  }
  ( eval "$cover_test_cmd" ) || test_rc=$?
else
  ( eval "$test_cmd" ) || test_rc=$?
fi

# Restore now (also covered by the EXIT trap, but do it here so we can
# verify byte-identity before deciding the verdict).
restore_file
if ! verify_restore; then
  echo "mutation-verify.sh: RESTORE FAILED — $file is not byte-identical to its snapshot after restore" >&2
  exit 2
fi

verdict_prefix=""
if [ "$have_syntax" -eq 0 ]; then
  verdict_prefix="[UNVERIFIED APPLICATION] "
  for _m in ${expect_markers[@]+"${expect_markers[@]}"}; do
    verdict_prefix=""
    break
  done
fi

if [ "$have_cover_check" -eq 0 ]; then
  reachability_suffix="; reachability was NOT verified"
elif cover_check_executed "$cover_profile" "$file" "$cover_check"; then
  reachability_suffix="; reachability verified by --cover-check $cover_check"
elif [ "$test_rc" -ne 0 ]; then
  reachability_suffix="; coverage unavailable — build/test failed before --cover-check $cover_check could prove reachability"
else
  echo "mutation-verify.sh: MUTANT-UNREACHABLE (--cover-check $cover_check had zero coverage in $file) — unreachable mutants prove neither killed nor survived" >&2
  exit 1
fi

if [ "$test_rc" -ne 0 ]; then
  echo "mutation-verify.sh: ${verdict_prefix}mutation CAUGHT (test-cmd exited $test_rc under mutation$reachability_suffix) — test genuinely isolates the fix" >&2
  exit 0
else
  echo "mutation-verify.sh: ${verdict_prefix}mutation NOT caught (test-cmd exited 0 under mutation$reachability_suffix) — false-green test" >&2
  exit 1
fi
