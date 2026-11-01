# shellcheck shell=bash
# Public-command fixtures; no implementation functions are loaded.
set -euo pipefail
BIN=$IMPL_BIN
TMP=$SCN_TMP
export GIT_CONFIG_GLOBAL="$TMP/global" GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
printf '[user]\n name = Fixture\n email = fixture@example.invalid\n' > "$GIT_CONFIG_GLOBAL"
fail() { echo "FAIL: $*" >&2; exit 1; }
rc_is() {
  local want=$1 rc=0
  shift
  "$@" || rc=$?
  [ "$rc" = "$want" ] || fail "expected $want, got $rc: $*"
}
fixture_number=0
fixture() {
  fixture_number=$((fixture_number + 1))
  R="$TMP/${1:-repo}.$fixture_number"
  mkdir "$R"
  git -C "$R" init -q -b main
  git -C "$R" init -q --bare "$R.git"
  git -C "$R" remote add origin "$R.git"
  git -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial --allow-empty
  git -C "$R" push -q origin main
}
snap() { "$BIN/repo-state-check" snapshot "$R" "$1"; }
compare() { "$BIN/repo-state-check" compare "$1" "$2" > "$3"; }
check_key() {
  fixture
  snap "$TMP/before"
  git -C "$R" config "$1" "$2"
  snap "$TMP/after"
  rc_is "$3" compare "$TMP/before" "$TMP/after" "$TMP/changes"
}
digest() { shasum -a 256 | cut -d ' ' -f 1; }
