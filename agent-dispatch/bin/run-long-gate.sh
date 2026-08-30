#!/usr/bin/env bash
# run-long-gate.sh — run a command detached, monitor status, or wait
set -euo pipefail

mode=""
cmd=""
log=""
workdir=""
label=""
timeout_secs=1800
poll_secs=20
allow_concurrent=0

show_usage() {
  echo "Usage:" >&2
  echo "  $0 --cmd <shell-command> [--log <path>] [--workdir <dir>] [--label <name>] [--allow-concurrent]" >&2
  echo "  $0 --status --log <path>" >&2
  echo "  $0 --wait   --log <path> [--timeout-secs N] [--poll-secs N]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cmd)
      mode="launch"
      cmd="$2"
      shift 2
      ;;
    --status)
      mode="status"
      shift
      ;;
    --wait)
      mode="wait"
      shift
      ;;
    --log)
      log="$2"
      shift 2
      ;;
    --workdir)
      workdir="$2"
      shift 2
      ;;
    --label)
      label="$2"
      shift 2
      ;;
    --timeout-secs)
      timeout_secs="$2"
      shift 2
      ;;
    --poll-secs)
      poll_secs="$2"
      shift 2
      ;;
    --allow-concurrent)
      allow_concurrent=1
      shift
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      show_usage
      ;;
  esac
done

if [ -z "$mode" ]; then
  echo "Error: Must specify one of --cmd, --status, or --wait" >&2
  show_usage
fi

if [ "$mode" = "launch" ]; then
  if [ -z "$cmd" ]; then
    echo "Error: --cmd is required for launching" >&2
    show_usage
  fi
  if [ -z "$workdir" ]; then
    workdir="$PWD"
  fi
  if [ -z "$label" ]; then
    label="$(basename "$workdir" | tr -cs 'A-Za-z0-9_-' '-')"
  fi
  if [ -z "$log" ]; then
    # No --log: create a private, unpredictable log under $TMPDIR (not a fixed, predictable
    # /tmp/<label>-gate.log that any local user could pre-create, symlink, or append to, and
    # that grew forever across runs). mktemp creates it 0600; chmod is belt-and-braces.
    log="$(mktemp "${TMPDIR:-/tmp}/${label}-gate.XXXXXX")" || {
      echo "Error: could not create a gate log under ${TMPDIR:-/tmp}" >&2
      exit 2
    }
    chmod 600 "$log" 2>/dev/null || true
  else
    # A caller-supplied --log is appended to. Refuse a symlink: appending through one writes
    # to whatever it points at, which is how a predictable log path turns into an arbitrary
    # file write. A regular file (or a path that does not exist yet) is fine.
    if [ -L "$log" ]; then
      echo "Error: --log path is a symlink, refusing to append through it: $log" >&2
      exit 2
    fi
    mkdir -p "$(dirname "$log")"
  fi

  # --- concurrency guard (orchestrator-drives-long-gates rule 6 / amendment 10) ---
  # Rule 6 -- "never run two instances of the same test suite concurrently" -- was prose
  # only, and was violated twice: phantom failures land in whichever run loses the race
  # for a shared port/singleton lock, and cost a diagnosis cycle each time. Enforce it at
  # the launcher instead of relying on the orchestrator remembering it.
  #
  # Scoped to the RESOLVED workdir, not to the command text: a gate running in another
  # repo must never block this one, so an unrelated `make test` elsewhere is not a
  # conflict. This is why the guard is a per-workdir lockfile and not `pgrep -f make`.
  lock=""
  if [ "$allow_concurrent" -eq 0 ]; then
    workdir_real="$(cd "$workdir" 2>/dev/null && pwd -P)" || workdir_real="$workdir"
    lock_key="$(printf '%s' "$workdir_real" | cksum | awk '{print $1 "-" $2}')"
    lock="${TMPDIR:-/tmp}/run-long-gate-${lock_key}.lock"

    if [ -e "$lock" ]; then
      held_pid="$(sed -n 's/^PID=//p' "$lock" 2>/dev/null | head -n 1)"
      held_log="$(sed -n 's/^LOG_PATH=//p' "$lock" 2>/dev/null | head -n 1)"
      if [ -n "$held_pid" ] && kill -0 "$held_pid" 2>/dev/null; then
        echo "Error: a gate is already running for $workdir_real" >&2
        echo "  conflicting PID=$held_pid LOG_PATH=${held_log:-unknown} LOCK=$lock" >&2
        echo "  Serialize full-suite runs (orchestrator-drives-long-gates rule 6)." >&2
        echo "  Wait for it (--wait --log ${held_log:-<log>}), or pass --allow-concurrent to override." >&2
        exit 4
      fi
      # A killed gate leaves its lock behind; a dead holder is a stale lock, not a conflict.
      rm -f "$lock"
    fi

    # Claim atomically (noclobber), so two launchers racing here cannot both win.
    # Seed with THIS shell's pid so the window before the child pid is written is never
    # read as a stale lock by a concurrent launcher.
    if ( set -C; printf 'PID=%s\nLOG_PATH=%s\nWORKDIR=%s\n' "$$" "$log" "$workdir_real" > "$lock" ) 2>/dev/null; then
      :
    else
      echo "Error: could not acquire gate lock $lock for $workdir_real (concurrent launch?)" >&2
      exit 4
    fi
  fi

  # Launch detached in a new session via Python subprocess.Popen (portable setsid)
  # Redirect stdin from /dev/null, write combined stdout/stderr to log.
  # Output LOG_PATH and PID immediately.
  if ! pid=$(python3 -c '
import shlex, subprocess, sys
cmd = sys.argv[1]
log_path = sys.argv[2]
workdir = sys.argv[3]
lock = sys.argv[4]
# GATE_EXIT is echoed BEFORE the lock is released so the exit code the log carries is
# always the gate command s own, never rm s.
tail = "; echo GATE_EXIT=$?"
if lock:
    tail += "; rm -f " + shlex.quote(lock)
log_file = open(log_path, "a", buffering=1)
p = subprocess.Popen(
    f"({cmd}){tail}",
    shell=True,
    start_new_session=True,
    stdout=log_file,
    stderr=subprocess.STDOUT,
    stdin=subprocess.DEVNULL,
    cwd=workdir
)
print(p.pid)
' "$cmd" "$log" "$workdir" "$lock" < /dev/null); then
    [ -n "$lock" ] && rm -f "$lock"
    echo "Error: failed to launch gate for $workdir" >&2
    exit 2
  fi

  # Hand the lock over to the gate process, which removes it when it finishes.
  if [ -n "$lock" ]; then
    printf 'PID=%s\nLOG_PATH=%s\nWORKDIR=%s\n' "$pid" "$log" "$workdir_real" > "$lock"
  fi

  echo "LOG_PATH=$log"
  echo "PID=$pid"
  exit 0

elif [ "$mode" = "status" ]; then
  if [ -z "$log" ]; then
    echo "Error: --log is required for status check" >&2
    exit 2
  fi
  if [ ! -f "$log" ]; then
    exit 2
  fi
  # Scan log for GATE_EXIT=<n>
  exit_line=$(grep -E '^GATE_EXIT=[0-9]+' "$log" 2>/dev/null | tail -n 1 || true)
  if [ -n "$exit_line" ]; then
    echo "$exit_line"
    exit 0
  else
    exit 3
  fi

elif [ "$mode" = "wait" ]; then
  if [ -z "$log" ]; then
    echo "Error: --log is required for wait" >&2
    exit 2
  fi

  elapsed=0
  while true; do
    exit_line=$(grep -E '^GATE_EXIT=[0-9]+' "$log" 2>/dev/null | tail -n 1 || true)
    if [ -n "$exit_line" ]; then
      exit_code="${exit_line#GATE_EXIT=}"
      exit "$exit_code"
    fi

    if [ "$elapsed" -ge "$timeout_secs" ]; then
      echo "Timeout waiting for gate. Log: $log" >&2
      exit 124
    fi

    sleep "$poll_secs"
    elapsed=$((elapsed + poll_secs))
  done
fi
