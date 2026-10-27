#!/usr/bin/env bash
# agent-dispatch-run-tests: partial runs exit 4
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

# Each top-level invocation probes its own PATH; only internal wrappers may
# inherit the parent decision (including when a runner starts another runner).
if [ "${1:-}" != --_run-one ] || [ -z "${RUN_TESTS__PS_AVAILABLE:-}" ]; then
  RUN_TESTS__PS_AVAILABLE=0
  command -v ps >/dev/null 2>&1 && RUN_TESTS__PS_AVAILABLE=1
fi
export RUN_TESTS__PS_AVAILABLE
kill_grace=${RUN_TESTS__TEST_KILL_GRACE:-15}

# Internal, test-only entrypoint; not part of the public CLI.
if [ "${1:-}" = --_run-one ]; then
  trap ':' TERM
  suite=$2; rundir=$3; limit=$4; runner_pid=$5
  key=${suite//\//__}; name=${suite##*/}
  identity_at=-1; identity_ok=1
  stopped() {
    [ ! -e "$rundir/INTERRUPTED" ] && kill -0 "$runner_pid" 2>/dev/null || return 0
    if [ "$RUN_TESTS__PS_AVAILABLE" = 1 ] && [ "$SECONDS" -ne "$identity_at" ]; then
      identity_at=$SECONDS
      identity=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')
      if [ -n "$identity" ] && [ "$identity" != "$runner_pid" ]; then identity_ok=0; fi
    fi
    [ "$identity_ok" -eq 0 ]
  }
  signal_suite() {
    if [ "$1" != KILL ] || kill -0 -- "-$pgid" 2>/dev/null; then
      kill -"$1" -- "-$pgid" 2>/dev/null || :
    fi
    # The wrapper signals both the group and the bare child PID; guard the
    # latter with kill -0 before reaping.
    if [ "$reaped" -eq 0 ] && kill -0 "$pgid" 2>/dev/null; then
      kill -"$1" "$pgid" 2>/dev/null || :
    fi
  }
  # Name the survivors before signalling them: pid, elapsed time and command.
  report_leak() {
    if [ "$RUN_TESTS__PS_AVAILABLE" != 1 ]; then
      printf 'LEAK %s: ps not found; cannot list surviving processes\n' "$name"; return 0
    fi
    local survivors
    survivors=$(ps -A -o pid= -o pgid= -o etime= -o command= 2>/dev/null | awk -v g="$pgid" -v n="$name" '
      $2 == g { c = $0; sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", c)
        printf "LEAK %s: pid %s, elapsed %s: %s\n", n, $1, $3, c }' || :)
    if [ -n "$survivors" ]; then
      printf '%s\n' "$survivors"
    else
      printf 'LEAK %s: survivors could not be listed\n' "$name"
    fi
  }
  write_rc() {
    printf '%s\n' "$1" > "$rundir/$key.rc.tmp"
    mv "$rundir/$key.rc.tmp" "$rundir/$key.rc"
  }
  if stopped; then write_rc not-run; exit 0; fi
  printf 'RUN  %s\n' "$name"
  started=$SECONDS
  rc=0; interrupted=0; term_at=; timed_out=0; killed=0; leader_polls=0; reaped=0; leaked=0; native=0
  # child setpgid (N to N): Operation not permitted is a harmless parent/child race.
  [ "${RUN_TESTS__TEST_NOGROUP:-}" = 1 ] || set -m
  if command -v timeout >/dev/null 2>&1; then
    native=1
    timeout -k "$kill_grace" "$limit" bash "$ROOT/$suite" </dev/null > "$rundir/$key.log" 2>&1 &
  elif command -v gtimeout >/dev/null 2>&1; then
    native=1
    gtimeout -k "$kill_grace" "$limit" bash "$ROOT/$suite" </dev/null > "$rundir/$key.log" 2>&1 &
  else
    bash "$ROOT/$suite" </dev/null > "$rundir/$key.log" 2>&1 &
  fi
  pgid=$!
  set +m
  printf '%s\n' "$pgid" > "$rundir/$key.pid.tmp"
  mv "$rundir/$key.pid.tmp" "$rundir/$key.pid"
  # wait may return early because TERM is trapped. Reap until the whole
  # recorded group is gone, including children surviving the group leader.
  while kill -0 "$pgid" 2>/dev/null || kill -0 -- "-$pgid" 2>/dev/null; do
    now=$SECONDS
    if stopped; then interrupted=1; fi
    if ! kill -0 "$pgid" 2>/dev/null; then
      if [ "$reaped" -eq 0 ]; then
        wait "$pgid" || rc=$?
        reaped=1
      fi
      # Increment only after a completed sleep below: at least 50 x 0.1s.
      # 1.3s straggler fixture pins >=14 polls; 50 is load headroom, deliberately not test-pinned (a near-threshold straggler would flake under load).
      if [ "$leader_polls" -ge 50 ] && [ "$timed_out" -eq 0 ]; then leaked=1; fi
    fi
    if [ "$interrupted" -eq 1 ] || [ "$leaked" -eq 1 ] || [ "$((now - started))" -ge "$limit" ]; then
      if [ -z "$term_at" ]; then
        term_at=$now
        if [ "$interrupted" -eq 0 ] && [ "$leaked" -eq 0 ]; then timed_out=1; fi
        if [ "$leaked" -eq 1 ]; then report_leak; fi
        if (set -C; : > "$rundir/$key.termed") 2>/dev/null; then
          signal_suite TERM
        fi
      elif { [ "$leaked" -eq 1 ] && [ "$((now - term_at))" -ge 2 ]; } || [ "$((now - term_at))" -ge "$kill_grace" ]; then
        killed=1
        signal_suite KILL
      fi
    fi
    { sleep 0.1 2>/dev/null || :; } 2>/dev/null
    if [ "$reaped" -eq 1 ]; then leader_polls=$((leader_polls + 1)); fi
  done
  if [ "$reaped" -eq 0 ]; then wait "$pgid" || rc=$?; reaped=1; fi
  stopped && interrupted=1
  rm -f "$rundir/$key.pid"
  secs=$((SECONDS - started))
  printf '%s\n' "$secs" > "$rundir/$key.secs.tmp"
  mv "$rundir/$key.secs.tmp" "$rundir/$key.secs"
  why=
  if [ "$interrupted" -eq 1 ]; then rc=not-run
  elif [ "$leaked" -eq 1 ]; then why=leaked
  elif [ "$timed_out" -eq 1 ] || { [ "$native" -eq 1 ] && [ "$secs" -ge "$limit" ] && { [ "$rc" = 124 ] || [ "$rc" = 137 ]; }; }; then
    if [ "$killed" -eq 1 ] || [ "$rc" = 137 ]; then rc=137; why=killed; else rc=124; why=timeout; fi
  fi
  [ -z "$why" ] || printf '%s\n' "$why" > "$rundir/$key.why"
  if [ "$why" = leaked ]; then printf 'FAIL %s (exited %s; left processes running)\n' "$name" "$rc"; fi
  if [ "$why" = leaked ]; then printf '%s\n' "$rc" > "$rundir/$key.leader-rc"; rc=leaked; fi
  # Internal, test-only fault injection for missing and malformed results.
  if [ "${RUN_TESTS__TEST_DROP_RC:-}" = "junk:$key" ]; then write_rc junk
  elif [ "${RUN_TESTS__TEST_DROP_RC:-}" != "$key" ]; then write_rc "$rc"; fi
  exit 0
fi

usage() { printf 'usage: run-tests.sh [-h|--help] [-j N] [--timeout S] [--only SUITES | --changed [BASE]]\n'; }
usage_error() { printf 'run-tests.sh: %s\n' "$1" >&2; usage >&2; exit 2; }
jobs_label=RUN_TESTS_JOBS; timeout_label=RUN_TESTS_TIMEOUT
jobs=${RUN_TESTS_JOBS:-}; timeout=${RUN_TESTS_TIMEOUT:-420}
partial=0; only=; changed=0; changed_base=; only_set=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -j|--timeout)
      [ "$#" -ge 2 ] || usage_error "$1 requires a value"
      if [ "$1" = -j ]; then jobs=$2; jobs_label=-j; else timeout=$2; timeout_label=--timeout; fi
      shift 2 ;;
    --only)
      [ "$#" -ge 2 ] || usage_error "$1 requires a value"
      partial=1; only_set=1; only=${only:+$only,}$2
      shift 2 ;;
    --changed)
      changed=1; partial=1
      shift
      if [ "$#" -gt 0 ]; then
        case "$1" in -*) ;; *) changed_base=$1; shift ;; esac
      fi ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
[ "$changed" -eq 0 ] || [ "$only_set" -eq 0 ] || usage_error "--only and --changed are exclusive"
if [ -z "$jobs" ]; then
  jobs=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
  [ "$jobs" -le 12 ] || jobs=12
fi
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || usage_error "$jobs_label: expected a positive integer: $jobs"
[[ "$kill_grace" =~ ^[1-9][0-9]*$ ]] || usage_error "RUN_TESTS__TEST_KILL_GRACE (test-only): expected a positive integer: $kill_grace"
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || usage_error "$timeout_label: expected a positive integer: $timeout"
summarize() {
  local dir=$1 list=$2 mode=$3 suite key rc secs why
  passed=0; failed=0; total=0; finished=0; not_run=0
  while IFS= read -r -d '' suite; do
    total=$((total + 1)); key=${suite//\//__}
    rc=; secs=0
    [ ! -f "$dir/$key.rc" ] || rc=$(cat "$dir/$key.rc")
    [ ! -f "$dir/$key.secs" ] || secs=$(cat "$dir/$key.secs")
    if [ "$mode" = interrupted ] && { [ ! -f "$dir/$key.rc" ] || [ "$rc" = not-run ]; }; then
      printf 'NOT RUN %s\n' "${suite##*/}"; not_run=$((not_run + 1)); continue
    fi
    [ ! -f "$dir/$key.rc" ] || finished=$((finished + 1))
    if [ "$rc" = leaked ]; then
      failed=$((failed + 1)); printf 'FAIL %s (exited %s; left processes running)\n' "${suite##*/}" "$(cat "$dir/$key.leader-rc" 2>/dev/null || printf unknown)"; continue
    fi
    if ! [[ "$rc" =~ ^[0-9]+$ ]]; then
      printf 'FAIL %s (no result)\n' "${suite##*/}"; failed=$((failed + 1)); continue
    fi
    why=
    [ ! -f "$dir/$key.why" ] || why=$(cat "$dir/$key.why")
    case "$why:$rc" in
      :0) passed=$((passed + 1)); printf 'PASS %s (%ss)\n' "${suite##*/}" "$secs" ;;
      timeout:124) failed=$((failed + 1)); printf 'TIMEOUT %s (%ss)\n' "${suite##*/}" "$secs" ;;
      killed:137) failed=$((failed + 1)); printf 'KILLED %s (%ss)\n' "${suite##*/}" "$secs" ;;
      *) failed=$((failed + 1)); printf 'FAIL %s (exit %s, %ss)\n' "${suite##*/}" "$rc" "$secs" ;;
    esac
  done < "$list"
  printf 'Summary: %s passed, %s failed, %s total\n' "$passed" "$failed" "$total"
  if [ "$mode" = interrupted ]; then
    printf 'INTERRUPTED: %s finished, %s not run\n' "$finished" "$not_run"
  fi
  [ "$passed" -eq "$total" ] && { [ "$mode" != full ] || [ "$passed" -eq "$discovered_total" ]; }
}
on_signal() {
  local signal=$1 file pgid alive deadline code
  trap '' INT TERM HUP
  touch "$rundir/INTERRUPTED"
  shopt -s nullglob
  deadline=$((SECONDS + 10))
  while :; do
    alive=0
    for file in "$rundir"/*.pid; do
      [ -f "$file" ] && [ ! -f "${file%.pid}.rc" ] || continue
      pgid=$(cat "$file" 2>/dev/null) || continue
      if kill -0 -- "-$pgid" 2>/dev/null; then
        alive=1
        if (set -C; : > "${file%.pid}.termed") 2>/dev/null; then
          kill -TERM -- "-$pgid" 2>/dev/null || :
        fi
      fi
    done
    [ "$alive" -eq 1 ] && [ "$SECONDS" -lt "$deadline" ] || break
    { sleep 0.1 2>/dev/null || :; } 2>/dev/null
  done
  for file in "$rundir"/*.pid; do
    [ -f "$file" ] && [ ! -f "${file%.pid}.rc" ] || continue
    pgid=$(cat "$file" 2>/dev/null) || continue
    kill -0 -- "-$pgid" 2>/dev/null && kill -KILL -- "-$pgid" 2>/dev/null || :
  done
  if [ -n "${xpid:-}" ]; then
    wait "$xpid" 2>/dev/null || :
  fi
  for file in "$rundir"/*.pid; do rm -f "$file"; done
  summarize "$rundir" "$list" interrupted || :
  printf 'Total wall: %ss\n' "$(( $(date +%s) - started ))"
  case "$signal" in INT) code=130;; TERM) code=143;; HUP) code=129;; esac
  exit "$code"
}
run_suites() {
  cd "$ROOT" || return 1
  set -m
  xargs -0 -P "$jobs" -I{} bash "$SCRIPT_DIR/run-tests.sh" --_run-one {} "$rundir" "$timeout" "$$" < "$1" &
  xpid=$!
  set +m
  wait "$xpid"
}

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

suite_list=$(for suite in "${suites[@]}"; do
  printf '%s\t%s\n' "${suite##*/}" "$suite"
done | sort | while IFS=$'\t' read -r name suite; do
  printf '%s\n' "${suite#"$ROOT"/}"
done)
select_only() {
  local remaining=$1 token suite matches match last
  while :; do
    last=0
    case "$remaining" in
      *,*) token=${remaining%%,*}; remaining=${remaining#*,} ;;
      *) token=$remaining; last=1 ;;
    esac
    token=${token#"${ROOT##*/}"/}
    matches=0; match=
    while IFS= read -r suite; do
      case "$token" in
        */*) [ "$token" = "$suite" ] || continue ;;
        *) [ "$token" = "${suite##*/}" ] || continue ;;
      esac
      matches=$((matches + 1)); match=$suite
    done <<< "$suite_list"
    [ "$matches" -ne 0 ] || usage_error "no suite matches: $token"
    [ "$matches" -le 1 ] || usage_error "ambiguous suite: $token"
    printf '%s\n' "$match"
    [ "$last" -eq 0 ] || break
  done
}
selected=
if [ "$only_set" -eq 1 ]; then selected=$(select_only "$only") || exit 2; fi
if [ "$changed" -eq 1 ] && [ -n "$changed_base" ]; then
  git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || usage_error 'not a git checkout'
fi
if [ "$changed" -eq 1 ] && [ -n "$changed_base" ] &&
  ! git -C "$ROOT" rev-parse --verify --quiet "$changed_base^{commit}" >/dev/null 2>&1; then
  usage_error "unknown base: $changed_base"
fi
rundir=$(mktemp -d "${TMPDIR:-/tmp}/run-tests.XXXXXX") || exit 1
printf 'Run dir: %s\n' "$rundir"
if [ "$RUN_TESTS__PS_AVAILABLE" = 0 ]; then
  printf 'run-tests.sh: NOTICE: ps not found; runner identity check disabled (liveness only)\n'
fi
started=$(date +%s)
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  printf 'run-tests.sh: NOTICE: no timeout/gtimeout found; enforcing timeout in worker poll loop\n'
fi
list="$rundir/suites"
while IFS= read -r suite; do printf '%s\0' "$suite"; done <<< "$suite_list" > "$list"
full_changed() {
  printf 'FULL GATE: %s\n' "$1"
  partial=0
}
select_changed() {
  local gitroot prefix def base path rel suite matched runtime candidate inplugin
  gitroot=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) || {
    full_changed 'git repository unavailable'; return;
  }
  prefix=${ROOT#"$gitroot"/}
  [ "$ROOT" != "$gitroot" ] || prefix=
  base=${1:-}
  if [ -z "$base" ]; then
    def=$(git -C "$gitroot" symbolic-ref -q refs/remotes/origin/HEAD) &&
      base=$(git -C "$gitroot" merge-base HEAD "$def") || {
        full_changed 'no base available'; return;
      }
  fi
  if ! {
    git -C "$gitroot" diff --name-only -z --no-renames "$base"...HEAD &&
    git -C "$gitroot" diff --name-only -z --no-renames --cached &&
    git -C "$gitroot" diff --name-only -z --no-renames &&
    git -C "$gitroot" ls-files --others --exclude-standard -z
  } > "$rundir/changes"; then
    full_changed 'git change listing failed'; return
  fi
  if [ ! -s "$rundir/changes" ]; then
    full_changed 'no changed files'; return
  fi
  : > "$rundir/selected"
  while IFS= read -r -d '' path; do
    rel=$path; inplugin=1
    if [ -n "$prefix" ]; then
      case "$path" in
        "$prefix"/*) rel=${path#"$prefix"/} ;;
        *) inplugin=0 ;;
      esac
    fi
    case "$inplugin:$rel" in
      1:bin/test-*.sh|1:test/*.sh)
        if [ ! -f "$ROOT/$rel" ]; then full_changed 'suite deleted'; return; fi
        matched=0
        while IFS= read -r -d '' suite; do
          if [ "$suite" = "$rel" ]; then
            printf '%s\n' "$suite" >> "$rundir/selected"; matched=1
          fi
        done < "$rundir/suites"
        [ "$matched" -eq 0 ] || continue ;;
    esac
    case "$inplugin:$rel" in 1:bin/*|1:tools/*) full_changed 'code change'; return ;; esac
    runtime=0
    while IFS= read -r -d '' candidate; do
      case "${candidate##*/}" in test-*.sh) continue ;; esac
      if grep -lF -- "${path##*/}" "$candidate" >/dev/null 2>&1; then runtime=1; break; fi
    done < <(find "$SCRIPT_DIR" -type f -print0)
    if [ "$runtime" -eq 1 ]; then full_changed 'runtime input of bin/'; return; fi
    matched=0
    while IFS= read -r -d '' suite; do
      if grep -lF -e "$path" -e "$rel" -e "${path##*/}" "$ROOT/$suite" >/dev/null 2>&1; then
        printf '%s\n' "$suite" >> "$rundir/selected"; matched=1
      fi
    done < "$rundir/suites"
    if [ "$matched" -eq 0 ]; then full_changed 'changed file has no matching suite'; return; fi
  done < "$rundir/changes"
  sort -u "$rundir/selected" | while IFS= read -r suite; do
    printf '%s\0' "$suite"
  done > "$rundir/selection"
  list="$rundir/selection"
}
discovered_total=${#suites[@]}
if [ "$changed" -eq 1 ]; then
  select_changed "$changed_base"
elif [ "$partial" -eq 1 ]; then
  printf '%s\n' "$selected" | sort -u | while IFS= read -r suite; do printf '%s\0' "$suite"; done > "$rundir/selection"
  list="$rundir/selection"
fi
# All modes use basename order, including selections crossing bin/ and test/.
while IFS= read -r -d '' suite; do
  printf '%s\t%s\n' "${suite##*/}" "$suite"
done < "$list" | sort | while IFS=$'\t' read -r name suite; do
  printf '%s\0' "$suite"
done > "$rundir/ordered"
list="$rundir/ordered"
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP
run_suites "$list"
status=0
mode=full; [ "$partial" -eq 0 ] || mode=partial
summarize "$rundir" "$list" "$mode" || status=1
printf 'Slowest suites:\n'
while IFS= read -r -d '' suite; do
  key=${suite//\//__}
  [ ! -f "$rundir/$key.secs" ] || printf '%s %s\n' "$(cat "$rundir/$key.secs")" "${suite##*/}"
done < "$list" | sort -rn | head -5
while IFS= read -r -d '' suite; do
  key=${suite//\//__}
  if [ ! -f "$rundir/$key.rc" ] || [ "$(cat "$rundir/$key.rc")" != 0 ] || [ -f "$rundir/$key.why" ]; then
    if [ -f "$rundir/$key.log" ]; then
      printf 'Log tail: %s\n' "${suite##*/}"
      if [ "${CI:-}" = true ]; then cat "$rundir/$key.log"; else tail -20 "$rundir/$key.log"; fi
    fi
  fi
done < "$list"
while IFS= read -r -d '' suite; do
  key=${suite//\//__}
  [ -f "$rundir/$key.log" ] || continue
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in SKIP*) printf 'SKIP %s: %s\n' "${suite##*/}" "$line" ;; esac
  done < "$rundir/$key.log"
done < "$list"
shellcheck_state='passed'
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

if [ "$partial" -eq 0 ] && command -v shellcheck >/dev/null 2>&1; then
  if [ "${#shellcheck_targets[@]}" -gt 0 ]; then
    echo "RUN  shellcheck --severity=warning"
    if shellcheck --severity=warning "${shellcheck_targets[@]}"; then
      echo "PASS shellcheck --severity=warning (${#shellcheck_targets[@]} entrypoints)"
    else
      rc=$?
      echo "FAIL shellcheck --severity=warning (exit $rc)"
      status=1; shellcheck_state=failed
    fi
  else
    echo "run-tests.sh: NOTICE: no non-test executable entrypoints found for shellcheck"
  fi
elif [ "$partial" -eq 0 ]; then
  echo "run-tests.sh: NOTICE: shellcheck not found; skipping shellcheck --severity=warning"
  shellcheck_state="skipped (not installed)"
fi

printf 'Total wall: %ss\n' "$(( $(date +%s) - started ))"
if [ "$status" -eq 0 ] && [ "${RUN_TESTS_KEEP_LOGS:-}" != 1 ]; then rm -rf "$rundir"; fi
if [ "$partial" -eq 1 ]; then
  printf 'PARTIAL RUN: %s of %s suites — NOT the gate\n' "$total" "$discovered_total"
  [ "$status" -ne 0 ] || status=4
elif [ "$status" -eq 0 ]; then
  printf 'GATE PASS: all %s suites passed; shellcheck %s\n' "$total" "$shellcheck_state"
else
  suffix=; [ "$shellcheck_state" != failed ] || suffix='; shellcheck failed'
  printf 'GATE FAIL: %s of %s suites failed%s\n' "$failed" "$discovered_total" "$suffix"
fi
exit "$status"
