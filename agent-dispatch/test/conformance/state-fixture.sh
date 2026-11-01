# shellcheck shell=bash
# Shared black-box fixture. All writes are inside the harness-owned scratch tree.
set -eu
: "${id:?}"
mkdir -p "$SCN_REPO" "$SCN_TMP/bin"
git -C "$SCN_REPO" init -q
git -C "$SCN_REPO" symbolic-ref HEAD refs/heads/main
printf 'base\n' > "$SCN_REPO/tracked.txt"
git -C "$SCN_REPO" add .
git -C "$SCN_REPO" -c user.name=Conformance -c user.email=conformance@example.invalid commit -qm fixture
# Disclose deterministic fixture tools rather than host-specific versions.
cat > "$SCN_TMP/bin/python3" <<'PY'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo 'Python fixture'; else exec "$STATE_PYTHON" "$@"; fi
PY
cat > "$SCN_TMP/bin/ruff" <<'RUFF'
#!/usr/bin/env bash
echo 'ruff fixture'
RUFF
cat > "$SCN_TMP/bin/date" <<'DATE'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ]; then cat "$SCN_TMP/clock"; else exec /bin/date "$@"; fi
DATE
STATE_PYTHON=$(command -v python3)
export STATE_PYTHON
printf '1700000000\n' > "$SCN_TMP/clock"
chmod +x "$SCN_TMP/bin/"*
export PATH="$SCN_TMP/bin:$PATH"
cd "$SCN_REPO"
# Emit every observed status, retaining the command's own output unchanged.
observe() {
  local rc=0
  "$@" || rc=$?
  scenario_rc=$rc
  printf 'observed_rc=%s\n' "$rc"
}
snapshot() { "$IMPL_BIN/repo-state-check" snapshot "$SCN_REPO" "$1"; }
case "$id" in
  state-compare-*)
    snapshot "$SCN_TMP/before"
    case "$id" in
      *config) printf '\n[fixture]\n changed = true\n' >> .git/config ;;
      *hook) printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit ;;
      *ref) git -C "$SCN_REPO" update-ref refs/replace/1111111111111111111111111111111111111111 HEAD ;;
      *harmless) touch tracked.txt ;;
      *alternates) printf '%s\n' "$SCN_REPO/.git/objects" > .git/objects/info/alternates ;;
      *grafts) git -C "$SCN_REPO" rev-parse HEAD > .git/info/grafts ;;
      *shallow) git -C "$SCN_REPO" rev-parse HEAD > .git/shallow ;;
      *exclude) printf 'ignored-fixture\n' >> .git/info/exclude ;;
      *filter)
        printf '*.txt filter=fixture\n' > .gitattributes
        printf '\n[filter "fixture"]\n clean = "echo filter-ran >> %s; cat"\n' "$SCN_TMP/filter-ran" >> .git/config
        ;;
      *socket)
        python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' ".git/fsmonitor--daemon.ipc"
        ;;
    esac
    snapshot "$SCN_TMP/after"
    case "$id" in
      *deleted) rm "$SCN_TMP/before" ;;
      *truncated) : > "$SCN_TMP/before" ;;
    esac
    observe "$IMPL_BIN/repo-state-check" compare "$SCN_TMP/before" "$SCN_TMP/after"
    if [ "$id" = state-compare-filter ]; then
      if [ -s "$SCN_TMP/filter-ran" ]; then echo 'filter executed before comparison'; else echo 'filter not executed'; fi
    fi
    ;;
  state-pin-invalid)
    DISPATCH_REVIEW_PIN_TTL_SECS=invalid observe "$IMPL_BIN/review-pin.sh" status "$SCN_REPO"
    ;;
  state-pin-*)
    "$IMPL_BIN/review-pin.sh" pin "$SCN_REPO" --label fixture
    observe "$IMPL_BIN/review-pin.sh" status "$SCN_REPO"
    case "$id" in
      *block)
        printf 'Edit tracked.txt.\n' > "$SCN_TMP/brief"
        observe "$IMPL_BIN/coding-dispatch.sh" codex "$SCN_REPO" "$SCN_TMP/brief" true
        [ "$(cat tracked.txt)" = base ]
        [ ! -s "$SCN_TMP/argv" ]
        echo 'pinned edit unchanged; no runtime invoked'
        ;;
      *stale)
        printf '1700000002\n' > "$SCN_TMP/clock"
        export DISPATCH_REVIEW_PIN_TTL_SECS=1
        observe "$IMPL_BIN/review-pin.sh" status "$SCN_REPO"
        [ ! -e .git/review-pinned ]
        echo 'stale marker removed'
        "$IMPL_BIN/review-pin.sh" pin "$SCN_REPO" --label replacement
        ;;
      *duplicate) observe "$IMPL_BIN/review-pin.sh" pin "$SCN_REPO" ;;
    esac
    "$IMPL_BIN/review-pin.sh" release "$SCN_REPO"
    observe "$IMPL_BIN/review-pin.sh" status "$SCN_REPO"
    ;;
  state-clone-*)
    dest="$SCN_TMP/dispatch-review-wt.fixture"
    case "$id" in
      *filter) printf '\n[filter "fixture"]\n clean = cat\n' >> .git/config ;;
      *unsafe) dest="$SCN_TMP/unsafe" ;;
    esac
    source_repo=$SCN_REPO
    case "$id" in
      *nonempty) mkdir -m 700 "$dest"; printf 'retain\n' > "$dest/foreign" ;;
      *mode) mkdir -m 755 "$dest" ;;
      *source) source_repo="$SCN_TMP/not-a-worktree"; mkdir "$source_repo" ;;
    esac
    observe "$IMPL_BIN/review-clone.sh" "$source_repo" "$dest"
    if [ "$id" = state-clone-isolation ]; then
      printf 'clone edit\n' > "$dest/tracked.txt"
      printf '\n[fixture]\n clone = true\n' >> "$dest/.git/config"
      git -C "$dest" update-ref refs/heads/private HEAD
      [ "$(cat tracked.txt)" = base ]
      ! grep -q 'clone = true' .git/config
      ! git -C "$SCN_REPO" show-ref --verify --quiet refs/heads/private
      [ ! -f "$dest/.git/objects/info/alternates" ]
      echo 'source content config refs isolated; no alternates'
      observe "$IMPL_BIN/review-clone.sh" --remove "$SCN_TMP" "$SCN_REPO"
      [ -d "$SCN_REPO" ]
      observe "$IMPL_BIN/review-clone.sh" --remove "$SCN_TMP" "$dest"
      [ ! -e "$dest" ]
      echo 'clone removed; source retained'
    fi
    ;;
  state-gate-*)
    case "$id" in
      *pass) observe "$IMPL_BIN/gate-run.sh" --expect-root "$SCN_REPO" --no-venv -- 'printf "gate passed\n"' ;;
      *fail) observe "$IMPL_BIN/gate-run.sh" -- 'exit 7' ;;
      *moved) observe "$IMPL_BIN/gate-run.sh" --expect-root "$SCN_REPO" -- "cd '$SCN_TMP'" ;;
      *venv)
        mkdir -p .venv/bin
        printf '#!/bin/sh\necho "venv fixture"\n' > .venv/bin/python3
        chmod +x .venv/bin/python3
        observe "$IMPL_BIN/gate-run.sh" -- 'python3 --version'
        DISPATCH_NO_VENV=1 observe "$IMPL_BIN/gate-run.sh" -- 'python3 --version'
        ;;
    esac
    ;;
  state-long-*)
    log="$SCN_TMP/gate.log"
    case "$id" in
      *symlink)
        : > "$SCN_TMP/target"
        ln -s "$SCN_TMP/target" "$log"
        observe "$IMPL_BIN/run-long-gate.sh" --cmd true --log "$log" --workdir "$SCN_REPO"
        [ ! -s "$SCN_TMP/target" ]
        ;;
      *pending)
        : > "$log"
        observe "$IMPL_BIN/run-long-gate.sh" --status --log "$log"
        observe "$IMPL_BIN/run-long-gate.sh" --wait --log "$log" --timeout-secs 0 --poll-secs 1
        printf 'GATE_EXIT=0\n' > "$log"
        observe "$IMPL_BIN/run-long-gate.sh" --status --log "$log"
        ;;
      *missing) observe "$IMPL_BIN/run-long-gate.sh" --status --log "$log" ;;
      *)
        # Only short finite commands. Always wait synchronously for completion.
        code=0
        [ "$id" != state-long-fail ] || code=7
        "$IMPL_BIN/run-long-gate.sh" --cmd "printf 'short gate\n'; exit $code" --log "$log" --workdir "$SCN_REPO" --label fixture > "$SCN_TMP/launch"
        # PID is already a supported harness normalisation context.
        sed 's/^PID=/pid=/' "$SCN_TMP/launch"
        observe "$IMPL_BIN/run-long-gate.sh" --wait --log "$log" --timeout-secs 5 --poll-secs 1
        observe "$IMPL_BIN/run-long-gate.sh" --status --log "$log"
        cat "$log"
        ;;
    esac
    ;;
esac

# Preserve the final observed implementation status for the harness rc contract.
exit "${scenario_rc:-0}"
