#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE
export GIT_AUTHOR_NAME='Test Author' GIT_AUTHOR_EMAIL='test@example.invalid'
export GIT_COMMITTER_NAME='Test Author' GIT_COMMITTER_EMAIL='test@example.invalid'

bin_dir=$(cd "$(dirname "$0")" && pwd -P)
cli=$bin_dir/review-log-status
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/repo
mkdir -p "$repo/docs/agent-reviews" "$tmp/archive" "$tmp/outside"
git -C "$repo" init -q
log=$repo/docs/agent-reviews/review.md

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
check 2 '' "$cli" "$tmp/outside/absent.md"
grep -q 'Usage:' "$tmp/err" || fail 'outside-repo usage missing'
check 2 '' "$cli"

printf 'review\n' > "$log"
check 3 untracked "$cli" "$log"
git -C "$repo" add docs/agent-reviews/review.md
check 0 tracked "$cli" "$log"
git -C "$repo" commit -qm 'Add log'
check 0 tracked "$cli" "$log"

ignored=$repo/docs/agent-reviews/ignored.md
printf 'docs/agent-reviews/ignored.md\n' > "$repo/.gitignore"
printf 'first\n' > "$ignored"
check 4 ignored "$cli" "$ignored"
grep -qF '.gitignore:1:docs/agent-reviews/ignored.md' "$tmp/err" || fail 'ignore rule missing'
grep -q 'local-only' "$tmp/err" || fail 'local-only guidance missing'

destination=$tmp/archive/ignored.md
check 4 "$(printf 'ignored\narchived %s' "$destination")" env PEER_REVIEW_LOG_ARCHIVE="$tmp/archive" "$cli" --archive "$ignored"
cmp -s "$ignored" "$destination" || fail 'archive copy differs'

printf 'existing\n' > "$destination"
hash=$(git hash-object -- "$ignored" | cut -c 1-8)
check 4 "$(printf 'ignored\narchived %s/archive/ignored-%s.md' "$tmp" "$hash")" env PEER_REVIEW_LOG_ARCHIVE="$tmp/archive" "$cli" --archive "$ignored"
[ "$(cat "$destination")" = existing ] || fail 'collision overwrote original'
archived_path=$(sed -n '2s/^archived //p' "$tmp/out")
[ "$archived_path" != "$destination" ] || fail 'collision did not use suffix'
cmp -s "$ignored" "$archived_path" || fail 'suffixed archive copy differs'

check 4 ignored env -u PEER_REVIEW_LOG_ARCHIVE "$cli" --archive "$ignored"
grep -q 'unset or is not an existing directory' "$tmp/err" || fail 'unset archive guidance missing'

# Mutate a copy to classify only by porcelain status. An ignored log has empty
# porcelain output, so the ignored assertion above must reject this mutation.
mutant=$tmp/review-log-status-mutant
python3 - "$cli" "$mutant" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('if git -C "$repo" ls-files --error-unmatch')
end = source.index('\necho ignored\n', start)
replacement = '''if [ -n "$(git -C "$repo" status --porcelain -- "$relative_path")" ]; then
  echo untracked
  exit 3
fi
echo tracked
exit 0
'''
pathlib.Path(sys.argv[2]).write_text(source[:start] + replacement + source[end:])
PY
chmod +x "$mutant"
mutant_rc=0
"$mutant" "$ignored" >"$tmp/mutant.out" 2>"$tmp/mutant.err" || mutant_rc=$?
if [ "$mutant_rc" -eq 4 ] && [ "$(cat "$tmp/mutant.out")" = ignored ]; then
  fail 'porcelain-only mutation survived ignored-case test'
fi
echo 'mutation caught: porcelain-only classification fails ignored-case assertion'
echo 'test-review-log-status.sh PASS'
