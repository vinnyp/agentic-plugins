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
#   test-cmd exits NON-ZERO under the mutation (went RED) -> exit 0
#     (CAUGHT). With --expect-fail-output, only when the RED run's output
#     holds every expected text; otherwise -> exit 3 (RED for an unrelated
#     reason: the hazard assertion is not shown to have caught this mutant).
#   test-cmd exits ZERO under the mutation (stayed GREEN)  -> false-green
#     test -> exit 1.
#   Bad args, missing file, a failing baseline, a no-op mutation, failed
#     applied-verification, a failed restore, or an --expect-fail-output text
#     that is empty, multi-line, or already printed by the passing baseline
#     -> exit 2.
#
# Applied-verification flags:
#   --expect-anchor <str> checks the original snapshot contains <str> before
#     mutation; missing anchors abort with exit 2.
#   --expect-marker <str> checks the mutated file contains <str> after
#     mutation; missing markers abort with exit 2.
#   --syntax-cmd <cmd> runs after mutation and before the test; non-zero exits
#     abort with exit 2. Example: --syntax-cmd "python -m py_compile path/to/file.py"
#
# Failure-cause flag (issue foundry#259):
#   --expect-fail-output <str> (repeatable) requires the mutated run's combined
#     stdout+stderr to contain <str> (text only the hazard assertion's own
#     failure message prints) when it goes RED. A RED run without it failed
#     for an unrelated reason (an incidental message or needle change), so the
#     script exits 3 instead of reporting CAUGHT. Empty or multi-line text,
#     and text the passing baseline already prints, are refused (exit 2): they
#     cannot identify the failure. This is a presence check over all output:
#     it cannot separate causes inside one snapshot/diff assertion that echoes
#     expected content. With the flag, each run's output is captured to a file
#     and printed on stdout (stderr merged) after the run finishes. Without the
#     flag, a CAUGHT verdict says its cause was not checked.
#
# Knock-out (issue foundry#259; requires --expect-fail-output):
#   --knockout-cmd <cmd> is the same test command with only the hazard test
#     deselected, by an exact form (supported: cargo -- --exact --skip, go -v
#     -skip '^Name$', pytest -q --deselect <full node id>; docs/commands.md),
#     with a required scope proof: --knockout-expect-output '<n><rest>' (every
#     "<n><rest>" in the output is summed; the full run must sum to 0 and the
#     knock-out to <n>) and/or --knockout-delta-line <prefix> (exactly one
#     fewer line starting with <prefix> than the full run). The knock-out must
#     start with --test-cmd and differ from it, pass green on the unmutated
#     copy, print something different from the full baseline, not print any
#     expected text there, and pass its scope proof, also on the mutant
#     (exit 2 otherwise). On the same mutated copy, and only when the main run would
#     be CAUGHT, the expected text must disappear; if it persists, another test
#     prints it (or the deselect missed) and the run exits 2. The verdict names
#     the command, its exit code on the mutant and the count line. Without it,
#     CAUGHT says the knock-out did not run.
#
# Control mutant (issue foundry#259; requires --expect-fail-output; recommended):
#   --control-sed <expr> | --control-cmd <cmd> (with --control-expect-fail-output,
#     the control test's own failure line) applies a second mutation that
#     breaks a DIFFERENT behavior, on a fresh copy of the original, with the
#     same no-op, --control-anchor / --control-marker and --syntax-cmd checks.
#     It must edit only --file. It runs only when the main run would be CAUGHT
#     (a RED run without the expected text stays exit 3). Exit 2 when the
#     control's text is already in the main run, the control is inert, its RED
#     run lacks its own text, or it prints any expected text. One passing
#     control shows only that that one other failure does not print the text.
#     Without a control, a CAUGHT verdict says the control did not run. The
#     control counts as verified only when --syntax-cmd checked its copy.
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
         [--expect-fail-output <str>] \
         [--knockout-cmd <shell-command> (--knockout-expect-output <str> | --knockout-delta-line <prefix>)] \
         [(--control-sed <sed-expr> | --control-cmd <shell-command>) \
          --control-expect-fail-output <str> \
          [--control-anchor <str>] [--control-marker <str>]] \
         (--mutate-sed <sed-expr> | --mutate-cmd <shell-command>)

Exactly one of --mutate-sed or --mutate-cmd is required.

--test-cmd is run twice: once as a baseline against the unmutated file
(must pass, or the script aborts) and once under mutation.

--expect-anchor may be repeated and must be present in the original snapshot.
--expect-marker may be repeated and must be present in the mutated file.
--syntax-cmd runs after mutation and before the test, for example:
  --syntax-cmd "python -m py_compile path/to/file.py"
--cover-check runs the mutated Go test command with -coverprofile and
asserts the target line/function in --file had non-zero coverage. With
--expect-fail-output, the baseline also runs with -coverprofile.
--expect-fail-output may be repeated; a RED mutated run whose output lacks
any of them failed for an unrelated reason and exits 3, not CAUGHT. Empty or
multi-line text, or text the passing baseline prints, exits 2.
--knockout-cmd (requires --expect-fail-output and a scope proof:
--knockout-expect-output '<n><rest>', summed over the output, and/or
--knockout-delta-line <prefix>, one fewer line than the full run) is --test-cmd
plus an exact deselect of only the hazard test; it must pass on the unmutated
copy and print something different from the full baseline; on the mutant the
expected text must disappear and the scope proof must still hold, or the run
exits 2.
--control-sed / --control-cmd (requires --expect-fail-output and
--control-expect-fail-output) applies a control mutation that breaks a
different behavior, on a fresh copy, when the main run would be CAUGHT. It must
edit only --file. An inert control, a control RED without its own text, a
control text already in the main run, or a control output holding an expected
text exits 2; --control-anchor / --control-marker verify it the way
--expect-anchor / --expect-marker verify the main mutation.
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
expect_fail_outputs=()
control_sed=""
control_cmd=""
have_control_sed=0
have_control_cmd=0
control_anchors=()
control_markers=()
control_expect_outputs=()
knockout_cmd=""
have_knockout=0
knockout_expect_outputs=()
knockout_delta_line=""
have_knockout_delta=0

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
    --expect-fail-output)
      require_value "--expect-fail-output" "$#"
      # An empty value matches every line under grep -F, and a newline splits
      # the value into OR-ed patterns; either would report a false cause.
      case "$2" in
        *[![:space:]]*) : ;;
        *) echo "mutation-verify.sh: --expect-fail-output must not be empty or whitespace-only" >&2; exit 2 ;;
      esac
      case "$2" in
        *$'\n'*|*$'\r'*) echo "mutation-verify.sh: --expect-fail-output must be a single line" >&2; exit 2 ;;
      esac
      expect_fail_outputs+=("$2"); shift 2 ;;
    --control-sed)
      require_value "--control-sed" "$#"
      [ "$have_control_sed" -eq 1 ] && { echo "mutation-verify.sh: --control-sed given twice" >&2; exit 2; }
      control_sed="$2"; have_control_sed=1; shift 2 ;;
    --control-cmd)
      require_value "--control-cmd" "$#"
      [ "$have_control_cmd" -eq 1 ] && { echo "mutation-verify.sh: --control-cmd given twice" >&2; exit 2; }
      control_cmd="$2"; have_control_cmd=1; shift 2 ;;
    --control-expect-fail-output)
      require_value "--control-expect-fail-output" "$#"
      case "$2" in
        *[![:space:]]*) : ;;
        *) echo "mutation-verify.sh: --control-expect-fail-output must not be empty or whitespace-only" >&2; exit 2 ;;
      esac
      case "$2" in
        *$'\n'*|*$'\r'*) echo "mutation-verify.sh: --control-expect-fail-output must be a single line" >&2; exit 2 ;;
      esac
      control_expect_outputs+=("$2"); shift 2 ;;
    --knockout-cmd)
      require_value "--knockout-cmd" "$#"
      [ "$have_knockout" -eq 1 ] && { echo "mutation-verify.sh: --knockout-cmd given twice" >&2; exit 2; }
      case "$2" in
        *[![:space:]]*) : ;;
        *) echo "mutation-verify.sh: --knockout-cmd must not be empty or whitespace-only" >&2; exit 2 ;;
      esac
      knockout_cmd="$2"; have_knockout=1; shift 2 ;;
    --knockout-expect-output)
      require_value "--knockout-expect-output" "$#"
      case "$2" in
        *[![:space:]]*) : ;;
        *) echo "mutation-verify.sh: --knockout-expect-output must not be empty or whitespace-only" >&2; exit 2 ;;
      esac
      case "$2" in
        *$'\n'*|*$'\r'*) echo "mutation-verify.sh: --knockout-expect-output must be a single line" >&2; exit 2 ;;
      esac
      # The count line must START with its number ("1 filtered out", "1 deselected"):
      # the tool sums every "<n><rest>" occurrence in the knock-out output.
      case "$2" in
        [0-9]*) : ;;
        *) echo "mutation-verify.sh: --knockout-expect-output must start with its number (e.g. '1 deselected'): $2" >&2; exit 2 ;;
      esac
      case "${2#"${2%%[!0-9]*}"}" in
        ''|[0-9]*) echo "mutation-verify.sh: --knockout-expect-output needs text after its number (e.g. '1 deselected'): $2" >&2; exit 2 ;;
      esac
      knockout_expect_outputs+=("$2"); shift 2 ;;
    --knockout-delta-line)
      require_value "--knockout-delta-line" "$#"
      [ "$have_knockout_delta" -eq 1 ] && { echo "mutation-verify.sh: --knockout-delta-line given twice" >&2; exit 2; }
      case "$2" in
        *[![:space:]]*) : ;;
        *) echo "mutation-verify.sh: --knockout-delta-line must not be empty or whitespace-only" >&2; exit 2 ;;
      esac
      case "$2" in
        *$'\n'*|*$'\r'*) echo "mutation-verify.sh: --knockout-delta-line must be a single line" >&2; exit 2 ;;
      esac
      knockout_delta_line="$2"; have_knockout_delta=1; shift 2 ;;
    --control-anchor) require_value "--control-anchor" "$#"; control_anchors+=("$2"); shift 2 ;;
    --control-marker) require_value "--control-marker" "$#"; control_markers+=("$2"); shift 2 ;;
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
have_control=0
[ "$have_control_sed" -eq 1 ] && have_control=1
[ "$have_control_cmd" -eq 1 ] && have_control=1
have_control_checks=0
for _c in ${control_anchors[@]+"${control_anchors[@]}"} ${control_markers[@]+"${control_markers[@]}"} ${control_expect_outputs[@]+"${control_expect_outputs[@]}"}; do
  have_control_checks=1
  break
done
if [ "$have_control_sed" -eq 1 ] && [ "$have_control_cmd" -eq 1 ]; then
  echo "mutation-verify.sh: --control-sed and --control-cmd are mutually exclusive" >&2
  usage
  exit 2
fi
if [ "$have_control" -eq 0 ] && [ "$have_control_checks" -eq 1 ]; then
  echo "mutation-verify.sh: --control-anchor / --control-marker / --control-expect-fail-output require --control-sed or --control-cmd" >&2
  usage
  exit 2
fi
if [ "$have_control" -eq 1 ]; then
  _have_expect=0
  for _o in ${expect_fail_outputs[@]+"${expect_fail_outputs[@]}"}; do
    _have_expect=1
    break
  done
  if [ "$_have_expect" -eq 0 ]; then
    echo "mutation-verify.sh: a control mutant (--control-sed / --control-cmd) requires --expect-fail-output: the control checks that another failure does not print the expected text" >&2
    usage
    exit 2
  fi
  _have_control_expect=0
  for _c in ${control_expect_outputs[@]+"${control_expect_outputs[@]}"}; do
    _have_control_expect=1
    break
  done
  if [ "$_have_control_expect" -eq 0 ]; then
    echo "mutation-verify.sh: a control mutant requires --control-expect-fail-output: the text its own seeded failure prints, so a build break or crash cannot pass as a control" >&2
    usage
    exit 2
  fi
fi
if [ "$have_knockout" -eq 1 ]; then
  _have_expect_k=0
  for _o in ${expect_fail_outputs[@]+"${expect_fail_outputs[@]}"}; do
    _have_expect_k=1
    break
  done
  if [ "$_have_expect_k" -eq 0 ]; then
    echo "mutation-verify.sh: --knockout-cmd requires --expect-fail-output: the knock-out checks that the expected text disappears without the hazard test" >&2
    usage
    exit 2
  fi
  if [ "$knockout_cmd" = "$test_cmd" ]; then
    echo "mutation-verify.sh: --knockout-cmd is identical to --test-cmd; it must be the test command with only the hazard test deselected" >&2
    exit 2
  fi
  case "$knockout_cmd" in
    "$test_cmd"*) : ;;
    *)
      echo "mutation-verify.sh: --knockout-cmd must start with --test-cmd (the same command plus a deselect of the hazard test): $knockout_cmd" >&2
      exit 2 ;;
  esac
  _have_count=0
  for _k in ${knockout_expect_outputs[@]+"${knockout_expect_outputs[@]}"}; do
    _have_count=1
    break
  done
  [ "$have_knockout_delta" -eq 1 ] && _have_count=1
  if [ "$_have_count" -eq 0 ]; then
    echo "mutation-verify.sh: --knockout-cmd requires --knockout-expect-output (the runner's deselection count, e.g. '1 deselected') or --knockout-delta-line (a per-test line prefix, e.g. '=== RUN '): the only proof of the knock-out's scope" >&2
    exit 2
  fi
else
  for _k in ${knockout_expect_outputs[@]+"${knockout_expect_outputs[@]}"}; do
    echo "mutation-verify.sh: --knockout-expect-output requires --knockout-cmd" >&2
    exit 2
  done
  if [ "$have_knockout_delta" -eq 1 ]; then
    echo "mutation-verify.sh: --knockout-delta-line requires --knockout-cmd" >&2
    exit 2
  fi
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
# attempt has completed. `verify_restore`'s return code (NOT a stored
# flag) gates whether cleanup() is allowed to delete the snapshot (see
# BLOCKER 4: a failed restore must never lose the only surviving copy of
# the file).
restored=0
mut_sec=0
# `cp -p` keeps the file's mode, but it also copies the snapshot's ORIGINAL
# mtime back — older than the mutant's build artifacts — so an mtime-based
# build (cargo, make) would treat the mutant's artifacts as fresh and keep
# running the mutant after a byte-identical restore.
# Wait past restore entry before touching: all mutant artifacts precede it,
# and Python pyc headers and coarse build timestamps compare whole seconds.
restore_file() {
  [ "$restored" -eq 1 ] && return 0
  if [ "$mut_sec" -gt 0 ]; then
    entry_sec=$(date +%s)
  fi
  cp -p "$snap_file" "$file" || return $?
  if [ "$mut_sec" -gt 0 ]; then
    restore_waits=0
    while [ "$(date +%s)" -le "$entry_sec" ]; do
      if [ "$restore_waits" -ge 15 ]; then
        echo "mutation-verify.sh: warning: clock did not advance before restore touch; dependent builds may remain stale" >&2
        break
      fi
      sleep 0.2
      restore_waits=$((restore_waits + 1))
    done
  fi
  touch "$file" || echo "mutation-verify.sh: warning: failed to refresh mtime for $file; dependent builds may remain stale" >&2
  restored=1
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

# sum_count_lines <rest> <file>: the sum of every <n> in "<n><rest>" in <file>,
# where <n> is the maximal digit run right before <rest> and no digit follows
# <rest>. "1 filtered out" printed by two cargo test binaries sums to 2; "11
# deselected" counts as 11, never as 1. C locale so odd bytes cannot abort awk.
sum_count_lines() {
  LC_ALL=C MV_COUNT_REST="$1" awk '
    BEGIN { t = ENVIRON["MV_COUNT_REST"]; n = length(t); sum = 0 }
    {
      line = $0; off = 0
      while ((i = index(line, t)) > 0) {
        pos = off + i
        post = substr($0, pos + n, 1)
        k = pos - 1; digits = ""
        while (k >= 1 && substr($0, k, 1) ~ /[0-9]/) { digits = substr($0, k, 1) digits; k-- }
        if (digits != "" && post !~ /[0-9]/) sum += digits + 0
        off = pos; line = substr($0, off + 1)
      }
    }
    END { print sum }' "$2"
}

# count_prefix_lines <prefix> <file>: lines of <file> that start with <prefix>.
count_prefix_lines() {
  LC_ALL=C MV_PREFIX="$1" awk '
    BEGIN { p = ENVIRON["MV_PREFIX"]; n = length(p); c = 0 }
    substr($0, 1, n) == p { c++ }
    END { print c }' "$2"
}

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
have_expect_fail=0
for _o in ${expect_fail_outputs[@]+"${expect_fail_outputs[@]}"}; do
  have_expect_fail=1
  break
done
baseline_rc=0
baseline_out="$snap_dir/baseline-run.out"
baseline_cmd="$test_cmd"
if [ "$have_expect_fail" -eq 1 ] && [ "$have_cover_check" -eq 1 ]; then
  # The mutated run adds -coverprofile, which prints its own lines (e.g.
  # "coverage: N% of statements"). Run the baseline the same way so text
  # every coverprofile run prints is refused below.
  baseline_cmd="$(test_cmd_with_coverprofile "$test_cmd" "$snap_dir/baseline-cover.out")" || {
    echo "mutation-verify.sh: --cover-check requires --test-cmd to contain a Go package test command (go test <package>)" >&2
    exit 2
  }
fi
if [ "$have_expect_fail" -eq 1 ]; then
  # Capture to a file, not through a pipe: a pipe would wait on any
  # background child that inherited the test's output.
  ( eval "$baseline_cmd" ) >"$baseline_out" 2>&1 || baseline_rc=$?
  cat "$baseline_out"
else
  ( eval "$test_cmd" ) || baseline_rc=$?
fi
if [ "$baseline_rc" -ne 0 ]; then
  baseline_note=""
  [ "$baseline_cmd" = "$test_cmd" ] || baseline_note=", run with -coverprofile added for --cover-check"
  echo "mutation-verify.sh: test-cmd does not pass before mutation (baseline exited $baseline_rc$baseline_note) — the instrument is invalid" >&2
  exit 2
fi
# An --expect-fail-output (or --control-expect-fail-output) string that a
# PASSING run already prints (a test name echoed on success, say) cannot tell
# one failure from any other.
for _o in ${expect_fail_outputs[@]+"${expect_fail_outputs[@]}"}; do
  if grep -F -q -- "$_o" "$baseline_out"; then
    echo "mutation-verify.sh: --expect-fail-output text already appears in the passing baseline output, so it cannot identify the failure: $_o" >&2
    echo "mutation-verify.sh: use text only the failing hazard assertion prints" >&2
    exit 2
  fi
done
for _c in ${control_expect_outputs[@]+"${control_expect_outputs[@]}"}; do
  if grep -F -q -- "$_c" "$baseline_out"; then
    echo "mutation-verify.sh: --control-expect-fail-output text already appears in the passing baseline output, so it cannot identify the control's failure: $_c" >&2
    echo "mutation-verify.sh: use text only the control test's failing assertion prints" >&2
    exit 2
  fi
done

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

for _a in ${control_anchors[@]+"${control_anchors[@]}"}; do
  if ! grep -F -q -- "$_a" "$snap_file"; then
    echo "mutation-verify.sh: CONTROL ANCHOR NOT FOUND — expected control anchor is absent from the unmutated $file: $_a" >&2
    exit 2
  fi
done

# Knock-out baseline: the hazard-deselected command must pass on the
# unmutated copy (a bad flag or runner error would otherwise "confirm" by
# printing nothing), and must not already print any expected text.
if [ "$have_knockout" -eq 1 ]; then
  knockout_base_rc=0
  knockout_base_out="$snap_dir/knockout-baseline.out"
  ( eval "$knockout_cmd" ) >"$knockout_base_out" 2>&1 || knockout_base_rc=$?
  cat "$knockout_base_out"
  if [ "$knockout_base_rc" -ne 0 ]; then
    echo "mutation-verify.sh: KNOCK-OUT BROKEN — --knockout-cmd does not pass before mutation (exited $knockout_base_rc); a broken knock-out would confirm by printing nothing" >&2
    exit 2
  fi
  for _o in "${expect_fail_outputs[@]}"; do
    if grep -F -q -- "$_o" "$knockout_base_out"; then
      echo "mutation-verify.sh: --expect-fail-output text already appears in the passing knock-out baseline output: $_o" >&2
      exit 2
    fi
  done
  if [ ! -s "$knockout_base_out" ] || cmp -s "$knockout_base_out" "$baseline_out"; then
    echo "mutation-verify.sh: KNOCK-OUT CHANGED NOTHING — the knock-out baseline printed nothing, or exactly what the full baseline printed; it cannot show which tests it deselected" >&2
    exit 2
  fi
  # Scope proof: a runner line showing exactly one test was deselected
  # (pytest "1 deselected", cargo "1 filtered out"), matched as a whole number,
  # and not already printed by the full run (a filter in --test-cmd).
  # The tool sums every "<n><rest>" occurrence: the full run must show 0 and
  # the knock-out exactly the declared number (several cargo test binaries
  # each printing "1 filtered out" sum past 1).
  for _k in ${knockout_expect_outputs[@]+"${knockout_expect_outputs[@]}"}; do
    _want="${_k%%[!0-9]*}"; _rest="${_k#"$_want"}"; _want=$((10#$_want))
    _full_sum="$(sum_count_lines "$_rest" "$baseline_out")"
    if [ "$_full_sum" -ne 0 ]; then
      echo "mutation-verify.sh: KNOCK-OUT SCOPE UNPROVEN — the full, unmutated run already prints the --knockout-expect-output line (its counts sum to $_full_sum), so it cannot show the knock-out's deselection: $_k" >&2
      exit 2
    fi
    _ko_sum="$(sum_count_lines "$_rest" "$knockout_base_out")"
    if [ "$_ko_sum" -ne "$_want" ]; then
      echo "mutation-verify.sh: KNOCK-OUT SCOPE UNPROVEN — the knock-out baseline's '<n>$_rest' counts sum to $_ko_sum, not the declared --knockout-expect-output as a whole number: $_k" >&2
      exit 2
    fi
  done
  # Delta line: exactly one fewer per-test line (e.g. go -v '=== RUN ') in the
  # knock-out than in the full run, so exactly one test (or subtest) went.
  if [ "$have_knockout_delta" -eq 1 ]; then
    _full_lines="$(count_prefix_lines "$knockout_delta_line" "$baseline_out")"
    _ko_lines="$(count_prefix_lines "$knockout_delta_line" "$knockout_base_out")"
    if [ "$((_full_lines - _ko_lines))" -ne 1 ]; then
      echo "mutation-verify.sh: KNOCK-OUT SCOPE UNPROVEN — lines starting with --knockout-delta-line '$knockout_delta_line': full run $_full_lines, knock-out $_ko_lines; exactly one fewer is required" >&2
      exit 2
    fi
  fi
fi

# Mutate.
if [ "$have_sed" -eq 1 ]; then
  # Read FROM the snapshot, write TO the file — sidesteps GNU-vs-BSD `sed -i`
  # portability entirely.
  mutation_rc=0
  sed "$mutate_sed" "$snap_file" > "$file" || mutation_rc=$?
  mut_sec=$(date +%s)
  if [ "$mutation_rc" -ne 0 ]; then
    echo "mutation-verify.sh: sed mutation command failed" >&2
    exit 2
  fi
else
  # Subshell: a --mutate-cmd that `cd`s must not change this script's cwd.
  mutation_rc=0
  ( eval "$mutate_cmd" ) || mutation_rc=$?
  mut_sec=$(date +%s)
  if [ "$mutation_rc" -ne 0 ]; then
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
mutated_cmd="$test_cmd"
if [ "$have_cover_check" -eq 1 ]; then
  cover_profile="$snap_dir/cover.out"
  mutated_cmd="$(test_cmd_with_coverprofile "$test_cmd" "$cover_profile")" || {
    echo "mutation-verify.sh: --cover-check requires --test-cmd to contain a Go package test command (go test <package>)" >&2
    exit 2
  }
fi
mutated_out="$snap_dir/mutated-run.out"
if [ "$have_expect_fail" -eq 1 ]; then
  ( eval "$mutated_cmd" ) >"$mutated_out" 2>&1 || test_rc=$?
  cat "$mutated_out"
else
  ( eval "$mutated_cmd" ) || test_rc=$?
fi

# Knock-out: on the SAME mutated copy, run the test command with only the
# hazard test deselected — only when the main run would be CAUGHT (RED with
# every expected text). The verdict uses it after the exit-3 check below.
knockout_ran=0
if [ "$have_knockout" -eq 1 ] && [ "$test_rc" -ne 0 ]; then
  _all_present=1
  for _o in "${expect_fail_outputs[@]}"; do
    grep -F -q -- "$_o" "$mutated_out" || { _all_present=0; break; }
  done
  if [ "$_all_present" -eq 1 ]; then
    knockout_out="$snap_dir/knockout-run.out"
    knockout_rc=0
    ( eval "$knockout_cmd" ) >"$knockout_out" 2>&1 || knockout_rc=$?
    cat "$knockout_out"
    knockout_ran=1
  fi
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

# Main expected-text check first: a RED run without the text is a survivor
# (exit 3) whatever a control would show, so the control never runs then.
if [ "$test_rc" -ne 0 ] && [ "$have_expect_fail" -eq 1 ]; then
  for _o in "${expect_fail_outputs[@]}"; do
    if ! grep -F -q -- "$_o" "$mutated_out"; then
      skipped_control=""
      [ "$have_control" -eq 1 ] && skipped_control="; control not run"
      [ "$have_knockout" -eq 1 ] && skipped_control="$skipped_control; knock-out not run"
      echo "mutation-verify.sh: ${verdict_prefix}RED FOR AN UNRELATED REASON (test-cmd exited $test_rc under mutation$reachability_suffix$skipped_control) — expected failure text absent: $_o" >&2
      echo "mutation-verify.sh: the hazard assertion is not shown to have caught this mutant; treat it as a surviving mutant (a test gap). Change the expected text only if this output shows the hazard assertion itself failing at its own location (see docs/commands.md)" >&2
      exit 3
    fi
  done
fi

# Knock-out verdict: the expected text must disappear when only the hazard
# test is deselected; text that persists comes from another test.
knockout_suffix=""
if [ "$have_expect_fail" -eq 1 ] && [ "$have_knockout" -eq 0 ]; then
  knockout_suffix="; knock-out NOT run, so the text is not attributed to the hazard test"
fi
if [ "$knockout_ran" -eq 1 ]; then
  for _o in "${expect_fail_outputs[@]}"; do
    if grep -F -q -- "$_o" "$knockout_out"; then
      echo "mutation-verify.sh: TEXT PERSISTS WITHOUT THE HAZARD TEST — the knock-out run on the same mutant also printed: $_o" >&2
      echo "mutation-verify.sh: another test prints it, or the knock-out did not deselect the hazard test (unknown ids are often silently ignored); record the main mutant as UNPROVEN" >&2
      exit 2
    fi
  done
  # The mutated knock-out run must still show the same scope (a crash or
  # truncation would otherwise make the text "disappear").
  for _k in ${knockout_expect_outputs[@]+"${knockout_expect_outputs[@]}"}; do
    _want="${_k%%[!0-9]*}"; _rest="${_k#"$_want"}"; _want=$((10#$_want))
    _mut_sum="$(sum_count_lines "$_rest" "$knockout_out")"
    if [ "$_mut_sum" -ne "$_want" ]; then
      echo "mutation-verify.sh: KNOCK-OUT SCOPE UNPROVEN ON THE MUTANT — the knock-out run on the mutant shows '<n>$_rest' summing to $_mut_sum, not $_k (truncated or crashed?)" >&2
      exit 2
    fi
  done
  if [ "$have_knockout_delta" -eq 1 ]; then
    _main_lines="$(count_prefix_lines "$knockout_delta_line" "$mutated_out")"
    _komut_lines="$(count_prefix_lines "$knockout_delta_line" "$knockout_out")"
    if [ "$((_main_lines - _komut_lines))" -ne 1 ]; then
      echo "mutation-verify.sh: KNOCK-OUT SCOPE UNPROVEN ON THE MUTANT — lines starting with '$knockout_delta_line': main run $_main_lines, knock-out run $_komut_lines on the mutant; exactly one fewer is required (truncated or crashed?)" >&2
      exit 2
    fi
  fi
  knockout_scope=""
  for _k in ${knockout_expect_outputs[@]+"${knockout_expect_outputs[@]}"}; do
    knockout_scope="$knockout_scope${knockout_scope:+, }'$_k'"
  done
  if [ "$have_knockout_delta" -eq 1 ]; then
    knockout_scope="$knockout_scope${knockout_scope:+, }one fewer '$knockout_delta_line' line"
  fi
  knockout_scope=", deselection shown by $knockout_scope"
  knockout_suffix="; knock-out \`$knockout_cmd\` (exited $knockout_rc on the mutant$knockout_scope) removed the expected text, so it is attributed to the test(s) that command deselects"
fi

# Control mutant: only when the main run would be CAUGHT. Same fresh-copy
# mutation and applied-verification as the main mutant; same file capture.
# It must go RED for its own seeded reason (--control-expect-fail-output
# present) and must not print any main expected text.
control_suffix=""
if [ "$have_expect_fail" -eq 1 ] && [ "$have_control" -eq 0 ]; then
  control_suffix="; control NOT run, so the text's specificity is unchecked"
fi
if [ "$have_control" -eq 1 ] && [ "$test_rc" -ne 0 ]; then
  for _c in "${control_expect_outputs[@]}"; do
    if grep -F -q -- "$_c" "$mutated_out"; then
      echo "mutation-verify.sh: CONTROL TEXT IN THE MAIN RUN — the main mutated run already printed the control's failure text, so the two failures cannot be told apart: $_c" >&2
      exit 2
    fi
  done
  restored=0
  control_mut_rc=0
  if [ "$have_control_sed" -eq 1 ]; then
    sed "$control_sed" "$snap_file" > "$file" || control_mut_rc=$?
  else
    ( eval "$control_cmd" ) || control_mut_rc=$?
  fi
  mut_sec=$(date +%s)
  if [ "$control_mut_rc" -ne 0 ]; then
    echo "mutation-verify.sh: control mutation command failed" >&2
    exit 2
  fi
  if cmp -s "$snap_file" "$file"; then
    echo "mutation-verify.sh: control mutation did not change $file (no-op control); refusing to emit a verdict" >&2
    exit 2
  fi
  for _m in ${control_markers[@]+"${control_markers[@]}"}; do
    if ! grep -F -q -- "$_m" "$file"; then
      echo "mutation-verify.sh: CONTROL MARKER ABSENT — the control edit did not land as intended: $_m" >&2
      exit 2
    fi
  done
  if [ "$have_syntax" -eq 1 ]; then
    control_syntax_rc=0
    ( eval "$syntax_cmd" ) || control_syntax_rc=$?
    if [ "$control_syntax_rc" -ne 0 ]; then
      echo "mutation-verify.sh: CONTROL FILE INVALID — --syntax-cmd exited $control_syntax_rc after the control mutation; refusing to emit a verdict" >&2
      exit 2
    fi
  fi
  control_rc=0
  control_out="$snap_dir/control-run.out"
  ( eval "$baseline_cmd" ) >"$control_out" 2>&1 || control_rc=$?
  cat "$control_out"
  restore_file
  if ! verify_restore; then
    echo "mutation-verify.sh: RESTORE FAILED — $file is not byte-identical to its snapshot after the control run" >&2
    exit 2
  fi
  if [ "$control_rc" -eq 0 ]; then
    echo "mutation-verify.sh: CONTROL INERT — the control mutant left test-cmd green, so it proves nothing about the expected text" >&2
    exit 2
  fi
  for _c in "${control_expect_outputs[@]}"; do
    if ! grep -F -q -- "$_c" "$control_out"; then
      echo "mutation-verify.sh: CONTROL RED FOR AN UNRELATED REASON — the control run lacks its own --control-expect-fail-output text (a build break or crash is not a control): $_c" >&2
      echo "mutation-verify.sh: do not re-point --control-expect-fail-output at this run's output; a crash is not a control" >&2
      exit 2
    fi
  done
  for _o in "${expect_fail_outputs[@]}"; do
    if grep -F -q -- "$_o" "$control_out"; then
      echo "mutation-verify.sh: EXPECTED TEXT NOT SPECIFIC TO THE HAZARD — the control mutant's RED run also printed: $_o" >&2
      echo "mutation-verify.sh: this refusal stands; record the main mutant as UNPROVEN unless this output shows the hazard test itself failing" >&2
      exit 2
    fi
  done
  control_verified=0
  [ "$have_syntax" -eq 1 ] && control_verified=1
  control_flag=""
  [ "$control_verified" -eq 0 ] && control_flag="[UNVERIFIED CONTROL] "
  control_suffix="; ${control_flag}control went RED for its own reason without the expected text"
fi

if [ "$test_rc" -ne 0 ]; then
  if [ "$have_expect_fail" -eq 1 ]; then
    matched_list=""
    for _o in "${expect_fail_outputs[@]}"; do
      matched_list="$matched_list${matched_list:+, }'$_o'"
    done
    echo "mutation-verify.sh: ${verdict_prefix}mutation CAUGHT (test-cmd exited $test_rc under mutation$reachability_suffix; expected failure text present in output, matched: $matched_list$knockout_suffix$control_suffix) — the RED run printed every --expect-fail-output text" >&2
  else
    echo "mutation-verify.sh: ${verdict_prefix}mutation CAUGHT (test-cmd exited $test_rc under mutation$reachability_suffix; failure cause was NOT checked, pass --expect-fail-output) — test went RED" >&2
  fi
  exit 0
else
  echo "mutation-verify.sh: ${verdict_prefix}mutation NOT caught (test-cmd exited 0 under mutation$reachability_suffix) — false-green test" >&2
  exit 1
fi
