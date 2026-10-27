#!/usr/bin/env bash
set -euo pipefail
BIN=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/repo-state-test.XXXXXX")
[ -n "$TMP" ] || exit 1
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
  R=$(mktemp -d "$TMP/${1:-repo}.XXXXXX")
  [ -n "$R" ] || exit 1
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
# CLI failures distinguish critical after-state loss from invalid input.
fixture
snap "$TMP/before"
printf '[core\n bad' >> "$R/.git/config"
rc_is 3 "$BIN/repo-state-check" snapshot "$R" "$TMP/corrupt-after"
grep -qx unreadable "$TMP/corrupt-after"
rc_is 2 "$BIN/repo-state-check" compare "$TMP/before" "$TMP/corrupt-after" > "$TMP/output"
grep -qx 'config: <unreadable after review>' "$TMP/output"
rc_is 2 "$BIN/repo-state-check" compare "$TMP/before" "$TMP/nonexistent" > "$TMP/output"
grep -qx 'config: <unreadable after review>' "$TMP/output"
rc_is 3 "$BIN/repo-state-check" compare "$TMP/nonexistent" "$TMP/before" > "$TMP/output"
grep -qx 'state: <unreadable before snapshot>' "$TMP/output"
rc_is 64 "$BIN/repo-state-check" > "$TMP/output" 2> "$TMP/error"
grep -q '^usage: repo-state-check ' "$TMP/error"
[ ! -s "$TMP/output" ]
for help in --help -h; do
  rc_is 0 "$BIN/repo-state-check" "$help" > "$TMP/output" 2> "$TMP/error"
  grep -q '^usage: repo-state-check ' "$TMP/output"
  [ ! -s "$TMP/error" ]
done
for args in snapshot compare; do
  rc_is 64 "$BIN/repo-state-check" "$args" > "$TMP/output" 2> "$TMP/error"
  grep -q '^usage: repo-state-check ' "$TMP/error"
done
(TMPDIR="$TMP/nonexistent"; export TMPDIR
 rc_is 3 "$BIN/repo-state-check" compare "$TMP/before" "$TMP/before"
 mktemp() { return 1; }
 rc_is 3 repo_state_compare "$TMP/before" "$TMP/before" "$TMP/changes")
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
check_key branch.main.remote . 1
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
git -C "$R" config --file "$GIT_CONFIG_GLOBAL" user.email changed@example.invalid
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '(global:' "$TMP/changes"
for key in credential.helper remote.origin.url; do
  # These paths deterministically reproduce the old short-marker false positive.
  fixture repo-p1p2
  git -C "$R" config "$key" 'https://u:PWONE_SECRET@h/r'
  snap "$TMP/before"
  git -C "$R" config "$key" 'https://u:PWTWO_SECRET@h/r'
  snap "$TMP/after"
  rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
  grep -q "^config $key " "$TMP/changes"
  grep -Eq 'p1|p2' "$TMP/before" "$TMP/after" "$TMP/changes" || { echo "fixture premise lost: snapshot no longer records the repo-p1p2 path" >&2; exit 1; }
  if grep -E 'PWONE_SECRET|PWTWO_SECRET' "$TMP/before" "$TMP/after" "$TMP/changes"; then
    echo "secret leaked into snapshot/changes for $key" >&2
    exit 1
  fi
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
# Decoy configuration must not replace the requested repository's configuration.
git -C "$D" config marker.decoy 1
git -C "$R" config marker.real 1
(export GIT_DIR="$D/.git"; snap "$TMP/after")
grep -q 'marker.real' "$TMP/after"
if grep -q 'marker.decoy' "$TMP/after"; then exit 1; fi
git -C "$R" config --unset marker.real
(export GIT_CONFIG_PARAMETERS="'marker.injected'='1'"; snap "$TMP/after")
if grep -q 'marker.injected' "$TMP/after"; then exit 1; fi
mkdir "$TMP/hash-shims" "$TMP/snapshot-tmp" "$TMP/snapshot-out"
for hash in shasum sha256sum; do
  printf '#!/bin/sh\nexit 127\n' > "$TMP/hash-shims/$hash"
  chmod +x "$TMP/hash-shims/$hash"
done
(PATH="$TMP/hash-shims:$PATH"; rc_is 3 "$BIN/repo-state-check" snapshot "$R" "$TMP/hash-failed")
if [ -f "$TMP/hash-failed" ] && grep -Eq 'sha256:$' "$TMP/hash-failed"; then exit 1; fi
(TMPDIR="$TMP/snapshot-tmp"; export TMPDIR; snap "$TMP/snapshot-out/state")
for dir in "$TMP/snapshot-tmp" "$TMP/snapshot-out"; do
  for leftover in "$dir"/repo-state-config.* "$dir"/.repo-state.*; do
    [ ! -e "$leftover" ] || { echo "leaked snapshot intermediate: $leftover" >&2; exit 1; }
  done
done
rc_is 0 "$BIN/repo-state-check" snapshot "$R" "$TMP/after"
rc_is 0 "$BIN/repo-state-check" compare "$TMP/before" "$TMP/after"
rc_is 64 "$BIN/repo-state-check" nonsense
rc_is 3 "$BIN/repo-state-check" snapshot rel/path "$TMP/after"
mkdir "$TMP/links"
ln -s "$BIN/repo-state-check" "$TMP/links/check"
rc_is 0 "$TMP/links/check" snapshot "$R" "$TMP/after"
repo_state_mark_unreadable "$TMP/after"
rc_is 2 "$TMP/links/check" compare "$TMP/before" "$TMP/after"
git -C "$R" config --file "$GIT_CONFIG_GLOBAL" user.email fixture@example.invalid
fixture
snap "$TMP/before"
printf '#!/bin/sh\n' > "$R/.git/hooks/pre-commit"
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: added' "$TMP/changes"
# Hook payloads include regular content, symlink targets and resolved content.
snap "$TMP/before"
printf '# changed\n' >> "$R/.git/hooks/pre-commit"
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: changed' "$TMP/changes"
snap "$TMP/before"
rm "$R/.git/hooks/pre-commit"
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: removed' "$TMP/changes"
fixture
printf '#!/bin/sh\n' > "$TMP/hook-one"
printf '#!/bin/sh\n' > "$TMP/hook-two"
snap "$TMP/before"
ln -s "$TMP/hook-one" "$R/.git/hooks/pre-commit"
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: added' "$TMP/changes"
snap "$TMP/before"
ln -sf "$TMP/hook-two" "$R/.git/hooks/pre-commit"
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: changed' "$TMP/changes"
snap "$TMP/before"
printf '# changed\n' >> "$TMP/hook-two"
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: changed' "$TMP/changes"
snap "$TMP/before"
rm "$TMP/hook-two"
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: changed' "$TMP/changes"
fixture
mkdir "$R/.githooks"
printf '#!/bin/sh\n' > "$R/.githooks/pre-commit"
git -C "$R" config core.hooksPath .githooks
snap "$TMP/before"
printf '# changed\n' >> "$R/.githooks/pre-commit"
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks core.hooksPath/pre-commit: changed' "$TMP/changes"
snap "$TMP/before"
common=$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)
printf '#!/bin/sh\n' > "$common/hooks/pre-push"
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-push: added' "$TMP/changes"
fixture
# Ensure the sample assertion is exercised even with an empty system template.
printf '# sample\n' > "$R/.git/hooks/fixture.sample"
snap "$TMP/before"
mkdir "$R/.githooks"
git -C "$R" config core.hooksPath .githooks
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^config core.hookspath ' "$TMP/changes"
if grep -Eq '^hooks .*\.sample: removed$' "$TMP/changes"; then exit 1; fi
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
# Classification must follow execution and destination effects, not editor text.
check_key alias.vscode '!true' 2
grep -q '^config alias.vscode ' "$TMP/changes"
check_key url.https://example.invalid/vscode/.insteadof https://x 2
grep -q '^config url.https://example.invalid/vscode/.insteadof ' "$TMP/changes"
check_key branch.main.vscode-merge-base origin/main 1
grep -q '^config branch.main.vscode-merge-base ' "$TMP/changes"
check_key branch.main.pushremote origin 2
grep -q '^config branch.main.pushremote ' "$TMP/changes"
for addition in none uploadpack branch; do
  fixture
  snap "$TMP/before"
  git -C "$R" remote add evil https://example.invalid/repo
  expected=1
  case "$addition" in
    uploadpack) git -C "$R" config remote.evil.uploadpack '!true'; expected=2 ;;
    branch) git -C "$R" config branch.main.remote evil; expected=2 ;;
  esac
  snap "$TMP/after"
  rc_is "$expected" repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
  grep -q '^config remote.evil.url ' "$TMP/changes"
  case "$addition" in
    uploadpack) grep -q '^config remote.evil.uploadpack ' "$TMP/changes" ;;
    branch) grep -q '^config branch.main.remote ' "$TMP/changes" ;;
  esac
done
for key in credential.helper http.extraheader foo.apitoken secrets.apikey token.x foo.password password.x proxy.x http.proxy remote.origin.proxy; do
  fixture
  case "$key" in
    credential.helper) value='store --file /x-PWONE_SECRET' ;;
    http.extraheader) value='AUTHORIZATION: bearer PWONE_SECRET' ;;
    http.proxy|remote.origin.proxy) value=u:PWONE_SECRET@proxy.example:8080 ;;
    *) value=PWONE_SECRET ;;
  esac
  git -C "$R" config "$key" "$value"
  snap "$TMP/before"
  git -C "$R" config "$key" "${value/PWONE_SECRET/PWTWO_SECRET}"
  snap "$TMP/after"
  rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
  grep -q "^config $key " "$TMP/changes"
  if grep -E 'PWONE_SECRET|PWTWO_SECRET' "$TMP/before" "$TMP/after" "$TMP/changes"; then
    echo "secret leaked into snapshot/changes for $key" >&2
    exit 1
  fi
done
# Credentialed URL keys must stay private and remain distinct snapshot entries.
fixture
key_one='url.https://u:PWONE_SECRET@h/.insteadOf'
key_two='url.https://u:PWTWO_SECRET@h/.insteadOf'
git -C "$R" config "$key_one" https://x
snap "$TMP/before"
git -C "$R" config --unset "$key_one"
git -C "$R" config "$key_two" https://x
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^config url.https://h/.insteadof ' "$TMP/changes"
if grep -E 'PWONE_SECRET|PWTWO_SECRET' "$TMP/before" "$TMP/after" "$TMP/changes"; then
  echo "secret leaked into snapshot/changes for credentialed key" >&2
  exit 1
fi
git -C "$R" config "$key_one" https://x
snap "$TMP/after"
# These digest assertions are independent: the replacement comparison above
# catches collapsing distinct credentialed keys into one entry.
for secret in PWONE_SECRET PWTWO_SECRET; do
  digest=$(printf 'u:%s' "$secret" | _repo_state_sha256)
  grep -Fq "$(printf '\turl.https://%s@h/.insteadof\t' "${digest:0:12}")" "$TMP/after"
done

if grep -E 'PWONE_SECRET|PWTWO_SECRET' "$TMP/after"; then
  echo "secret leaked into snapshot for distinct credentialed keys" >&2
  exit 1
fi
fixture
clone="$TMP/upstream-clone"
git -C "$R" clone -q -b main "$R.git" "$clone"
git -C "$clone" -c user.name=gh -c user.email=gh@x.invalid commit -qm upstream --allow-empty
git -C "$clone" push -q origin main
snap "$TMP/before"
git -C "$R" pull -q --ff-only origin main
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^ref refs/heads/main:' "$TMP/changes"
grep -q '^commit ' "$TMP/changes"
fixture
snap "$TMP/before"
git -C "$R" -c user.email=foreign@example.invalid commit -qm email-only --allow-empty
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^commit .* committer <changed>$' "$TMP/changes"
fixture
git -C "$R" config extensions.worktreeConfig true
wt="$TMP/config-linked"
git -C "$R" worktree add -q -b linked "$wt"
snap "$TMP/before"
git -C "$wt" config --worktree alias.x y
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^config alias.x ' "$TMP/changes"
for value in $'a\nb' $'a\tb'; do
  fixture
  git -C "$R" config x.value "$value"
  snap "$TMP/before"
  git -C "$R" config x.value "${value/b/c}"
  snap "$TMP/after"
  rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
  grep -q '^config x.value ' "$TMP/changes"
done
fixture
git -C "$R" branch alternate
snap "$TMP/before"
git -C "$R" switch -q alternate
snap "$TMP/after"
rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^worktree .*refs/heads/main -> HEAD .*refs/heads/alternate$' "$TMP/changes"
wt="$TMP/removed-linked"
snap "$TMP/before"
git -C "$R" worktree add -q --detach "$wt"
snap "$TMP/after"
rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx "tree $wt: worktree added" "$TMP/changes"
snap "$TMP/before"
git -C "$R" worktree remove "$wt"
snap "$TMP/after"
rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx "tree $wt: worktree removed" "$TMP/changes"
if grep -q '0 new dirty paths' "$TMP/changes"; then exit 1; fi
printf first > "$R/dirty"
snap "$TMP/before"
git -C "$R" add dirty
snap "$TMP/after"
rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx "tree $R: status changed (no new dirty paths)" "$TMP/changes"
# Configuration-only comparisons do not inspect objects; branch changes batch once.
fixture
snap "$TMP/before"
git -C "$R" config branch.main.description fixture
snap "$TMP/after"
(
  git() {
    case " $* " in *' cat-file '*) printf '%s\n' "$*" >> "$TMP/cat-file-calls" ;; esac
    command git "$@"
  }
  : > "$TMP/cat-file-calls"
  rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
  [ ! -s "$TMP/cat-file-calls" ]
  git -C "$R" commit -qm batch --allow-empty
  snap "$TMP/after"
  rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
  [ "$(wc -l < "$TMP/cat-file-calls" | tr -d ' ')" = 1 ]
  grep -q -- "--batch-check=%(objectname) %(objecttype)" "$TMP/cat-file-calls"
)
# A failing shasum must retry the same bytes with sha256sum.
(
  expected=$(printf fixture | _repo_state_sha256)
  shasum() { cat >/dev/null; return 1; }
  [ "$(printf fixture | _repo_state_sha256)" = "$expected" ]
)
# Fail closed on an explicit unreadable baseline.
repo_state_mark_unreadable "$TMP/bad-before"
rc_is 3 repo_state_compare "$TMP/bad-before" "$TMP/after" "$TMP/changes"
grep -qx 'state: <unreadable before snapshot>' "$TMP/changes"
check_key branch.main.remote /tmp/x.git 2
fixture
git -C "$R" config branch.main.remote origin
snap "$TMP/before"
git -C "$R" config --unset branch.main.remote
snap "$TMP/after"
rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
fixture
snap "$TMP/before"
git -C "$R" remote add evil https://example.invalid/evil
git -C "$R" config branch.bypass-cache.remote evil
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q $'branch.bypass-cache.remote\tevil$' "$TMP/after"
fixture
printf '#!/bin/sh\n' > "$TMP/hook-mode"
chmod -x "$TMP/hook-mode"
ln -s "$TMP/hook-mode" "$R/.git/hooks/pre-commit"
snap "$TMP/before"
chmod +x "$TMP/hook-mode"
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: changed' "$TMP/changes"
fixture
git -C "$R" switch -q --detach
git -C "$R" -c user.name=Foreign -c user.email=foreign@example.invalid commit -qm foreign --allow-empty
git -C "$R" tag -a v1 -m fixture
git -C "$R" switch -q main
snap "$TMP/before"
git -C "$R" switch -q -c x v1
snap "$TMP/after"
rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
if grep -q '^commit ' "$TMP/changes"; then exit 1; fi
# Security regression pins.
fixture
snap "$TMP/before"
git -C "$R" init -q --bare "$R/o\162igin"
printf '%s\n' 'o\\162igin/' >> "$R/.git/info/exclude"
git -C "$R" check-ignore -q 'o\162igin/'
git -C "$R" config branch.main.remote 'o\162igin'
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
# Check the remote classification independently of the hidden repository file.
grep -v '^metadata' "$TMP/before" > "$TMP/plain-before"
grep -v '^metadata' "$TMP/after" > "$TMP/plain-after"
rc_is 2 repo_state_compare "$TMP/plain-before" "$TMP/plain-after" "$TMP/changes"
for path in info/exclude info/attributes objects/info/alternates; do
  fixture
  snap "$TMP/before"
  printf '# fixture\n' >> "$R/.git/$path"
  snap "$TMP/after"
  expected=1
  [ "$path" != objects/info/alternates ] || expected=2
  rc_is "$expected" repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
done
for authority in 'https://u:PASS/SECRET@h/' 'https://u:PASS@SECRET@h/' '//u:SECRET@h/' 'https://SECRET@h/' 'https://u:SECRET?x@h/' 'https://u:SECRET#x@h/' 'https://u:pa/SECRET@h//x@y/'; do
  fixture
  snap "$TMP/before"
  git -C "$R" config "url.$authority.insteadOf" https://x
  snap "$TMP/after"
  rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
  if grep -q SECRET "$TMP/after" "$TMP/changes"; then
    echo 'userinfo shape leaked' >&2; exit 1
  fi
done
check_key core.sshCommand '/usr/bin/sshpass -p SECRET ssh' 2
if grep -q SECRET "$TMP/changes"; then echo 'core command leaked' >&2; exit 1; fi
fixture
git -C "$R" config credential.helper SECRET
(
  # Count calls across pipeline subshells, then fail on the config hash's Nth call.
  printf '0\n' > "$TMP/hash-count"
  _repo_state_sha256() {
    local data n
    data=$(cat)
    n=$(cat "$TMP/hash-count"); n=$((n + 1)); printf '%s\n' "$n" > "$TMP/hash-count"
    if [ "$data" = SECRET ]; then printf '%s\n' "$n" > "$TMP/hash-nth"; fi
    [ "$n" != "${fail_nth:-0}" ] || return 1
    printf '%s' "$data" | shasum -a 256 | cut -d ' ' -f 1
  }
  snap "$TMP/count-config"
  fail_nth=$(cat "$TMP/hash-nth")
  printf '0\n' > "$TMP/hash-count"
  rc_is 3 repo_state_snapshot "$R" "$TMP/failed-config"
)
# Hashing must not spool plaintext to a temporary file.
(
  mktemp() { echo 'plaintext hash spool attempted' >&2; return 1; }
  printf SECRET | _repo_state_sha256 >/dev/null
)
# Final drift regressions: bound snapshots even for hostile metadata types.
TIMEOUT=$(command -v timeout || command -v gtimeout)
for shape in fifo zero dangling; do
  fixture
  snap "$TMP/before"
  case "$shape" in
    fifo) rm "$R/.git/info/exclude"; mkfifo "$R/.git/info/exclude" ;;
    zero) ln -s /dev/zero "$R/.git/info/attributes" ;;
    dangling) ln -s "$TMP/absent-target" "$R/.git/info/attributes" ;;
  esac
  rc_is 0 "$TIMEOUT" -k 1 10 bash -c '. "$1"; repo_state_snapshot "$2" "$3"' _ "$BIN/lib/repo-state.sh" "$R" "$TMP/after"
  rc_is 1 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
  path=info/attributes
  [ "$shape" != fifo ] || path=info/exclude
  grep -qx "metadata $path: <changed>" "$TMP/changes" || { echo "metadata $shape missed" >&2; exit 1; }
done
fixture
snap "$TMP/before"
git -C "$R" -c user.name=Foreign -c user.email=foreign@example.invalid commit -qm injected --allow-empty
git -C "$R" update-ref refs/remotes/origin/zz HEAD
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^commit ' "$TMP/changes" || { echo 'remote exemption hole' >&2; exit 1; }
fixture
replacement=$(git -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree -m replacement "HEAD^{tree}")
for operation in add move remove; do
  snap "$TMP/before"
  case "$operation" in
    add) git -C "$R" replace HEAD "$replacement" ;;
    move)
      replacement=$(git -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree -m moved "HEAD^{tree}")
      git -C "$R" replace -f HEAD "$replacement" ;;
    remove) git -C "$R" replace -d HEAD ;;
  esac
  snap "$TMP/after"
  rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
done
fixture
git -C "$R" config branch.main.remote origin
git -C "$R" config branch.main.merge refs/heads/main
snap "$TMP/before"
git -C "$R" config branch.main.remote .
git -C "$R" config branch.main.merge refs/heads/redirected
snap "$TMP/after"
rc_is 2 repo_state_compare "$TMP/before" "$TMP/after" "$TMP/changes"
check_key remote.origin.pushurl 'https://u:SECRET/password@host.invalid/' 2
if grep -q SECRET "$TMP/after" "$TMP/changes"; then echo 'value userinfo leaked' >&2; exit 1; fi
for setting in 'editor /usr/local/bin/ed-wrap --api-key=SECRET' 'pager /usr/bin/env GH_TOKEN=SECRET less' 'fsmonitor /usr/bin/monitor --token=SECRET' 'editor ed --key=SECRET'; do
  key=${setting%% *}; value=${setting#* }
  check_key "core.$key" "$value" 2
  grep -Fq -- "-> ${value%% *}…" "$TMP/changes" || { echo 'command display not truncated' >&2; exit 1; }
  if grep -q SECRET "$TMP/changes"; then echo 'command arguments leaked' >&2; exit 1; fi
done
check_key core.editor $'/usr/bin/editor\t--secret=SECRET' 2
grep -Fq -- '-> /usr/bin/editor…' "$TMP/changes" || { echo 'encoded command whitespace leaked' >&2; exit 1; }
check_key 'url.https://host.invalid/?SECRET.insteadOf' https://x 2
if grep -q SECRET "$TMP/changes"; then echo 'displayed key query leaked' >&2; exit 1; fi
[ "$(printf fixture | repo_state_digest)" = "$(printf fixture | _repo_state_sha256)" ]
echo 'repo-state tests passed'
