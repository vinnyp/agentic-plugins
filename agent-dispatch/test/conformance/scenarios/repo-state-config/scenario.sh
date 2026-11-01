#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
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
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
fixture
git -C "$R" config --add include.path /missing-one
git -C "$R" config --add include.path /missing-two
snap "$TMP/before"
git -C "$R" config --unset-all include.path /missing-one
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
fixture
snap "$TMP/before"
git -C "$R" config --file "$GIT_CONFIG_GLOBAL" user.email changed@example.invalid
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '(global:' "$TMP/changes"
for key in credential.helper remote.origin.url; do
  # These paths deterministically reproduce the old short-marker false positive.
  fixture repo-p1p2
  git -C "$R" config "$key" 'https://u:PWONE_SECRET@h/r'
  snap "$TMP/before"
  git -C "$R" config "$key" 'https://u:PWTWO_SECRET@h/r'
  snap "$TMP/after"
  rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
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
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q ':  -> true$' "$TMP/changes"
fixture
git -C "$R" config x.value $'a = b\tend\nnext%'
git -C "$R" config remote.origin.url 'https://h/a b'
printf '[x]\n\tflag\n' >> "$R/.git/config"
snap "$TMP/before"
snap "$TMP/after"
rc_is 0 compare "$TMP/before" "$TMP/after" "$TMP/changes"
[ ! -s "$TMP/changes" ]
# The contract explicitly requires checking ls permission text.
# shellcheck disable=SC2012
[ "$(ls -l "$TMP/after" | cut -c 1-10)" = '-rw-------' ]
old_umask=$(umask)
snap "$TMP/after"
[ "$(umask)" = "$old_umask" ]
printf 'unreadable\n' > "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'config: <unreadable after review>' "$TMP/changes"
for bad in '' rel/path "$TMP"; do rc_is 3 "$BIN/repo-state-check" snapshot "$bad" "$TMP/after"; done
D="$TMP/decoy"; mkdir "$D"
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
printf 'unreadable\n' > "$TMP/after"
rc_is 2 "$TMP/links/check" compare "$TMP/before" "$TMP/after"
git -C "$R" config --file "$GIT_CONFIG_GLOBAL" user.email fixture@example.invalid
echo "PASS: repo-state-config"
