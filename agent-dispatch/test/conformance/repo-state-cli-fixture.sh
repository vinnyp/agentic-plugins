# shellcheck shell=bash
RUN_ID="rsb$$x$RANDOM"
SUITE_PGID=$(ps -p "$$" -o pgid= | tr -d '[:space:]')
RUN_PID_FILE="$TMP/run-pids"
REAL_GIT=$(command -v git)
: > "$RUN_PID_FILE"
SHIMS="$TMP/shims"
SLOW="$TMP/slow-shims"
NOTIMER="$TMP/no-timer-shim"
mkdir "$SHIMS" "$SLOW" "$NOTIMER"
# Tagged git: argv[0] is "tagged-<id>" so a survivor is found by tag, never by name.
cat > "$SHIMS/git" <<'SHIM'
#!/usr/bin/env bash
echo $$ >> "$RUN_PID_FILE"
exec -a "tagged-$RUN_ID" "$REAL_GIT" "$@"
SHIM
cat > "$SHIMS/sleep" <<'SHIM'
#!/usr/bin/env bash
echo "$$ tagged-sleep-$RUN_ID" >> "$RUN_PID_FILE"
exec -a "tagged-sleep-$RUN_ID" /bin/sleep "$@"
SHIM
# Slow git: the matched subcommands sleep, under the tag, whatever git does with a FIFO.
cat > "$SLOW/git" <<'SHIM'
#!/usr/bin/env bash
echo $$ >> "$RUN_PID_FILE"
sub='' flag=''
for arg in "$@"; do
  case "$arg" in
    rev-parse|cat-file|rev-list) sub=$arg ;;
    --git-common-dir|--absolute-git-dir|--show-toplevel) flag=$arg ;;
  esac
done
case "$sub" in
  cat-file|rev-list) exec -a "tagged-$RUN_ID" /bin/sleep 30 ;;
  rev-parse) [ -z "$flag" ] || exec -a "tagged-$RUN_ID" /bin/sleep 30 ;;
esac
exec -a "tagged-$RUN_ID" "$REAL_GIT" "$@"
SHIM
# A timer that claims success without running anything.
printf '#!/bin/sh\nexit 0\n' > "$NOTIMER/timeout"
chmod +x "$SHIMS/git" "$SHIMS/sleep" "$SLOW/git" "$NOTIMER/timeout"
export SUITE_PGID RUN_ID RUN_PID_FILE REAL_GIT SHIMS SLOW NOTIMER BIN TMP

setup_mode() {
  : > "$RUN_PID_FILE"
  TMPDIR="$TMP/timers"; mkdir "$TMPDIR"
  export TMPDIR
}
cli() { PATH="$SHIMS:$PATH" "$BIN/repo-state-check" "$@"; }
slow_cli() { PATH="$SLOW:$SHIMS:$PATH" "$BIN/repo-state-check" "$@"; }
outdir() { mkdir "$TMP/out-$RUN_ID"; printf '%s\n' "$TMP/out-$RUN_ID"; }
# Poll for tagged processes that are still alive (zombies do not count).
survivors() {
  local deadline=$((SECONDS + ${1:-2})) pid alive state
  local groups term_groups targets pgid shell_pgid cleanup_deadline pending pass
  shell_pgid=$(ps -p "${BASHPID:-$(exec sh -c 'echo "$PPID"')}" -o pgid= | tr -d '[:space:]')
  while :; do
    alive=''
    while read -r pid _tag; do
      [ -n "$pid" ] || continue
      state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
      case "$state" in ''|Z*) continue ;; esac
      if ps -p "$pid" -o command= 2>/dev/null | grep -qF "$RUN_ID"; then alive="$alive $pid"; fi
    done < "$RUN_PID_FILE"
    [ -z "$alive" ] && return 0
    if [ "$SECONDS" -ge "$deadline" ]; then
      for pid in $alive; do ps -p "$pid" -o pid=,ppid=,pgid=,stat=,command= >&2; done
      # Recheck tags before signalling. Only a separate group created inside
      # this run can contain one of our tagged descendants.
      term_groups=''
      for pass in TERM KILL; do
        groups='' targets=''
        if [ "$pass" = KILL ]; then
          for pgid in $term_groups; do
            kill -0 -- "-$pgid" 2>/dev/null || continue
            groups="$groups $pgid"
          done
        fi
        while read -r pid _tag; do
          [ -n "$pid" ] || continue
          state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
          case "$state" in ''|Z*) continue ;; esac
          ps -p "$pid" -o command= 2>/dev/null | grep -qF "$RUN_ID" || continue
          targets="$targets $pid"
          pgid=$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]')
          if [[ "$SUITE_PGID" =~ ^[0-9]+$ ]] && [[ "$shell_pgid" =~ ^[0-9]+$ ]] &&
             [[ "$pgid" =~ ^[0-9]+$ ]] && [ "$pgid" -gt 1 ] &&
             [ "$pgid" != "$SUITE_PGID" ] && [ "$pgid" != "$shell_pgid" ]; then
            case " $groups " in *" $pgid "*) ;; *) groups="$groups $pgid" ;; esac
          fi
        done < "$RUN_PID_FILE"
        for pgid in $groups; do kill -"$pass" -- "-$pgid" 2>/dev/null || true; done
        for pid in $targets; do kill -"$pass" "$pid" 2>/dev/null || true; done
        [ "$pass" = TERM ] || break
        term_groups=$groups
        cleanup_deadline=$((SECONDS + 2))
        while [ "$SECONDS" -lt "$cleanup_deadline" ]; do
          pending=0
          for pgid in $groups; do kill -0 -- "-$pgid" 2>/dev/null && pending=1; done
          for pid in $targets; do kill -0 "$pid" 2>/dev/null && pending=1; done
          [ "$pending" = 1 ] || break
          /bin/sleep 0.1
        done
        # The KILL pass also collects children recorded during the TERM wait.
      done
      fail "tagged processes survived:$alive"
    fi
    /bin/sleep 0.2
  done
}
no_state_dir() {
  ! compgen -G "$1/.repo-state.*" >/dev/null || fail "stray .repo-state.* beside $1"
  ! compgen -G "$1/.repo-state-out.*" >/dev/null || fail 'stray output temporary file'
}
no_bound_dir() {
  ! compgen -G "$TMPDIR/repo-state-bound.*" >/dev/null || fail 'stray bound directory'
  ! compgen -G "$TMPDIR/repo-state-cli.*" >/dev/null || fail 'stray CLI directory'
  ! compgen -G "$TMPDIR/.repo-state-compare.*" >/dev/null || fail 'stray compare directory'
  ! compgen -G "$TMPDIR/repo-state-changes.*" >/dev/null || fail 'stray changes file' 
}
first_line() { local l=''; IFS= read -r l < "$1" || true; printf '%s' "${l%%$'\t'*}"; }
moved_ref_fixture() {
  local tree commit
  tree=$("$REAL_GIT" -C "$R" rev-parse 'HEAD^{tree}')
  commit=$("$REAL_GIT" -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree -p HEAD -m moved "$tree")
  "$REAL_GIT" -C "$R" update-ref refs/heads/moved "$commit"
  export MOVED=$commit
}



compare_pair() {
  local d=$1
  cli snapshot "$R" "$d/before"
  moved_ref_fixture
  cli snapshot "$R" "$d/after"
}
