#!/usr/bin/env bash
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_NAMESPACE CDPATH
export GIT_AUTHOR_NAME='Test Author' GIT_AUTHOR_EMAIL='test@example.invalid'
export GIT_COMMITTER_NAME='Test Author' GIT_COMMITTER_EMAIL='test@example.invalid'

bin_dir=$(cd "$(dirname -- "$0")" && pwd -P)
cli=$bin_dir/review-log-status
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo
mkdir -p "$repo/docs/agent-reviews" "$tmp/archive" "$tmp/outside"
git -C "$repo" init -q
printf 'docs/agent-reviews/\n' > "$repo/.gitignore"
git -C "$repo" add .gitignore
git -C "$repo" commit -qm 'Add ignore rule'
log=$repo/plain.md

fail() { echo "FAIL: $*" >&2; exit 1; }
check() {
  local expected_rc=$1 expected_out=$2
  shift 2
  local rc=0
  (cd "$tmp/outside" && "$@") >"$tmp/out" 2>"$tmp/err" || rc=$?
  [ "$rc" -eq "$expected_rc" ] || fail "expected exit $expected_rc, got $rc: $(cat "$tmp/err")"
  [ "$(cat "$tmp/out")" = "$expected_out" ] || fail "expected stdout '$expected_out', got '$(cat "$tmp/out")'"
}

check 5 missing "$cli" "$log"
check 5 missing "$cli" "$repo/not-here/review.md"
check 2 '' "$cli" "$tmp/outside/absent.md"
grep -q 'Usage:' "$tmp/err" || fail 'outside-repo usage missing'
check 2 '' "$cli"
grep -q 'Usage:' "$tmp/err" || fail 'no-args usage missing'

unborn=$tmp/unborn
mkdir -p "$unborn"
git -C "$unborn" init -q
printf 'first\n' > "$unborn/review.md"
check 3 untracked "$cli" "$unborn/review.md"
[ ! -s "$tmp/err" ] || fail 'unborn untracked check wrote stderr'
git -C "$unborn" add review.md
check 6 staged "$cli" "$unborn/review.md"
[ ! -s "$tmp/err" ] || fail 'unborn staged check wrote stderr'

printf 'review\n' > "$log"
check 3 untracked "$cli" "$log"
git -C "$repo" add plain.md
check 6 staged "$cli" "$log"
git -C "$repo" commit -qm 'Add plain log'
check 0 committed "$cli" "$log"
printf 'changed\n' >> "$log"
check 6 staged "$cli" "$log"
git -C "$repo" add plain.md
check 6 staged "$cli" "$log"
git -C "$repo" show HEAD:plain.md > "$log"
check 6 staged "$cli" "$log"
git -C "$repo" commit -qm 'Update plain log'
check 6 staged "$cli" "$log"
git -C "$repo" show HEAD:plain.md > "$log"
check 0 committed "$cli" "$log"
check 0 committed env PEER_REVIEW_LOG_ARCHIVE="$tmp/archive" "$cli" --archive "$log"
[ "$(find "$tmp/archive" -type f | wc -l | tr -d ' ')" -eq 0 ] || fail 'committed log was archived'

ignored=$repo/docs/agent-reviews/ignored.md
printf 'first\n' > "$ignored"
check 4 ignored "$cli" "$ignored"
grep -qF '.gitignore:1:docs/agent-reviews/' "$tmp/err" || fail 'ignore rule missing'
check 4 ignored env -u PEER_REVIEW_LOG_ARCHIVE "$cli" --archive "$ignored"
grep -q 'unset or is not an existing directory' "$tmp/err" || fail 'unset archive guidance missing'

forced=$repo/docs/agent-reviews/forced.md
printf 'forced\n' > "$forced"
git -C "$repo" add -f docs/agent-reviews/forced.md
check 6 staged "$cli" "$forced"
git -C "$repo" commit -qm 'Force add log'
check 0 committed "$cli" "$forced"

(cd "$repo" && "$cli" docs/agent-reviews/forced.md) >"$tmp/out" 2>"$tmp/err" || fail 'relative path failed'
[ "$(cat "$tmp/out")" = committed ] || fail 'relative path state wrong'

printf 'tracked\n' > "$repo/a1.md"
git -C "$repo" add a1.md
git -C "$repo" commit -qm 'Add glob decoy'
printf 'literal\n' > "$repo/a?.md"
check 3 untracked "$cli" "$repo/a?.md"
printf 'dash\n' > "$repo/-dash.md"
git -C "$repo" add -- ./-dash.md
git -C "$repo" commit -qm 'Add dash path'
check 0 committed "$cli" "$repo/-dash.md"
(cd "$repo" && "$cli" -dash.md) >"$tmp/out" 2>"$tmp/err" || fail 'dash-leading relative path failed'
[ "$(cat "$tmp/out")" = committed ] || fail 'dash-leading relative path state wrong'

foreign=$tmp/foreign
mkdir -p "$foreign"
git -C "$foreign" init -q
GIT_DIR="$foreign/.git" GIT_INDEX_FILE="$foreign/.git/index" "$cli" "$log" >"$tmp/out" 2>"$tmp/err" || fail 'foreign Git environment failed'
[ "$(cat "$tmp/out")" = committed ] || fail 'foreign Git environment changed state'

hash=$(git hash-object -- "$ignored" | cut -c 1-8)
destination=$tmp/archive/ignored-$hash.md
check 4 "$(printf 'ignored\narchived %s' "$destination")" env PEER_REVIEW_LOG_ARCHIVE="$tmp/archive" "$cli" --archive "$ignored"
cmp -s "$ignored" "$destination" || fail 'archive copy differs'
check 4 "$(printf 'ignored\narchived %s' "$destination")" env PEER_REVIEW_LOG_ARCHIVE="$tmp/archive" "$cli" --archive "$ignored"
[ "$(find "$tmp/archive" -type f | wc -l | tr -d ' ')" -eq 1 ] || fail 'idempotent archive made another copy'

printf 'existing\n' > "$destination"
collision=$tmp/archive/ignored-$hash-2.md
check 4 "$(printf 'ignored\narchived %s' "$collision")" env PEER_REVIEW_LOG_ARCHIVE="$tmp/archive" "$cli" --archive "$ignored"
[ "$(cat "$destination")" = existing ] || fail 'collision overwrote original'
cmp -s "$ignored" "$collision" || fail 'collision copy differs'
check 4 "$(printf 'ignored\narchived %s' "$collision")" env PEER_REVIEW_LOG_ARCHIVE="$tmp/archive" "$cli" --archive "$ignored"
[ "$(find "$tmp/archive" -type f | wc -l | tr -d ' ')" -eq 2 ] || fail 'collision reuse made another copy'

regular=$tmp/regular
printf 'untouched\n' > "$regular"
check 4 ignored env PEER_REVIEW_LOG_ARCHIVE="$regular" "$cli" --archive "$ignored"
grep -q 'not an existing directory' "$tmp/err" || fail 'regular-file archive notice missing'
[ "$(cat "$regular")" = untouched ] || fail 'regular-file archive changed'
check 4 ignored env PEER_REVIEW_LOG_ARCHIVE="$repo/docs" "$cli" --archive "$ignored"
grep -q 'inside the log repository' "$tmp/err" || fail 'in-repo archive refusal missing'
git -C "$repo" worktree add -q -b archive-checkout "$tmp/linked-archive"
check 4 ignored env PEER_REVIEW_LOG_ARCHIVE="$tmp/linked-archive" "$cli" --archive "$ignored"
grep -q 'another checkout of the log repository' "$tmp/err" || fail 'linked-worktree archive refusal missing'
[ ! -e "$tmp/linked-archive/ignored-$hash.md" ] || fail 'linked-worktree archive made a copy'

hidden=$repo/docs/agent-reviews/.hidden
printf 'hidden\n' > "$hidden"
hidden_hash=$(git hash-object -- "$hidden" | cut -c 1-8)
check 4 "$(printf 'ignored\narchived %s/archive/.hidden-%s' "$tmp" "$hidden_hash")" env PEER_REVIEW_LOG_ARCHIVE="$tmp/archive" "$cli" --archive "$hidden"
cmp -s "$hidden" "$tmp/archive/.hidden-$hidden_hash" || fail 'dotfile archive copy differs'

other=$repo/docs/agent-reviews/report.txt
printf 'other\n' > "$other"
other_hash=$(git hash-object -- "$other" | cut -c 1-8)
check 4 "$(printf 'ignored\narchived %s/archive/report-%s.txt' "$tmp" "$other_hash")" env PEER_REVIEW_LOG_ARCHIVE="$tmp/archive" "$cli" --archive "$other"

case_dir=$tmp/case-check
mkdir -p "$case_dir"
printf 'probe\n' > "$case_dir/review.md"
if [ -e "$case_dir/Review.md" ]; then
  echo 'SKIP: case-insensitive filesystem cannot test GIT_ICASE_PATHSPECS isolation'
else
  printf 'review\n' > "$repo/review.md"
  git -C "$repo" add review.md
  git -C "$repo" commit -qm 'Add case decoy'
  printf 'untracked\n' > "$repo/Review.md"
  check 3 untracked env GIT_ICASE_PATHSPECS=1 "$cli" "$repo/Review.md"
fi

# Force check-ignore itself to fail after a successful ls-files miss.
mkdir -p "$tmp/stub"
real_git=$(command -v git)
cat > "$tmp/stub/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = check-ignore ]; then
    echo 'fatal: simulated check-ignore failure' >&2
    exit 128
  fi
done
exec "$real_git" "\$@"
STUB
chmod +x "$tmp/stub/git"
printf 'free\n' > "$repo/free.md"
check 2 '' env PATH="$tmp/stub:$PATH" "$cli" "$repo/free.md"
grep -q 'fatal: simulated check-ignore failure' "$tmp/err" || fail 'check-ignore error was hidden'

echo 'test-review-log-status.sh PASS'
