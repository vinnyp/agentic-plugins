#!/usr/bin/env bash
set -euo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
TMP=$(set -eu; scratch=$(mktemp -d "${TMPDIR:-/tmp}/repo-state-memory.XXXXXX"); [ -n "$scratch" ]; printf '%s\n' "$scratch")
[ -n "$TMP" ] || exit 1
RUN_ID="repo-state-memory-$$-$RANDOM"
cleanup() {
  local pid=''
  if [ -r "$TMP/sleeper" ]; then
    pid=$(cat "$TMP/sleeper")
    if ps -p "$pid" -o command= 2>/dev/null | grep -qF "$RUN_ID"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
. "$BIN/lib/repo-state.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
rc_is() { local want=$1 rc=0; shift; "$@" || rc=$?; [ "$rc" = "$want" ] || fail "expected $want, got $rc: $*"; }
payload() { REPO_STATE_BOUND_OUT=$'hello\n@@done 7 99\n\n'; return 7; }
[ "$(CUSTOM_BOUND_LIMIT=08 repo_state_snapshot_limit fixture 60 CUSTOM_BOUND_LIMIT)" = 8 ] || fail 'named limit ignored'
flags=$-
rc_is 7 repo_state_run_bounded 5 payload
[ "$REPO_STATE_BOUND_OUT" = $'hello\n@@done 7 99\n\n' ] || fail 'framed payload lost bytes'
[ "$flags" = "$-" ] || fail 'bound changed shell flags'
exec 7>"$TMP/seven" 8>"$TMP/eight"
rc_is 7 repo_state_run_bounded 5 payload
printf seven >&7; printf eight >&8
repo_state_cancel_bound
printf more >&7
exec 7>&- 8>&-
[ "$(cat "$TMP/seven")" = sevenmore ] && [ "$(cat "$TMP/eight")" = eight ] || fail 'inherited fds lost'
(set -C; flags=$-; rc_is 7 repo_state_run_bounded 5 payload; [ "$flags" = "$-" ]) || fail 'noclobber changed'
closed_fds() {
  if { printf injected >&7; } 2>/dev/null; then return 9; fi
  if { printf injected >&8; } 2>/dev/null; then return 9; fi
  REPO_STATE_BOUND_OUT=closed
}
rc_is 0 repo_state_run_bounded 5 closed_fds
[ "$REPO_STATE_BOUND_OUT" = closed ] || fail 'operation inherited channel'
# Change only the emitter; the operation cannot access the channel descriptors.
REAL_BASH=$(command -v bash); export REAL_BASH
mkdir "$TMP/bin"
cat > "$TMP/bin/bash" <<'SHIM'
#!/bin/bash
script=$(cat "$1") || exit 125
shift
case "$CHANNEL_MUTATION" in
  bytes) script=${script//'${#REPO_STATE_BOUND_OUT}'/999} ;;
  rc) script=${script//'"$rc" "${#REPO_STATE_BOUND_OUT}"'/'"0" "${#REPO_STATE_BOUND_OUT}"'} ;;
  suffix) script=${script//'@@done %s %s'/'@@done %s %s trailing'} ;;
esac
exec "$REAL_BASH" <(printf '%s\n' "$script") "$@"
SHIM
chmod +x "$TMP/bin/bash"
for mutation in bytes rc suffix; do
  rc=0
  CHANNEL_MUTATION=$mutation PATH="$TMP/bin:$PATH" repo_state_run_bounded 5 payload || rc=$?
  [ "$rc" = 125 ] || fail "channel $mutation mismatch accepted"
  [ -z "$REPO_STATE_BOUND_OUT" ] || fail 'invalid channel retained payload'
done
max_payload() { REPO_STATE_BOUND_OUT=$(LC_ALL=C head -c 67108864 /dev/zero | tr '\0' x); }
rc_is 0 repo_state_run_bounded 20 max_payload
[ "${#REPO_STATE_BOUND_OUT}" = 67108864 ] || fail 'at-cap payload lost bytes'
REPO_STATE_BOUND_OUT=''
large_payload() { REPO_STATE_BOUND_OUT=$(LC_ALL=C head -c 67108865 /dev/zero | tr '\0' x); }
rc_is 125 repo_state_run_bounded 20 large_payload 2>"$TMP/cap.err"
grep -q 'large_payload output exceeded 64 MiB; not evaluated' "$TMP/cap.err" || fail 'cap diagnostic missing'
leaks_sleeper() { bash -c 'exec -a "$1" sleep 60' _ "$2" & printf '%s\n' "$!" > "$1"; REPO_STATE_BOUND_OUT=verdict; return 2; }
rc_is 2 repo_state_run_bounded 5 leaks_sleeper "$TMP/sleeper" "$RUN_ID"
[ "$REPO_STATE_BOUND_OUT" = verdict ] || fail 'cleanup changed verdict'
pid=$(cat "$TMP/sleeper")
# A reaped leader may briefly leave a zombie; it cannot run or hold the channel.
state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
case "$state" in ''|*Z*) ;; *) fail 'leaked sleeper survived group cleanup' ;; esac
printf 'config\tlocal\tfile:fixture\tcore.hookspath\told\n' > "$TMP/old"
printf 'config\tlocal\tfile:fixture\tcore.hookspath\tnew\n' > "$TMP/new"
: > "$TMP/empty"
rc_is 0 repo_state_compare "$TMP/old" "$TMP/old" "$TMP/changes"
[ ! -s "$TMP/changes" ] || fail 'self compare produced changes'
rc_is 2 repo_state_compare "$TMP/empty" "$TMP/new" "$TMP/changes"
grep -q '(absent) ->' "$TMP/changes" || fail 'addition pairing'
rc_is 2 repo_state_compare "$TMP/old" "$TMP/empty" "$TMP/changes"
grep -q -- '-> (absent)' "$TMP/changes" || fail 'removal pairing'
rc_is 2 repo_state_compare "$TMP/old" "$TMP/new" "$TMP/changes"
# Fail if compare tries to create even a short-lived intermediate directory.
mktemp() { fail 'compare created temporary storage'; }
rc_is 2 repo_state_compare "$TMP/old" "$TMP/new" "$TMP/changes"
unset -f mktemp
for broken_stage in config records; do
  (
    eval "$(declare -f _repo_state_pairs | sed '1s/_repo_state_pairs/_repo_state_pairs_real/')"
    _repo_state_pairs() { if [ "$1" = "$broken_stage" ]; then return 3; fi; _repo_state_pairs_real "$@"; }
    result=0
    repo_state_compare "$TMP/old" "$TMP/new" "$TMP/changes" || result=$?
    [ "$result" = 3 ] || fail "pairing $broken_stage failure hidden"
  )
done
# Replace all formerly named intermediates whenever a consumer runs. A directory
# creation would make the consumer read the planted /dev/null links.
mkdir "$TMP/plant-bin" "$TMP/storage"
REAL_AWK=$(command -v awk); export REAL_AWK
cat > "$TMP/plant-bin/awk" <<'PLANT'
#!/bin/bash
for dir in "$REPO_STATE_TMP"/.repo-state-compare.* "$REPO_STATE_TMP"/.repo-state.*; do
  [ -d "$dir" ] || continue
  for name in before after old new diff records exclude commits dirty-old dirty-new dirty escaped config config.refs config.status unsafe; do
    rm -f "$dir/$name"
    ln -s /dev/null "$dir/$name"
  done
done
exec "$REAL_AWK" "$@"
PLANT
chmod +x "$TMP/plant-bin/awk"
REPO_STATE_TMP="$TMP/storage" PATH="$TMP/plant-bin:$PATH" rc_is 2 repo_state_compare "$TMP/old" "$TMP/new" "$TMP/changes"
[ -n "$(cat "$TMP/changes")" ] || fail 'planting concealed drift'
[ -z "$(ls -A "$TMP/storage")" ] || fail 'plantable intermediate name created'
(
  _repo_state_git() { return 128; }
  _repo_state_configs() { cat >/dev/null; return 0; }
  rc_is 0 _repo_state_worktree_configs fixture
  _repo_state_configs() { cat >/dev/null; return 3; }
  rc_is 3 _repo_state_worktree_configs fixture
)
mkfifo "$TMP/before"
(cat "$TMP/old" > "$TMP/before") & writer=$!
rc_is 2 "$BIN/repo-state-check" compare "$TMP/before" "$TMP/new" > "$TMP/fifo-result"
wait "$writer"
grep -q '^config core.hookspath' "$TMP/fifo-result" || fail 'FIFO input not read once'
export GIT_CONFIG_GLOBAL="$TMP/global" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n name = Fixture\n email = fixture@example.invalid\n' > "$GIT_CONFIG_GLOBAL"
mkdir "$TMP/repo"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial --allow-empty
git -C "$TMP/repo" config example.multiline $'first\nsecond'
printf dirty > "$TMP/repo/path with spaces"
printf dirty > "$TMP/repo/"$'path\nwith newline'
repo_state_snapshot "$TMP/repo" "$TMP/a"
(
  # Read by the snapshot through dynamic scope.
  # shellcheck disable=SC2034
  REPO_STATE_SALT=fixture
  mktemp() { fail 'snapshot created temporary storage'; }
  repo_state_snapshot_memory "$TMP/repo"
  [ -n "$REPO_STATE_BOUND_OUT" ] || fail 'in-memory snapshot empty'
)
repo_state_snapshot "$TMP/repo" "$TMP/b"
rc_is 0 repo_state_compare "$TMP/a" "$TMP/b" "$TMP/changes"
grep -q 'first%0Asecond' "$TMP/a" || fail 'multiline config lost'
grep -q 'path%0Awith newline' "$TMP/a" || fail 'NUL dirty path lost'
git -C "$TMP/repo" config core.hooksPath changed
repo_state_snapshot "$TMP/repo" "$TMP/b"
rc_is 2 repo_state_compare "$TMP/a" "$TMP/b" "$TMP/changes"
echo 'repo-state memory tests passed'
