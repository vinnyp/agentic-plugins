#!/usr/bin/env bash
# shellcheck disable=SC1003,SC2016,SC2329
# Mutant lines use relative paths. Single-quote variables (including
# $MUTATION_VERIFY_FILE) so commands expand them inside mutation-verify.sh.
set -uo pipefail
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  case "$_src" in /*) ;; *) _src="$_dir/$_src" ;; esac
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
# shellcheck source=lib/portable-stat.sh
. "$SCRIPT_DIR/lib/portable-stat.sh"
VCS_DIR_NAME=".git"
verdict_line() {
  sed -n '/^mutation-verify.sh: /{/^mutation-verify.sh: hint: /!p;}' "$1" | tail -1
}
owned_dir() {
  local uid
  uid=$(pstat_uid "$1") || return 1
  [ "$uid" = "$(id -u)" ]
}
# Remove only directories named for a dead owner; this loop never signals PIDs.
reap_copy_pid() {
  local owner=$1 copy
  [[ "$owner" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$owner" 2>/dev/null && return 0
  for copy in "${TMPDIR:-/tmp}"/mutation-verify-copy."$owner".*; do
    [ -d "$copy" ] && [ ! -L "$copy" ] || continue
    owned_dir "$copy" || continue
    chmod -R u+w "$copy" 2>/dev/null || :
    rm -rf "$copy" 2>/dev/null || :
  done
}
# Only line numbers cross xargs; the original text is read without re-tokenizing.
if [ "${1:-}" = --_worker ]; then
  n=$2; parent=$3; out=$4; cwd_rel=$5; sweep_pid=$6; limit=$7
  trap ':' TERM INT HUP
  stopped() { [ -f "$parent/INTERRUPTED" ] || ! kill -0 "$sweep_pid" 2>/dev/null; }
  write_result() {
    printf '%s\n' "$2" > "$out/$n.verdict.tmp"
    mv "$out/$n.verdict.tmp" "$out/$n.verdict"
    printf '%s\n' "$1" > "$out/$n.rc.tmp"
    mv "$out/$n.rc.tmp" "$out/$n.rc"
    printf 'MUTANT %s rc=%s %s\n' "$n" "$1" "$2" >&2
  }
  if stopped; then write_result not-run 'mutation-sweep.sh: not-run'; exit 0; fi
  line=$(sed -n "${n}p" "$parent/lines")
  cd "$parent/parse" || { write_result 2 'mutation-sweep.sh: worker parse cwd failed'; exit 0; }
  set -f
  set +u
  eval "set -- $line"
  set +f
  cd "$parent/S/$cwd_rel" || { write_result 2 'mutation-sweep.sh: worker cwd failed'; exit 0; }
  if stopped; then write_result not-run 'mutation-sweep.sh: not-run'; exit 0; fi
  # The actual verifier PID is recorded separately: timeout is the group leader.
  launcher='printf "%s\n" "$$" > "$1"; shift; exec bash "$@"'
  started=$SECONDS; interrupted=0; reaped=0; term_at=; timed_out=0; leaked=0; rc=0; leader_polls=0
  set -m
  if command -v timeout >/dev/null 2>&1; then
    RUN_TESTS_JOBS=1 timeout -k 20 "$limit" bash -c "$launcher" sweep-verifier "$parent/$n.copy-pid" "$SCRIPT_DIR/mutation-verify.sh" --copy-root "$parent/S" "$@" </dev/null > "$out/$n.out" 2>&1 &
  elif command -v gtimeout >/dev/null 2>&1; then
    RUN_TESTS_JOBS=1 gtimeout -k 20 "$limit" bash -c "$launcher" sweep-verifier "$parent/$n.copy-pid" "$SCRIPT_DIR/mutation-verify.sh" --copy-root "$parent/S" "$@" </dev/null > "$out/$n.out" 2>&1 &
  else
    RUN_TESTS_JOBS=1 bash -c "$launcher" sweep-verifier "$parent/$n.copy-pid" "$SCRIPT_DIR/mutation-verify.sh" --copy-root "$parent/S" "$@" </dev/null > "$out/$n.out" 2>&1 &
  fi
  pgid=$!
  set +m
  printf '%s\n' "$pgid" > "$out/$n.pid.tmp"
  mv "$out/$n.pid.tmp" "$out/$n.pid"
  printf '%s\n' "$pgid" > "$parent/$n.owner"
  # Bash 3.2 reaps background children during sleep 0.1.
  while kill -0 "$pgid" 2>/dev/null || kill -0 -- "-$pgid" 2>/dev/null; do
    now=$SECONDS
    # During a signal the live parent owns termination; the worker takes over
    # only if that parent disappears (including SIGKILL).
    kill -0 "$sweep_pid" 2>/dev/null || interrupted=1
    if ! kill -0 "$pgid" 2>/dev/null && [ "$reaped" = 0 ]; then
      wait "$pgid" || rc=$?
      reaped=1
    fi
    if [ "$reaped" = 1 ] && kill -0 -- "-$pgid" 2>/dev/null && [ ! -f "$parent/INTERRUPTED" ]; then
      leader_polls=$((leader_polls+1))
      [ "$leader_polls" -lt 50 ] || leaked=1
    fi
    # A live signalled controller owns its full 20-second grace, even if a
    # timeout leader exits before descendants finish their inner cleanup.
    if [ -f "$parent/INTERRUPTED" ] && kill -0 "$sweep_pid" 2>/dev/null; then
      :
    elif [ "$interrupted" = 1 ] || [ "$leaked" = 1 ] || [ "$((now-started))" -ge "$limit" ]; then
      if [ -z "$term_at" ]; then
        term_at=$now
        if [ "$interrupted" = 0 ] && [ "$leaked" = 0 ]; then timed_out=1; fi
        kill -TERM -- "-$pgid" 2>/dev/null || :
      elif { [ "$leaked" = 1 ] && [ "$((now-term_at))" -ge 2 ]; } || [ "$((now-term_at))" -ge 20 ]; then
        kill -KILL -- "-$pgid" 2>/dev/null || :
      fi
    fi
    { sleep 0.1 2>/dev/null || :; } 2>/dev/null
  done
  if [ "$reaped" = 0 ]; then wait "$pgid" || rc=$?; fi
  stopped && interrupted=1
  # Copies and captures may remain when their verifier was killed.
  copy_pid=$(cat "$parent/$n.copy-pid" 2>/dev/null || :)
  reap_copy_pid "$copy_pid"
  reap_copy_pid "$pgid"
  rm -f "$out/$n.pid"
  verdict=$(verdict_line "$out/$n.out")
  tree=$(cat "$parent/tree")
  if [ "$interrupted" = 1 ]; then rc=not-run; verdict="mutation-sweep.sh: not-run tree=$tree"
  elif [ "$timed_out" = 1 ] || [ "$rc" = 124 ]; then
    case "$rc" in 124|137) ;; *) rc=124;; esac
    verdict="mutation-sweep.sh: TIMEOUT after ${limit}s tree=$tree"
  elif [ "$leaked" = 1 ]; then
    verdict=${verdict% tree=*}
    rc=4; verdict="${verdict:-mutation-sweep.sh: mutant exited}; left processes running tree=$tree"
  elif [ "$rc" = 137 ]; then
    verdict="mutation-sweep.sh: killed (rc 137) tree=$tree"
  fi
  write_result "$rc" "$verdict"
  if [ "${MUTATION_VERIFY__TEST_DROP:-}" = "$n" ]; then
    rm -f "$out/$n.rc" "$out/$n.verdict" "$out/$n.out"
  fi
  exit 0
fi
error() { echo "mutation-sweep.sh: $*" >&2; exit 2; }
usage() {
  cat <<'HELP'
usage: mutation-sweep.sh --copy-root <dir> --mutants <file> [-j N] [--timeout S] [--out <dir>]
       mutation-sweep.sh [-h|--help]
Lines are trusted shell input: quote command values and single-quote variables
that expand in the copy. --file must be relative; --copy-root is supplied by
the sweep. Each line requires --control-sed or --control-cmd. Executable command
and process substitutions are refused as a guard, not a sandbox. Commands must
not name the real root literally.
Exit 0: every mutant measured without errors (exit 1/3 are unconfirmed).
Exit 1: missing results. Exit 4: errors (refusals, canary, TIMEOUT, other errors).
Exit 2: usage. Exit 130/143/129: INT/TERM/HUP.
MUTATION_VERIFY_SWEEP_JOBS: concurrency, default min(cores, 8); -j overrides.
MUTATION_VERIFY_SWEEP_TIMEOUT: seconds per mutant, default 600; --timeout overrides.
Both values must be positive integers. RUN_TESTS_JOBS=1 is exported to mutants.
HELP
}
root=; mutants=; out=; jobs=${MUTATION_VERIFY_SWEEP_JOBS-__default}
limit=${MUTATION_VERIFY_SWEEP_TIMEOUT-600}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --copy-root|--mutants|--out|-j|--timeout)
      [ "$#" -ge 2 ] || error "missing value for $1"
      case "$1" in --copy-root) root=$2;; --mutants) mutants=$2;; --out) out=$2;; -j) jobs=$2;; --timeout) limit=$2;; esac
      shift 2 ;;
    -h|--help) usage; exit 0;;
    *) error "usage: mutation-sweep.sh --copy-root <dir> --mutants <file> [-j N] [--timeout S] [--out <dir>]" ;;
  esac
done
[ -n "$root" ] && [ -n "$mutants" ] || error '--copy-root and --mutants are required'
if [ "$jobs" = __default ]; then
  jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
  [[ "$jobs" =~ ^[1-9][0-9]*$ ]] || jobs=1
  [ "$jobs" -le 8 ] || jobs=8
fi
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || error 'jobs must be a positive integer'
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || error 'timeout must be a positive integer'
# A killed sweep cannot run EXIT cleanup. Reap stale named directories only
# when their numeric owner is dead, never signalling an old process group.
shopt -s nullglob
for stale in "${TMPDIR:-/tmp}"/mutation-sweep.[0-9]*.* "${TMPDIR:-/tmp}"/mutation-verify-copy.[0-9]*.*; do
  [ -d "$stale" ] && [ ! -L "$stale" ] || continue
  owner=${stale##*/}; owner=${owner#mutation-sweep.}; owner=${owner#mutation-verify-copy.}; owner=${owner%%.*}
  [[ "$owner" =~ ^[0-9]+$ ]] || continue
  kill -0 "$owner" 2>/dev/null && continue
  owned_dir "$stale" || continue
  chmod -R u+w "$stale" 2>/dev/null || :
  rm -rf "$stale" 2>/dev/null || :
done
root_given=$root
root=$(cd -P "$root" && pwd -P) || error 'invalid --copy-root'
cwd=$(pwd -P); cwd_rel=
case "$cwd" in "$root") ;; "$root"/*) cwd_rel=${cwd#"$root"/};; *) error 'caller cwd is outside --copy-root';; esac
[ -f "$mutants" ] || error 'cannot read --mutants'
parent=$(mktemp -d "${TMPDIR:-/tmp}/mutation-sweep.$$.XXXXXX") || error 'copy failed: mktemp'
[ -n "$parent" ] || error 'copy failed: empty temporary directory'
parent=$(cd -P "$parent" && pwd -P) || error 'cannot resolve temporary directory'
cleanup() { chmod -R u+w "$parent" 2>/dev/null; rm -rf "$parent"; }
trap cleanup EXIT
case "$parent" in "$root"|"$root"/*) error 'TMPDIR is inside --copy-root';; esac
# Refuse executable substitutions before eval. Quotes are tracked without eval.
substitution() {
  local text=$1 quote='' ch next i=0 escaped=0
  while [ "$i" -lt "${#text}" ]; do
    ch=${text:$i:1}; next=${text:$((i+1)):1}; i=$((i+1))
    if [ "$escaped" = 1 ]; then escaped=0; continue; fi
    if [ "$quote" = "'" ]; then [ "$ch" != "'" ] || quote=; continue; fi
    if [ -z "$quote" ]; then
      case "$ch" in ';'|'&'|'|'|'<'|'>'|$'\n') return 0;; esac
    fi
    [ "$ch$next" != "\$'" ] || return 0
    case "$ch" in
      '\') escaped=1;;
      "'") [ -n "$quote" ] || quote="'";;
      '"') if [ "$quote" = '"' ]; then quote=; else quote='"'; fi;;
      '`') return 0;;
      '$'|'<'|'>') [ "$next" != '(' ] || return 0;;
    esac
  done
  return 1
}
real_reference() {
  local value=$1 r tail
  for r in "$root_given" "$root"; do
    case "$r" in /*) ;; *) continue;; esac
    while [[ "$value" == *"$r"* ]]; do
      tail=${value#*"$r"}
      case "$tail" in ''|[!A-Za-z0-9._-]*) return 0;; esac
      value=$tail
    done
    value=$1
  done
  return 1
}
mkdir "$parent/parse" || error 'cannot create parse directory'
: > "$parent/lines"
: > "$parent/numbers"
n=0; total=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n+1))
  printf '%s\n' "$line" >> "$parent/lines"
  case "$line" in *[![:space:]]*) ;; *) continue;; esac
  trimmed=${line#"${line%%[![:space:]]*}"}
  case "$trimmed" in \#*) continue;; esac
  substitution "$line" && error "line $n: substitution refused"
  real_reference "$line" && error "line $n: references the real root"
  (
    cd "$parent/parse" || exit 10
    set -f
    set +u
    eval "set -- $line" 2>/dev/null || exit 10
    control=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --file) case "${2:-}" in /*) exit 11;; esac;;
        --copy-root) exit 12;;
        --control-sed|--control-cmd) [ "$#" -ge 2 ] || exit 10; control=1;;
      esac
      [ "$#" -ge 2 ] || exit 10
      shift 2
    done
    [ "$control" = 1 ] || exit 14
  )
  rc=$?
  case "$rc" in 0) ;; 11) error "line $n: absolute --file";; 12) error "line $n: --copy-root is supplied by sweep";; 14) error "line $n: requires --control-sed or --control-cmd";; *) error "line $n: parse failure";; esac
  printf '%s\n' "$n" >> "$parent/numbers"
  total=$((total+1))
done < "$mutants"
mkdir "$parent/S" || error 'copy failed'
shopt -s nullglob
for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
  [ "${entry##*/}" != "$VCS_DIR_NAME" ] || continue
  dest="$parent/S/${entry##*/}"
  if ! cp -c -pR "$entry" "$dest" 2>/dev/null; then
    rm -rf "$dest"
    cp -pR "$entry" "$dest" || error 'copy failed'
  fi
done
tree=$( (cd "$parent/S" && find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r f; do if [ -L "$f" ]; then printf 'L %s %s\n' "$f" "$(readlink "$f")"; else mode="$(pstat_mode "$f")"; printf 'F %s %s %s\n' "$f" "$mode" "$(cksum < "$f")"; fi; done) | cksum | cut -d' ' -f1)
printf '%s\n' "$tree" > "$parent/tree"
if [ -z "$out" ]; then out=$(mktemp -d "${TMPDIR:-/tmp}/mutation-sweep-results.XXXXXX") || error 'cannot create output'; fi
mkdir -p "$out" || error 'cannot create output'
out=$(cd -P "$out" && pwd -P) || error 'cannot resolve output directory'
while IFS= read -r n; do
  for suffix in out verdict rc pid out.tmp verdict.tmp rc.tmp pid.tmp; do
    [ ! -e "$out/$n.$suffix" ] && [ ! -L "$out/$n.$suffix" ] || error "output already exists: $n.$suffix"
  done
done < "$parent/numbers"
printf 'Sweep dir: %s\n' "$out"
summarize() {
  local n rc text
  c=0; u1=0; u3=0; e=0; m=0
  while IFS= read -r n; do
    if [ ! -f "$out/$n.rc" ] || [ ! -f "$out/$n.verdict" ]; then m=$((m+1)); continue; fi
    rc=$(cat "$out/$n.rc"); text=$(cat "$out/$n.verdict")
    printf 'MUTANT %s rc=%s %s\n' "$n" "$rc" "$text"
    case "$rc" in 0) c=$((c+1));; 1) u1=$((u1+1));; 3) u3=$((u3+1));; not-run) m=$((m+1));; *) e=$((e+1));; esac
  done < "$parent/numbers"
  printf 'SWEEP: %s caught, %s unconfirmed-survived, %s unconfirmed-unrelated, %s errors, %s missing of %s tree=%s\n' "$c" "$u1" "$u3" "$e" "$m" "$total" "$tree"
}
on_signal() {
  local signal=$1 record pgid alive deadline code copy_pid n
  trap '' INT TERM HUP
  : > "$parent/INTERRUPTED"
  # Longer than the inner run-tests.sh's 15-second grace.
  deadline=$((SECONDS+20))
  while :; do
    alive=0
    for record in "$parent"/*.owner; do
      n=${record##*/}; n=${n%.owner}
      [ ! -f "$out/$n.rc" ] || continue
      pgid=$(cat "$record") || continue
      if kill -0 -- "-$pgid" 2>/dev/null; then
        alive=1
        if [ ! -f "$record.termed" ]; then
          : > "$record.termed"
          kill -TERM -- "-$pgid" 2>/dev/null || :
        fi
      fi
    done
    if [ "$alive" = 0 ] && { [ -z "$xpid" ] || ! kill -0 "$xpid" 2>/dev/null; }; then break; fi
    [ "$SECONDS" -lt "$deadline" ] || break
    { sleep 0.1 2>/dev/null || :; } 2>/dev/null
  done
  for record in "$parent"/*.owner; do
    n=${record##*/}; n=${n%.owner}
    [ ! -f "$out/$n.rc" ] || continue
    pgid=$(cat "$record") || continue
    kill -0 -- "-$pgid" 2>/dev/null && kill -KILL -- "-$pgid" 2>/dev/null || :
  done
  if [ -n "$xpid" ]; then wait "$xpid" 2>/dev/null || :; fi
  # Separate, path-only cleanup also covers finished records without risking a
  # stale pgid being signalled after an unrelated process reused it.
  for record in "$parent"/*.owner; do
    pgid=$(cat "$record") || continue
    reap_copy_pid "$pgid"
  done
  for record in "$parent"/*.copy-pid; do
    copy_pid=$(cat "$record") || continue
    reap_copy_pid "$copy_pid"
  done
  while IFS= read -r n; do rm -f "$out/$n.pid"; done < "$parent/numbers"
  summarize
  case "$signal" in INT) code=130;; TERM) code=143;; HUP) code=129;; esac
  exit "$code"
}
xpid=
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP
set -m
xargs -P "$jobs" -I{} bash "$SCRIPT_DIR/mutation-sweep.sh" --_worker {} "$parent" "$out" "$cwd_rel" "$$" "$limit" < "$parent/numbers" &
xpid=$!
set +m
wait "$xpid" || :
summarize
[ "$m" -eq 0 ] || exit 1
[ "$e" -eq 0 ] || exit 4
exit 0
