#!/usr/bin/env bash
# shellcheck disable=SC2329
# mutation-verify.sh — snapshot-backed mutation-verify pass for a single file.
#
# Why this exists (issue #115): a mutation-verify pass (revert the fix ->
# confirm the test goes RED -> restore) has THREE times been done with
# `git checkout -- <file>` on an UNCOMMITTED diff. That restores the last
# COMMITTED baseline — discarding the in-flight fix AND yielding a false
# "mutation-proof" pass. This helper is snapshot-backed: mutates the real file in place and restores
# it from a mktemp snapshot; never run two in-place mutants concurrently in
# one tree — use --copy-root / mutation-sweep.sh for parallel mutants. It never
# invokes git, so it is immune to commit state and does NOT need a clean tree.
#
# Usage:
#   mutation-verify.sh --file <path> --test-cmd <shell-command> \
#     (--mutate-sed <sed-expr> | --mutate-cmd <shell-command>)
#
# --copy-root <dir> runs each phase in an isolated copy.
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
#     and nothing else after --test-cmd (any other suffix exits 2), with a
#     required scope proof: --knockout-expect-output '1<rest>' (every
#     "<n><rest>" in the output is summed; the full run must sum to 0 and the
#     knock-out to 1) and/or --knockout-delta-line '=== RUN ' (exactly one
#     fewer such line than the full run). The knock-out must
#     start with --test-cmd and differ from it, pass green on the unmutated
#     file, print something different from the full baseline, not print any
#     expected text there, and pass its scope proof, also on the mutant
#     (exit 2 otherwise). On the same mutated file, and only when the main run would
#     be CAUGHT, the expected text must disappear; if it persists, another test
#     prints it (or the deselect missed) and the run exits 2. The verdict names
#     the command, its exit code on the mutant and the count line. Without it,
#     CAUGHT says the knock-out did not run.
#
# Control mutant (issue foundry#259; requires --expect-fail-output; recommended):
#   --control-sed <expr> | --control-cmd <cmd> (with --control-expect-fail-output,
#     the control test's own failure line) applies a second mutation that
#     breaks a DIFFERENT behavior: the real file restored from the snapshot, then the
#     control mutation, with the same no-op, --control-anchor / --control-marker
#     and --syntax-cmd checks.
#     It must edit only --file. It runs only when the main run would be CAUGHT
#     (a RED run without the expected text stays exit 3). Exit 2 when the
#     control's text is already in the main run, the control is inert, its RED
#     run lacks its own text, or it prints any expected text. One passing
#     control shows only that that one other failure does not print the text.
#     Without a control, a CAUGHT verdict says the control did not run. The
#     control counts as verified only when --syntax-cmd checked the control-mutated file.
#
# --file is resolved to an ABSOLUTE path before snapshotting, and both
# --test-cmd and --mutate-cmd run inside a subshell, so a --test-cmd that
# does `cd` elsewhere cannot cause a restore to write to the wrong path.
#
# ABSOLUTE PROHIBITION: this script must NEVER invoke git in any form.
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
[ -r "$SCRIPT_DIR/lib/portable-stat.sh" ] || { echo "mutation-verify.sh: broken install: $SCRIPT_DIR/lib/portable-stat.sh not readable" >&2; exit 2; }
# shellcheck source=lib/portable-stat.sh
. "$SCRIPT_DIR/lib/portable-stat.sh"
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: mutation-verify.sh --file <path> --test-cmd <shell-command> [--copy-root <dir>] \
         [--expect-anchor <str>] [--expect-marker <str>] \
         [--syntax-cmd <shell-command>] [--cover-check <line-or-symbol>] \
         [--expect-fail-output <str>] \
         [--knockout-cmd <shell-command> (--knockout-expect-output <str> | --knockout-delta-line <prefix>)] \
         [(--control-sed <sed-expr> | --control-cmd <shell-command>) \
          --control-expect-fail-output <str> \
          [--control-anchor <str>] [--control-marker <str>]] \
         (--mutate-sed <sed-expr> | --mutate-cmd <shell-command>)

--copy-root <dir> runs each phase in an isolated copy; requires --control-*;
--cover-check unsupported. Caller cwd must be inside the root.

Exactly one of --mutate-sed or --mutate-cmd is required.

--test-cmd is run twice under pipefail: once as a baseline against the
unmutated file (must pass, or the script aborts) and once under mutation.
Use the test runner's own exit status; do not pipe into grep -q or head
(early pipe closure sends SIGPIPE / exit 141 under pipefail).

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
--knockout-expect-output '1<rest>', summed over the output, and/or
--knockout-delta-line '=== RUN ', one fewer line than the full run) is
--test-cmd plus exactly one documented deselect of only the hazard test (cargo
-- --exact --skip <path::name>, go -skip '^Name$' or '^Name$/^row$', pytest
--deselect <path::id>; anything else exits 2); it must pass on the unmutated
file and print something different from the full baseline; on the mutant the
expected text must disappear and the scope proof must still hold, or the run
exits 2.
--control-sed / --control-cmd (requires --expect-fail-output and
--control-expect-fail-output) applies a control mutation that breaks a
different behavior: the real file restored from the snapshot, then the control
mutation, when the main run would be CAUGHT. It must
edit only --file. An inert control, a control RED without its own text, a
control text already in the main run, or a control output holding an expected
text exits 2; --control-anchor / --control-marker verify it the way
--expect-anchor / --expect-marker verify the main mutation.
Missing anchors, missing markers, and failing syntax commands exit 2.
EOF
}

copy_mode=0
real_root=""
VCS_DIR_NAME=".git"
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
    --copy-root) require_value "--copy-root" "$#"; [ "$copy_mode" -eq 0 ] || { echo "mutation-verify.sh: --copy-root given twice" >&2; exit 2; }; real_root="$2"; copy_mode=1; shift 2 ;;
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
      # The knock-out removes exactly the hazard test, so the count is 1.
      if [ "$((10#${2%%[!0-9]*}))" -ne 1 ]; then
        echo "mutation-verify.sh: --knockout-expect-output must declare a count of exactly 1 (the knock-out removes only the hazard test): $2" >&2
        exit 2
      fi
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
      # Only the documented go -v prefix: one line per test and subtest.
      if [ "$2" != "=== RUN " ]; then
        echo "mutation-verify.sh: --knockout-delta-line must be exactly '=== RUN ' (the go -v per-test line): $2" >&2
        exit 2
      fi
      knockout_delta_line="$2"; have_knockout_delta=1; shift 2 ;;
    --control-anchor) require_value "--control-anchor" "$#"; control_anchors+=("$2"); shift 2 ;;
    --control-marker) require_value "--control-marker" "$#"; control_markers+=("$2"); shift 2 ;;
    -h|--help) usage; exit 2 ;;
    *) echo "mutation-verify.sh: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# Retained for copy-mode routing and caller-facing diagnostics in the next task.
# shellcheck disable=SC2034
file_given="$file"
if [ "$copy_mode" -eq 1 ]; then
  if [ "$have_control_sed" -eq 0 ] && [ "$have_control_cmd" -eq 0 ]; then
    echo "mutation-verify.sh: --copy-root requires a control" >&2
    exit 2
  fi
  if [ "$have_cover_check" -eq 1 ]; then
    echo 'mutation-verify.sh: --cover-check is not supported with --copy-root' >&2
    exit 2
  fi
  root_given="$real_root"
  real_root="$(cd -P "$real_root" && pwd -P)" || { echo "mutation-verify.sh: cannot resolve --copy-root" >&2; exit 2; }
  # Match literal roots with a boundary, never relative spellings such as '.'.
  real_path_command() {
    local value="$1" root tail root_alias
    root_alias="$real_root"
    case "$real_root" in /private/var/*) root_alias="${real_root#/private}" ;; /var/*) root_alias="/private$real_root" ;; esac
    for root in "$root_given" "$real_root" "$root_alias"; do
      case "$root" in /*) ;; *) continue ;; esac
      while [[ "$value" == *"$root"* ]]; do
        tail="${value#*"$root"}"
        case "$tail" in
          ''|[!A-Za-z0-9._-]*) return 0 ;;
        esac
        value="$tail"
      done
      value="$1"
    done
    return 1
  }
  for command_flag in --test-cmd --mutate-cmd --syntax-cmd --control-cmd --knockout-cmd; do
    case "$command_flag" in
      --test-cmd) command_value="$test_cmd" ;;
      --mutate-cmd) command_value="$mutate_cmd" ;;
      --syntax-cmd) command_value="$syntax_cmd" ;;
      --control-cmd) command_value="$control_cmd" ;;
      --knockout-cmd) command_value="$knockout_cmd" ;;
    esac
    if real_path_command "$command_value"; then
      echo "mutation-verify.sh: command refers to the real tree ($command_flag): use paths relative to the copy or \$MUTATION_VERIFY_COPY_ROOT" >&2
      exit 2
    fi
  done
fi

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
  # The part after --test-cmd must be one documented exact deselect (and
  # nothing else, such as --lib or --ignore before it):
  #   cargo:  -- --exact --skip <path::name>
  #   go:     -skip '^Name$'  or  -skip '^Name$/^row$'
  #   pytest: --deselect <path::id>
  _ko_suffix="${knockout_cmd#"$test_cmd"}"
  _re_cargo='^ -- --exact --skip [A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*$'
  _re_go="^ -skip '\\^[A-Za-z0-9_]+\\\$(/\\^[A-Za-z0-9_]+\\\$)?'\$"
  # pytest ids: an allowlist (letters, digits, _ . / = , + @ - [ ] and ::), no
  # whitespace, braces, globs, quotes or other shell metacharacters.
  _id_chars='[]A-Za-z0-9_./=,+@[-]'
  _re_pytest="^ --deselect ('${_id_chars}+::${_id_chars}+(::${_id_chars}+)*'|${_id_chars}+::${_id_chars}+(::${_id_chars}+)*)\$"
  if [[ ! "$_ko_suffix" =~ $_re_cargo ]] && [[ ! "$_ko_suffix" =~ $_re_go ]] && [[ ! "$_ko_suffix" =~ $_re_pytest ]]; then
    echo "mutation-verify.sh: --knockout-cmd must be --test-cmd plus exactly one documented deselect (cargo: -- --exact --skip <path::name>; go: -skip '^Name\$' or '^Name\$/^row\$'; pytest: --deselect <path::id>), with nothing else; got the suffix:$_ko_suffix" >&2
    exit 2
  fi
  # cargo: a test command that already has a "--" section would make the
  # appended "-- --exact --skip <name>" a second "--", turning every word after
  # it into a name FILTER (run only the hazard test). Refuse it.
  if [[ "$_ko_suffix" =~ $_re_cargo ]]; then
    read -r -a _tc_words <<<"$test_cmd"
    for _w in ${_tc_words[@]+"${_tc_words[@]}"}; do
      if [ "$_w" = "--" ]; then
        echo "mutation-verify.sh: the cargo knock-out needs a --test-cmd without its own '--' section (e.g. no '-- --nocapture'); the appended '-- --exact --skip' would become a name filter" >&2
        exit 2
      fi
    done
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
if [ "$copy_mode" -eq 0 ] && [ ! -e "$file" ]; then
  echo "mutation-verify.sh: --file does not exist: $file" >&2
  exit 2
fi
if [ "$copy_mode" -eq 0 ] && [ ! -f "$file" ]; then
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

# Copy setup owns its cleanup independently of the in-place restore path.
if [ "$copy_mode" -eq 1 ]; then
  file="$(cd -P "$(dirname "$file")" && printf '%s/%s' "$(pwd -P)" "$(basename "$file")")" || { echo "mutation-verify.sh: cannot resolve --file" >&2; exit 2; }
  [ -e "$file" ] || { echo "mutation-verify.sh: --file does not exist: $file" >&2; exit 2; }
  [ -f "$file" ] || { echo "mutation-verify.sh: --file is not a regular file: $file" >&2; exit 2; }
  case "$file" in
    "$real_root"/*) file_rel="${file#"$real_root"/}" ;;
    *) echo 'mutation-verify.sh: --file is not under --copy-root' >&2; exit 2 ;;
  esac
  if [ -L "$real_root/$file_rel" ]; then
    echo 'mutation-verify.sh: --file is a symlink; copy mode needs a regular file' >&2
    exit 2
  fi
  caller_cwd="$(pwd -P)"
  cwd_rel=""
  case "$caller_cwd" in "$real_root") ;; "$real_root"/*) cwd_rel="${caller_cwd#"$real_root"/}" ;; *) echo "mutation-verify.sh: caller cwd is outside --copy-root" >&2; exit 2 ;; esac
  real_file="$file"
  real_checksum="$(cksum < "$file")"
  file_mtime() {
    pstat_mtime "$real_file"
  }
  real_mtime="$(file_mtime)"
  # Reap only our uid's dead-owner copies; never signal a former owner.
  for stale in "${TMPDIR:-/tmp}"/mutation-verify-copy.[0-9]*.*; do
    [ -d "$stale" ] && [ ! -L "$stale" ] || continue
    stale_uid=$(pstat_uid "$stale") || continue
    [ "$stale_uid" = "$(id -u)" ] || continue
    stale_owner=${stale##*/}; stale_owner=${stale_owner#mutation-verify-copy.}; stale_owner=${stale_owner%%.*}
    [[ "$stale_owner" =~ ^[0-9]+$ ]] || continue
    kill -0 "$stale_owner" 2>/dev/null && continue
    chmod -R u+w "$stale" 2>/dev/null || :
    rm -rf "$stale" 2>/dev/null || :
  done
  copy_parent="$(mktemp -d "${TMPDIR:-/tmp}/mutation-verify-copy.$$.XXXXXX")" || {
    echo 'mutation-verify.sh: copy failed: cannot create temporary directory' >&2; exit 2;
  }
  copy_parent="$(cd -P "$copy_parent" && pwd -P)" || { echo "mutation-verify.sh: cannot resolve copy directory" >&2; exit 2; }
  cleanup_done=0
  snap_dir=""
  cleanup() {
    [ "$cleanup_done" -eq 1 ] && return 0
    cleanup_done=1
    if [ "$(cksum < "$real_file")" != "$real_checksum" ] || [ "$(file_mtime)" != "$real_mtime" ]; then
      echo 'mutation-verify.sh: hint: the real file changed during the run (edited externally?); the verdict applies to the snapshot' >&2
    fi
    if [ -n "$copy_parent" ]; then
      chmod -R u+w "$copy_parent" 2>/dev/null
      rm -rf "$copy_parent"
    fi
    [ -z "$snap_dir" ] || rm -rf "$snap_dir"
    return 0
  }
  trap cleanup EXIT
  trap 'cleanup; trap - INT; kill -s INT $$' INT
  trap 'cleanup; trap - TERM; kill -s TERM $$' TERM
  case "$copy_parent" in
    "$real_root"|"$real_root"/*) echo 'mutation-verify.sh: TMPDIR is inside --copy-root' >&2; exit 2 ;;
  esac
  pristine="$copy_parent/pristine"
  mkdir "$pristine" || { echo 'mutation-verify.sh: copy failed: mkdir pristine' >&2; exit 2; }
  copy_entry() {
    local source="$1" destination="$2"
    cp -c -pR "$source" "$destination" 2>/dev/null && return 0
    [ -n "$destination" ] && rm -rf "$destination"
    cp -pR "$source" "$destination"
  }
  shopt -s nullglob
  for entry in "$real_root"/* "$real_root"/.[!.]* "$real_root"/..?*; do
    [ "$(basename "$entry")" = "$VCS_DIR_NAME" ] && continue
    copy_entry "$entry" "$pristine/$(basename "$entry")" || {
      echo "mutation-verify.sh: copy failed: $(basename "$entry")" >&2; exit 2;
    }
  done
  shopt -u nullglob
  tree_hash="$( (cd "$pristine" && find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r f; do if [ -L "$f" ]; then printf 'L %s %s\n' "$f" "$(readlink "$f")"; else mode="$(pstat_mode "$f")"; printf 'F %s %s %s\n' "$f" "$mode" "$(cksum < "$f")"; fi; done) | cksum | cut -d' ' -f1)"
  make_copy() { copy_entry "$pristine" "$1"; }
  copy_cwd() {
    if [ -n "$cwd_rel" ]; then printf '%s/%s\n' "$1" "$cwd_rel"; else printf '%s\n' "$1"; fi
  }
  run_in_copy() {
    ( cd "$(copy_cwd "$1")" && MUTATION_VERIFY_COPY_ROOT="$1" MUTATION_VERIFY_FILE="$1/$file_rel" eval "$2" )
  }
  file="$file_given"
fi

if [ "$copy_mode" -eq 0 ]; then
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

fi

# Capture files remain outside phase trees in both modes.
if [ "$copy_mode" -eq 1 ]; then
  snap_dir="$(mktemp -d "$copy_parent/capture.XXXXXX")" || { echo "mutation-verify.sh: capture failure: cannot create capture directory tree=$tree_hash" >&2; exit 2; }
  snap_file="$pristine/$file_rel"
fi
cur_file="$file"
run_command() {
  local command_text="$1"
  shift
  if [ "$copy_mode" -eq 1 ]; then
    run_in_copy "$active_copy" "$command_text"
  else
    ( eval "$command_text" )
  fi
}
select_copy() {
  active_copy="$copy_parent/$1"
  make_copy "$active_copy" || {
    echo "mutation-verify.sh: copy failed: $1 tree=$tree_hash" >&2
    exit 2
  }
  cur_file="$active_copy/$file_rel"
}
report() {
  if [ "$copy_mode" -eq 1 ]; then
    echo "$* tree=$tree_hash"
  else
    echo "$*"
  fi
}

capture_command() {
  local capture_cmd="$1" capture_path="$2" capture_rc=0
  if ! ( : > "$capture_path" ); then
    report "mutation-verify.sh: capture failure: cannot open output file" >&2
    exit 2
  fi
  # Keep the capture open before running the command. A redirect failure is
  # distinguishable from the command's own exit status.
  if ! exec 9>"$capture_path"; then
    report "mutation-verify.sh: capture failure: cannot open output file" >&2
    exit 2
  fi
  run_command "$capture_cmd" >&9 2>&1 || capture_rc=$?
  exec 9>&-
  # ENOSPC can happen after opening. Verify capture storage independently.
  if ! printf '.' > "$snap_dir/capture-probe"; then
    report "mutation-verify.sh: capture failure: cannot write output file" >&2
    exit 2
  fi
  rm -f "$snap_dir/capture-probe"
  return "$capture_rc"
}

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
[ "$copy_mode" -eq 0 ] || select_copy baseline
baseline_rc=0
baseline_out="$snap_dir/baseline-run.out"
baseline_cmd="$test_cmd"
if [ "$have_expect_fail" -eq 1 ] && [ "$have_cover_check" -eq 1 ]; then
  # The mutated run adds -coverprofile, which prints its own lines (e.g.
  # "coverage: N% of statements"). Run the baseline the same way so text
  # every coverprofile run prints is refused below.
  baseline_cmd="$(test_cmd_with_coverprofile "$test_cmd" "$snap_dir/baseline-cover.out")" || {
    report "mutation-verify.sh: --cover-check requires --test-cmd to contain a Go package test command (go test <package>)" >&2
    exit 2
  }
fi
if [ "$have_expect_fail" -eq 1 ]; then
  # Capture to a file, not through a pipe: a pipe would wait on any
  # background child that inherited the test's output.
  capture_command "$baseline_cmd" "$baseline_out" || baseline_rc=$?
  cat "$baseline_out"
else
  run_command "$test_cmd" || baseline_rc=$?
fi
if [ "$baseline_rc" -ne 0 ]; then
  baseline_note=""
  [ "$baseline_cmd" = "$test_cmd" ] || baseline_note=", run with -coverprofile added for --cover-check"
  report "mutation-verify.sh: test-cmd does not pass before mutation (baseline exited $baseline_rc$baseline_note) — the instrument is invalid" >&2
  if [ "$baseline_rc" -eq 141 ]; then
    report "mutation-verify.sh: hint: exit 141 is SIGPIPE under pipefail — if --test-cmd pipes a test runner into grep -q or head, the early pipe close kills the runner; pass the test runner's own exit status instead" >&2
  fi
  exit 2
fi
# An --expect-fail-output (or --control-expect-fail-output) string that a
# PASSING run already prints (a test name echoed on success, say) cannot tell
# one failure from any other.
for _o in ${expect_fail_outputs[@]+"${expect_fail_outputs[@]}"}; do
  if grep -F -q -- "$_o" "$baseline_out"; then
    report "mutation-verify.sh: --expect-fail-output text already appears in the passing baseline output, so it cannot identify the failure: $_o" >&2
    report "mutation-verify.sh: hint: use text only the failing hazard assertion prints" >&2
    exit 2
  fi
done
for _c in ${control_expect_outputs[@]+"${control_expect_outputs[@]}"}; do
  if grep -F -q -- "$_c" "$baseline_out"; then
    report "mutation-verify.sh: --control-expect-fail-output text already appears in the passing baseline output, so it cannot identify the control's failure: $_c" >&2
    report "mutation-verify.sh: hint: use text only the control test's failing assertion prints" >&2
    exit 2
  fi
done

# Applied-verification, part 1 (applied-verification): assert every expected anchor is
# present in the ORIGINAL file before mutating. The post-hoc cmp check below only
# infers a zero-match from unchanged bytes, which a --mutate-cmd that writes
# something ELSE can slip past. Checking up front names the real defect.
for _a in ${expect_anchors[@]+"${expect_anchors[@]}"}; do
  if ! grep -F -q -- "$_a" "$snap_file"; then
    report "mutation-verify.sh: ANCHOR NOT FOUND — expected anchor is absent from the unmutated $file: $_a" >&2
    report "mutation-verify.sh: hint: the mutation would target zero sites; fix the anchor, do not trust a verdict from this run" >&2
    exit 2
  fi
done

for _a in ${control_anchors[@]+"${control_anchors[@]}"}; do
  if ! grep -F -q -- "$_a" "$snap_file"; then
    report "mutation-verify.sh: CONTROL ANCHOR NOT FOUND — expected control anchor is absent from the unmutated $file: $_a" >&2
    exit 2
  fi
done

# Knock-out baseline: the hazard-deselected command must pass on the
# unmutated file (a bad flag or runner error would otherwise "confirm" by
# printing nothing), and must not already print any expected text.
if [ "$have_knockout" -eq 1 ]; then
  knockout_base_rc=0
  knockout_base_out="$snap_dir/knockout-baseline.out"
  capture_command "$knockout_cmd" "$knockout_base_out" || knockout_base_rc=$?
  cat "$knockout_base_out"
  if [ "$knockout_base_rc" -ne 0 ]; then
    report "mutation-verify.sh: KNOCK-OUT BROKEN — --knockout-cmd does not pass before mutation (exited $knockout_base_rc); a broken knock-out would confirm by printing nothing" >&2
    exit 2
  fi
  for _o in "${expect_fail_outputs[@]}"; do
    if grep -F -q -- "$_o" "$knockout_base_out"; then
      report "mutation-verify.sh: --expect-fail-output text already appears in the passing knock-out baseline output: $_o" >&2
      exit 2
    fi
  done
  if [ ! -s "$knockout_base_out" ] || cmp -s "$knockout_base_out" "$baseline_out"; then
    report "mutation-verify.sh: KNOCK-OUT CHANGED NOTHING — the knock-out baseline printed nothing, or exactly what the full baseline printed; it cannot show which tests it deselected" >&2
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
      report "mutation-verify.sh: KNOCK-OUT SCOPE UNPROVEN — the full, unmutated run already prints the --knockout-expect-output line (its counts sum to $_full_sum), so it cannot show the knock-out's deselection: $_k" >&2
      exit 2
    fi
    _ko_sum="$(sum_count_lines "$_rest" "$knockout_base_out")"
    if [ "$_ko_sum" -ne "$_want" ]; then
      report "mutation-verify.sh: KNOCK-OUT SCOPE UNPROVEN — the knock-out baseline's '<n>$_rest' counts sum to $_ko_sum, not the declared --knockout-expect-output as a whole number: $_k" >&2
      exit 2
    fi
  done
  # Delta line: exactly one fewer per-test line (e.g. go -v '=== RUN ') in the
  # knock-out than in the full run, so exactly one test (or subtest) went.
  if [ "$have_knockout_delta" -eq 1 ]; then
    _full_lines="$(count_prefix_lines "$knockout_delta_line" "$baseline_out")"
    _ko_lines="$(count_prefix_lines "$knockout_delta_line" "$knockout_base_out")"
    if [ "$((_full_lines - _ko_lines))" -ne 1 ]; then
      report "mutation-verify.sh: KNOCK-OUT SCOPE UNPROVEN — lines starting with --knockout-delta-line '$knockout_delta_line': full run $_full_lines, knock-out $_ko_lines; exactly one fewer is required" >&2
      exit 2
    fi
  fi
fi

# Apply and validate a fresh control; copy mode saves its output for later.
run_control() {
  restored=0
  [ "$copy_mode" -eq 0 ] || select_copy control
  control_mut_rc=0
  if [ "$have_control_sed" -eq 1 ]; then
    sed "$control_sed" "$snap_file" > "$cur_file" || control_mut_rc=$?
  else
    run_command "$control_cmd" || control_mut_rc=$?
  fi
  mut_sec=$(date +%s)
  if [ "$control_mut_rc" -ne 0 ]; then
    report "mutation-verify.sh: control mutation command failed" >&2
    exit 2
  fi
  if cmp -s "$snap_file" "$cur_file"; then
    report "mutation-verify.sh: control mutation did not change $file (no-op control); refusing to emit a verdict" >&2
    exit 2
  fi
  for _m in ${control_markers[@]+"${control_markers[@]}"}; do
    if ! grep -F -q -- "$_m" "$cur_file"; then
      report "mutation-verify.sh: CONTROL MARKER ABSENT — the control edit did not land as intended: $_m" >&2
      exit 2
    fi
  done
  if [ "$have_syntax" -eq 1 ]; then
    control_syntax_rc=0
    run_command "$syntax_cmd" || control_syntax_rc=$?
    if [ "$control_syntax_rc" -ne 0 ]; then
      report "mutation-verify.sh: CONTROL FILE INVALID — --syntax-cmd exited $control_syntax_rc after the control mutation; refusing to emit a verdict" >&2
      exit 2
    fi
  fi
  control_rc=0
  control_out="$snap_dir/control-run.out"
  capture_command "$baseline_cmd" "$control_out" || control_rc=$?
  cat "$control_out"
  if [ "$copy_mode" -eq 0 ]; then
    restore_file
    if ! verify_restore; then
      report "mutation-verify.sh: RESTORE FAILED — $file is not byte-identical to its snapshot after the control run" >&2
      exit 2
    fi
  fi
  if [ "$control_rc" -eq 0 ]; then
    if [ "$copy_mode" -eq 1 ]; then
      report "mutation-verify.sh: CONTROL STAYED GREEN IN THE COPY — the test did not read the copy, or the control is inert; run the control in place to tell which" >&2
      exit 2 # copy-mode canary stayed green
    else
      report "mutation-verify.sh: CONTROL INERT — the control mutant left test-cmd green, so it proves nothing about the expected text" >&2
      exit 2
    fi
  else
  for _c in "${control_expect_outputs[@]}"; do
    if ! grep -F -q -- "$_c" "$control_out"; then
      report "mutation-verify.sh: CONTROL RED FOR AN UNRELATED REASON — the control run lacks its own --control-expect-fail-output text (a build break or crash is not a control): $_c" >&2
      report "mutation-verify.sh: hint: do not re-point --control-expect-fail-output at this run's output; a crash is not a control" >&2
      exit 2
    fi
  done
  fi
}

if [ "$copy_mode" -eq 1 ]; then
  if [ -n "$copy_parent" ]; then
    chmod -R u+w "$copy_parent/baseline" 2>/dev/null
    rm -rf "$copy_parent/baseline"
  fi
  run_control
  if [ -n "$copy_parent" ]; then
    chmod -R u+w "$copy_parent/control" 2>/dev/null
    rm -rf "$copy_parent/control"
  fi
fi

# Mutate.
[ "$copy_mode" -eq 0 ] || select_copy main
if [ "$have_sed" -eq 1 ]; then
  # Read FROM the snapshot, write TO the file — sidesteps GNU-vs-BSD `sed -i`
  # portability entirely.
  mutation_rc=0
  sed "$mutate_sed" "$snap_file" > "$cur_file" || mutation_rc=$?
  mut_sec=$(date +%s)
  if [ "$mutation_rc" -ne 0 ]; then
    report "mutation-verify.sh: sed mutation command failed" >&2
    exit 2
  fi
else
  # Subshell: a --mutate-cmd that `cd`s must not change this script's cwd.
  mutation_rc=0
  run_command "$mutate_cmd" || mutation_rc=$?
  mut_sec=$(date +%s)
  if [ "$mutation_rc" -ne 0 ]; then
    report "mutation-verify.sh: --mutate-cmd exited non-zero" >&2
    exit 2
  fi
fi

# Assert the mutation actually changed the file — a no-op mutation (sed
# matched nothing) must never be allowed to produce a bogus verdict.
if cmp -s "$snap_file" "$cur_file"; then
  report "mutation-verify.sh: mutation did not change $file (no-op mutation — the expression matched nothing); aborting before running the test" >&2
  exit 2
fi

# Applied-verification, part 2 (applied-verification): bytes changing is NOT evidence the
# INTENDED mutation landed. A semantically-wrong edit changes bytes, fails the test
# for an unrelated reason, and would be reported CAUGHT — a false pass inside the
# false-green detector.
for _m in ${expect_markers[@]+"${expect_markers[@]}"}; do
  if ! grep -F -q -- "$_m" "$cur_file"; then
    report "mutation-verify.sh: MARKER ABSENT — the file changed but the expected marker is not present after mutation: $_m" >&2
    report "mutation-verify.sh: hint: the edit did not land as intended; refusing to emit a caught/survived verdict" >&2
    exit 2
  fi
done

if [ "$have_syntax" -eq 1 ]; then
  syntax_rc=0
  run_command "$syntax_cmd" || syntax_rc=$?
  if [ "$syntax_rc" -ne 0 ]; then
    report "mutation-verify.sh: MUTATED FILE INVALID — --syntax-cmd exited $syntax_rc after mutation" >&2
    report "mutation-verify.sh: hint: a test failure here would be the wrong RED; refusing to emit a verdict" >&2
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
    report "mutation-verify.sh: --cover-check requires --test-cmd to contain a Go package test command (go test <package>)" >&2
    exit 2
  }
fi
mutated_out="$snap_dir/mutated-run.out"
if [ "$have_expect_fail" -eq 1 ]; then
  capture_command "$mutated_cmd" "$mutated_out" || test_rc=$?
  cat "$mutated_out"
else
  run_command "$mutated_cmd" || test_rc=$?
fi

# Knock-out: on the SAME mutated file, run the test command with only the
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
    capture_command "$knockout_cmd" "$knockout_out" || knockout_rc=$?
    cat "$knockout_out"
    knockout_ran=1
  fi
fi

# Restore now (also covered by the EXIT trap, but do it here so we can
# verify byte-identity before deciding the verdict).
if [ "$copy_mode" -eq 0 ]; then
  restore_file
  if ! verify_restore; then
    report "mutation-verify.sh: RESTORE FAILED — $file is not byte-identical to its snapshot after restore" >&2
    exit 2
  fi
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
  report "mutation-verify.sh: MUTANT-UNREACHABLE (--cover-check $cover_check had zero coverage in $file) — unreachable mutants prove neither killed nor survived" >&2
  exit 1
fi

# Main expected-text check first: a RED run without the text is a survivor
# (exit 3) whatever a control would show, so the control never runs then.
if [ "$test_rc" -ne 0 ] && [ "$have_expect_fail" -eq 1 ]; then
  for _o in "${expect_fail_outputs[@]}"; do
    if ! grep -F -q -- "$_o" "$mutated_out"; then
      skipped_control=""
      [ "$have_control" -eq 1 ] && skipped_control="; control not run"
      [ "$copy_mode" -eq 0 ] || skipped_control="; control ran first (canary)"
      [ "$have_knockout" -eq 1 ] && skipped_control="$skipped_control; knock-out not run"
      inconclusive=""
      [ "$copy_mode" -eq 0 ] || inconclusive="; INCONCLUSIVE in copy mode — confirm with a serial in-place run"
      report "mutation-verify.sh: ${verdict_prefix}RED FOR AN UNRELATED REASON (test-cmd exited $test_rc under mutation$reachability_suffix$skipped_control) — expected failure text absent: $_o$inconclusive" >&2
      report "mutation-verify.sh: hint: the hazard assertion is not shown to have caught this mutant; treat it as a surviving mutant (a test gap). Change the expected text only if this output shows the hazard assertion itself failing at its own location (see docs/commands.md)" >&2
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
      report "mutation-verify.sh: TEXT PERSISTS WITHOUT THE HAZARD TEST — the knock-out run on the same mutant also printed: $_o" >&2
      report "mutation-verify.sh: hint: another test prints it, or the knock-out did not deselect the hazard test (unknown ids are often silently ignored); record the main mutant as UNPROVEN" >&2
      exit 2
    fi
  done
  # The mutated knock-out run must still show the same scope (a crash or
  # truncation would otherwise make the text "disappear").
  for _k in ${knockout_expect_outputs[@]+"${knockout_expect_outputs[@]}"}; do
    _want="${_k%%[!0-9]*}"; _rest="${_k#"$_want"}"; _want=$((10#$_want))
    _mut_sum="$(sum_count_lines "$_rest" "$knockout_out")"
    if [ "$_mut_sum" -ne "$_want" ]; then
      report "mutation-verify.sh: KNOCK-OUT SCOPE UNPROVEN ON THE MUTANT — the knock-out run on the mutant shows '<n>$_rest' summing to $_mut_sum, not $_k (truncated or crashed?)" >&2
      exit 2
    fi
  done
  if [ "$have_knockout_delta" -eq 1 ]; then
    _main_lines="$(count_prefix_lines "$knockout_delta_line" "$mutated_out")"
    _komut_lines="$(count_prefix_lines "$knockout_delta_line" "$knockout_out")"
    if [ "$((_main_lines - _komut_lines))" -ne 1 ]; then
      report "mutation-verify.sh: KNOCK-OUT SCOPE UNPROVEN ON THE MUTANT — lines starting with '$knockout_delta_line': main run $_main_lines, knock-out run $_komut_lines on the mutant; exactly one fewer is required (truncated or crashed?)" >&2
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

# Control mutant: only when the main run would be CAUGHT. The real file is restored
# from the snapshot, then the control mutation is applied; same applied-verification
# as the main mutant and same file capture.
# It must go RED for its own seeded reason (--control-expect-fail-output
# present) and must not print any main expected text.
control_suffix=""
if [ "$have_expect_fail" -eq 1 ] && [ "$have_control" -eq 0 ]; then
  control_suffix="; control NOT run, so the text's specificity is unchecked"
fi
if [ "$have_control" -eq 1 ] && [ "$test_rc" -ne 0 ]; then
  for _c in "${control_expect_outputs[@]}"; do
    if grep -F -q -- "$_c" "$mutated_out"; then
      report "mutation-verify.sh: CONTROL TEXT IN THE MAIN RUN — the main mutated run already printed the control's failure text, so the two failures cannot be told apart: $_c" >&2
      exit 2
    fi
  done
  if [ "$copy_mode" -eq 0 ]; then
    run_control
  fi
  for _o in "${expect_fail_outputs[@]}"; do
    if grep -F -q -- "$_o" "$control_out"; then
      report "mutation-verify.sh: EXPECTED TEXT NOT SPECIFIC TO THE HAZARD — the control mutant's RED run also printed: $_o" >&2
      report "mutation-verify.sh: hint: this refusal stands; record the main mutant as UNPROVEN unless this output shows the hazard test itself failing" >&2
      exit 2
    fi
  done
  control_verified=0
  [ "$have_syntax" -eq 1 ] && control_verified=1
  control_flag=""
  [ "$control_verified" -eq 0 ] && control_flag="[UNVERIFIED CONTROL] "
  control_suffix="; ${control_flag}control went RED for its own reason without the expected text"
fi

canary_suffix=""
inconclusive=""
if [ "$copy_mode" -eq 1 ]; then
  canary_suffix="; control ran first (canary)"
  inconclusive="; INCONCLUSIVE in copy mode — confirm with a serial in-place run"
fi

if [ "$test_rc" -ne 0 ]; then
  if [ "$have_expect_fail" -eq 1 ]; then
    matched_list=""
    for _o in "${expect_fail_outputs[@]}"; do
      matched_list="$matched_list${matched_list:+, }'$_o'"
    done
    report "mutation-verify.sh: ${verdict_prefix}mutation CAUGHT (test-cmd exited $test_rc under mutation$reachability_suffix; expected failure text present in output, matched: $matched_list$knockout_suffix$control_suffix) — the RED run printed every --expect-fail-output text$canary_suffix" >&2
  else
    report "mutation-verify.sh: ${verdict_prefix}mutation CAUGHT (test-cmd exited $test_rc under mutation$reachability_suffix; failure cause was NOT checked, pass --expect-fail-output) — test went RED" >&2
  fi
  exit 0
else
  report "mutation-verify.sh: ${verdict_prefix}mutation NOT caught (test-cmd exited 0 under mutation$reachability_suffix) — false-green test$canary_suffix$inconclusive" >&2
  exit 1
fi
