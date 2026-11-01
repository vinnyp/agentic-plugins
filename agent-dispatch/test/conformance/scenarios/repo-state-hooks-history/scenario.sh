#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# Suppress Git-version-dependent advice in fixture history probes.
git -C "$TMP" config --file "$GIT_CONFIG_GLOBAL" advice.graftFileDeprecated false
fixture
snap "$TMP/before"
printf '#!/bin/sh\n' > "$R/.git/hooks/pre-commit"
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: added' "$TMP/changes"
# Hook payloads include regular content, symlink targets and resolved content.
snap "$TMP/before"
printf '# changed\n' >> "$R/.git/hooks/pre-commit"
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: changed' "$TMP/changes"
snap "$TMP/before"
rm "$R/.git/hooks/pre-commit"
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: removed' "$TMP/changes"
fixture
printf '#!/bin/sh\n' > "$TMP/hook-one"
printf '#!/bin/sh\n' > "$TMP/hook-two"
snap "$TMP/before"
ln -s "$TMP/hook-one" "$R/.git/hooks/pre-commit"
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: added' "$TMP/changes"
snap "$TMP/before"
ln -sf "$TMP/hook-two" "$R/.git/hooks/pre-commit"
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: changed' "$TMP/changes"
snap "$TMP/before"
printf '# changed\n' >> "$TMP/hook-two"
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: changed' "$TMP/changes"
snap "$TMP/before"
rm "$TMP/hook-two"
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: changed' "$TMP/changes"
fixture
mkdir "$R/.githooks"
printf '#!/bin/sh\n' > "$R/.githooks/pre-commit"
git -C "$R" config core.hooksPath .githooks
snap "$TMP/before"
printf '# changed\n' >> "$R/.githooks/pre-commit"
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks core.hooksPath/pre-commit: changed' "$TMP/changes"
snap "$TMP/before"
common=$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)
printf '#!/bin/sh\n' > "$common/hooks/pre-push"
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-push: added' "$TMP/changes"
fixture
# Ensure the sample assertion is exercised even with an empty system template.
printf '# sample\n' > "$R/.git/hooks/fixture.sample"
snap "$TMP/before"
mkdir "$R/.githooks"
git -C "$R" config core.hooksPath .githooks
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
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
  rc_is "$expected" compare "$TMP/before" "$TMP/after" "$TMP/changes"
  grep -q '^ref refs/heads/main:' "$TMP/changes"
  if [ "$identity" = foreign ]; then grep -q '^commit ' "$TMP/changes"
  elif grep -q '^commit ' "$TMP/changes"; then fail 'unexpected foreign commit report'; fi
done
fixture
git -C "$R" checkout -qb old
git -C "$R" -c user.name=t -c user.email=t@x.invalid commit -qm old --allow-empty
snap "$TMP/before"
git -C "$R" checkout -qb new old
snap "$TMP/after"
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
if grep -q '^commit ' "$TMP/changes"; then fail 'unexpected foreign commit report'; fi
for operation in stash notes untracked; do
  fixture
  snap "$TMP/before"
  case "$operation" in
    stash) printf x > "$R/file"; git -C "$R" add file; git -C "$R" stash -q ;;
    notes) git -C "$R" notes add -m x ;;
    untracked) printf x > "$R/new-file" ;;
  esac
  snap "$TMP/after"
  rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
  if [ "$operation" = untracked ]; then grep -q '^tree .*new-file' "$TMP/changes"
  else grep -q '^ref ' "$TMP/changes"; fi
done
fixture
wt="$TMP/linked"
git -C "$R" worktree add -q --detach "$wt" HEAD
snap "$TMP/before"
git -C "$wt" commit -qm moved --allow-empty
snap "$TMP/after"
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q "^worktree $wt: HEAD .* -> HEAD " "$TMP/changes"
snap "$TMP/before"
rm -rf "$wt"
snap "$TMP/after"
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx "tree $wt: unreadable" "$TMP/changes"
echo "PASS: repo-state-hooks-history"
