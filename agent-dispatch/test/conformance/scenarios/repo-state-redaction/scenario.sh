#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# Suppress Git-version-dependent advice in fixture history probes.
git -C "$TMP" config --file "$GIT_CONFIG_GLOBAL" advice.graftFileDeprecated false
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
  rc_is "$expected" compare "$TMP/before" "$TMP/after" "$TMP/changes"
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
  rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
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
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^config url.https://h/.insteadof ' "$TMP/changes"
if grep -E 'PWONE_SECRET|PWTWO_SECRET' "$TMP/before" "$TMP/after" "$TMP/changes"; then
  echo "secret leaked into snapshot/changes for credentialed key" >&2
  exit 1
fi
git -C "$R" config "$key_one" https://x
snap "$TMP/after"
# Neither an offline guess nor plaintext may appear; salted keys remain distinct.
for secret in PWONE_SECRET PWTWO_SECRET; do
  digest=$(printf 'u:%s' "$secret" | digest)
  if grep -Fq "${digest:0:12}" "$TMP/after" "$TMP/changes"; then
    fail 'credentialed key exposes an unsalted guess digest'
  fi
done
[ "$(awk -F '\t' '$1=="config" && $4 ~ /^url\.https:/ {print $4}' "$TMP/after" | sort -u | wc -l | tr -d ' ')" = 2 ] || fail 'distinct credentialed keys collapsed'

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
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^ref refs/heads/main:' "$TMP/changes"
if grep -q '^commit ' "$TMP/changes"; then fail 'unexpected foreign commit report'; fi
fixture
snap "$TMP/before"
git -C "$R" -c user.email=foreign@example.invalid commit -qm email-only --allow-empty
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^commit .* committer <changed>$' "$TMP/changes"
fixture
git -C "$R" config extensions.worktreeConfig true
wt="$TMP/config-linked"
git -C "$R" worktree add -q -b linked "$wt"
snap "$TMP/before"
git -C "$wt" config --worktree alias.x y
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^config alias.x ' "$TMP/changes"
for value in $'a\nb' $'a\tb'; do
  fixture
  git -C "$R" config x.value "$value"
  snap "$TMP/before"
  git -C "$R" config x.value "${value/b/c}"
  snap "$TMP/after"
  rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
  grep -q '^config x.value ' "$TMP/changes"
done
fixture
git -C "$R" branch alternate
snap "$TMP/before"
git -C "$R" switch -q alternate
snap "$TMP/after"
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^worktree .*refs/heads/main -> HEAD .*refs/heads/alternate$' "$TMP/changes"
wt="$TMP/removed-linked"
snap "$TMP/before"
git -C "$R" worktree add -q --detach "$wt"
snap "$TMP/after"
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx "tree $wt: worktree added" "$TMP/changes"
snap "$TMP/before"
git -C "$R" worktree remove "$wt"
snap "$TMP/after"
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx "tree $wt: worktree removed" "$TMP/changes"
if grep -q '0 new dirty paths' "$TMP/changes"; then exit 1; fi
printf first > "$R/dirty"
snap "$TMP/before"
git -C "$R" add dirty
snap "$TMP/after"
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx "tree $R: status changed (no new dirty paths)" "$TMP/changes"
echo "PASS: repo-state-redaction"
