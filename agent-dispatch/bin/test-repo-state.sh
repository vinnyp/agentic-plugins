#!/usr/bin/env bash
set -euo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/repo-state-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL="$TMP/global" GIT_CONFIG_NOSYSTEM=1
printf '[user]\n name = Fixture\n email = fixture@example.invalid\n' > "$GIT_CONFIG_GLOBAL"
# shellcheck source=agent-dispatch/bin/lib/repo-state.sh
. "$BIN/lib/repo-state.sh"
rc_is() {
  local want=$1 rc=0
  shift
  "$@" || rc=$?
  [ "$rc" = "$want" ] || { echo "expected $want, got $rc: $*" >&2; exit 1; }
}
fixture() {
  R=$(mktemp -d "$TMP/repo.XXXXXX")
  git -C "$R" init -q -b main
  git -C "$R" init -q --bare "$R.git"
  git -C "$R" remote add origin "$R.git"
  git -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial --allow-empty
  git -C "$R" push -q origin main
}
snap() { repo_state_snapshot "$R" "$1"; }
check_key() {
  fixture
  snap "$TMP/before"
  git -C "$R" config "$1" "$2"
  snap "$TMP/after"
  rc_is "$3" repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
}
check_key user.name Other 2
grep -Eq '^config user.name \(local:.*<changed>' "$TMP/changes"
check_key core.hooksPath /x 2
grep -Eq '^config core.hookspath .* /x$' "$TMP/changes"
for key in core.sshCommand includeIf.gitdir:/x/.path alias.x url.http://x.insteadOf filter.x.clean; do
  check_key "$key" /x 2
done
check_key commit.gpgSign true 2
grep -q -- '-> true' "$TMP/changes"
check_key branch.main.remote origin 1
fixture
snap "$TMP/before"
git -C "$R" remote add fork 'https://host.invalid/a b'
snap "$TMP/after"
rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
fixture
git -C "$R" config --add include.path /missing-one
git -C "$R" config --add include.path /missing-two
snap "$TMP/before"
git -C "$R" config --unset-all include.path /missing-one
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
fixture
snap "$TMP/before"
git config --file "$GIT_CONFIG_GLOBAL" user.email changed@example.invalid
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '(global:' "$TMP/changes"
for key in credential.helper remote.origin.url; do
  fixture
  git -C "$R" config "$key" 'https://u:p1@h/r'
  snap "$TMP/before"
  git -C "$R" config "$key" 'https://u:p2@h/r'
  snap "$TMP/after"
  rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
  if grep -E 'p1|p2' "$TMP/before" "$TMP/after" "$TMP/changes"; then exit 1; fi
done
fixture
git -C "$R" config commit.gpgSign ''
snap "$TMP/before"
git -C "$R" config commit.gpgSign true
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q ':  -> true$' "$TMP/changes"
fixture
git -C "$R" config x.value $'a = b\tend\nnext%'
git -C "$R" config remote.origin.url 'https://h/a b'
printf '[x]\n\tflag\n' >> "$R/.git/config"
snap "$TMP/before"
snap "$TMP/after"
rc_is 0 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
[ ! -s "$TMP/changes" ]
# The contract explicitly requires checking ls permission text.
# shellcheck disable=SC2012
[ "$(ls -l "$TMP/after" | cut -c 1-10)" = '-rw-------' ]
old_umask=$(umask)
snap "$TMP/after"
[ "$(umask)" = "$old_umask" ]
repo_state_mark_unreadable "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'config: <unreadable after review>' "$TMP/changes"
for bad in '' rel/path "$TMP"; do rc_is 3 repo_state_snapshot "$bad" "$TMP/after"; done
D=$(mktemp -d "$TMP/decoy.XXXXXX")
git -C "$D" init -q
cp "$D/.git/config" "$TMP/decoy-config"
(export GIT_DIR="$D/.git" GIT_INDEX_FILE="$D/index"; snap "$TMP/after")
grep -qx "$(printf 'repo\t%s' "$R")" "$TMP/after"
cmp "$D/.git/config" "$TMP/decoy-config"
rc_is 0 "$BIN/repo-state-check" snapshot "$R" "$TMP/after"
rc_is 0 "$BIN/repo-state-check" compare "$TMP/before" "$TMP/after"
rc_is 64 "$BIN/repo-state-check" nonsense
rc_is 3 "$BIN/repo-state-check" snapshot rel/path "$TMP/after"
mkdir "$TMP/links"
ln -s "$BIN/repo-state-check" "$TMP/links/check"
rc_is 0 "$TMP/links/check" snapshot "$R" "$TMP/after"
repo_state_mark_unreadable "$TMP/after"
rc_is 2 "$TMP/links/check" compare "$TMP/before" "$TMP/after"
git config --file "$GIT_CONFIG_GLOBAL" user.email fixture@example.invalid
fixture
snap "$TMP/before"
printf '#!/bin/sh\n' > "$R/.git/hooks/pre-commit"
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: added' "$TMP/changes"
for identity in foreign configured; do
  fixture
  snap "$TMP/before"
  if [ "$identity" = foreign ]; then
    git -C "$R" -c user.name=t -c user.email=t@x.invalid commit -qm foreign --allow-empty
    expected=2
  else
    git -C "$R" commit -qm configured --allow-empty
    expected=1
  fi
  snap "$TMP/after"
  rc_is "$expected" repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
  grep -q '^ref refs/heads/main:' "$TMP/changes"
  if [ "$identity" = foreign ]; then grep -q '^commit ' "$TMP/changes"
  elif grep -q '^commit ' "$TMP/changes"; then exit 1; fi
done
fixture
git -C "$R" checkout -qb old
git -C "$R" -c user.name=t -c user.email=t@x.invalid commit -qm old --allow-empty
snap "$TMP/before"
git -C "$R" checkout -qb new old
snap "$TMP/after"
rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
if grep -q '^commit ' "$TMP/changes"; then exit 1; fi
for operation in stash notes untracked; do
  fixture
  snap "$TMP/before"
  case "$operation" in
    stash) printf x > "$R/file"; git -C "$R" add file; git -C "$R" stash -q ;;
    notes) git -C "$R" notes add -m x ;;
    untracked) printf x > "$R/new-file" ;;
  esac
  snap "$TMP/after"
  rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
  if [ "$operation" = untracked ]; then grep -q '^tree .*new-file' "$TMP/changes"
  else grep -q '^ref ' "$TMP/changes"; fi
done
fixture
wt="$TMP/linked"
git -C "$R" worktree add -q --detach "$wt" HEAD
snap "$TMP/before"
git -C "$wt" commit -qm moved --allow-empty
snap "$TMP/after"
rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q "^worktree $wt: HEAD .* -> HEAD " "$TMP/changes"
snap "$TMP/before"
rm -rf "$wt"
snap "$TMP/after"
rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx "tree $wt: unreadable" "$TMP/changes"
echo 'repo-state tests passed'
