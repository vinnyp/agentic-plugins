#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=agent-dispatch/test/conformance/repo-state-fixture.sh
source "$(cd "$(dirname "$0")/../.." && pwd)/repo-state-fixture.sh"
# Suppress Git-version-dependent advice in fixture history probes.
git -C "$TMP" config --file "$GIT_CONFIG_GLOBAL" advice.graftFileDeprecated false
# Fail closed on an explicit unreadable baseline.
fixture
snap "$TMP/after"
printf 'unreadable\n' > "$TMP/bad-before"
rc_is 3 compare "$TMP/bad-before" "$TMP/after" "$TMP/changes"
grep -qx 'state: <unreadable before snapshot>' "$TMP/changes"
check_key branch.main.remote /tmp/x.git 2
fixture
git -C "$R" config branch.main.remote origin
snap "$TMP/before"
git -C "$R" config --unset branch.main.remote
snap "$TMP/after"
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
fixture
snap "$TMP/before"
git -C "$R" remote add evil https://example.invalid/evil
git -C "$R" config branch.bypass-cache.remote evil
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q $'branch.bypass-cache.remote\tevil$' "$TMP/after"
fixture
printf '#!/bin/sh\n' > "$TMP/hook-mode"
chmod -x "$TMP/hook-mode"
ln -s "$TMP/hook-mode" "$R/.git/hooks/pre-commit"
snap "$TMP/before"
chmod +x "$TMP/hook-mode"
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -qx 'hooks pre-commit: changed' "$TMP/changes"
fixture
git -C "$R" switch -q --detach
git -C "$R" -c user.name=Foreign -c user.email=foreign@example.invalid commit -qm foreign --allow-empty
git -C "$R" tag -a v1 -m fixture
git -C "$R" switch -q main
snap "$TMP/before"
git -C "$R" switch -q -c x v1
snap "$TMP/after"
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
if grep -q '^commit ' "$TMP/changes"; then fail 'unexpected foreign commit report'; fi
# Security regression pins.
fixture
snap "$TMP/before"
git -C "$R" init -q --bare "$R/o\162igin"
printf '%s\n' 'o\\162igin/' >> "$R/.git/info/exclude"
git -C "$R" check-ignore -q 'o\162igin/'
git -C "$R" config branch.main.remote 'o\162igin'
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
# Check the remote classification independently of the hidden repository file.
grep -v '^metadata' "$TMP/before" > "$TMP/plain-before"
grep -v '^metadata' "$TMP/after" > "$TMP/plain-after"
rc_is 2 compare "$TMP/plain-before" "$TMP/plain-after" "$TMP/changes"
for path in info/exclude info/attributes objects/info/alternates; do
  fixture
  snap "$TMP/before"
  printf '# fixture\n' >> "$R/.git/$path"
  snap "$TMP/after"
  expected=1
  [ "$path" != objects/info/alternates ] || expected=2
  rc_is "$expected" compare "$TMP/before" "$TMP/after" "$TMP/changes"
done
for authority in 'https://u:PASS/SECRET@h/' 'https://u:PASS@SECRET@h/' '//u:SECRET@h/' 'https://SECRET@h/' 'https://u:SECRET?x@h/' 'https://u:SECRET#x@h/' 'https://u:pa/SECRET@h//x@y/'; do
  fixture
  snap "$TMP/before"
  git -C "$R" config "url.$authority.insteadOf" https://x
  snap "$TMP/after"
  rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
  if grep -q SECRET "$TMP/after" "$TMP/changes"; then
    echo 'userinfo shape leaked' >&2; exit 1
  fi
done
check_key core.sshCommand '/usr/bin/sshpass -p SECRET ssh' 2
if grep -q SECRET "$TMP/changes"; then echo 'core command leaked' >&2; exit 1; fi
for shape in fifo zero dangling; do
  fixture
  snap "$TMP/before"
  case "$shape" in
    fifo) rm "$R/.git/info/exclude"; mkfifo "$R/.git/info/exclude" ;;
    zero) ln -s /dev/zero "$R/.git/info/attributes" ;;
    dangling) ln -s "$TMP/absent-target" "$R/.git/info/attributes" ;;
  esac
  rc_is 0 "$BIN/repo-state-check" snapshot "$R" "$TMP/after"
  expected=1
  [ "$shape" != fifo ] || expected=2
  rc_is "$expected" compare "$TMP/before" "$TMP/after" "$TMP/changes"
  path=info/attributes
  [ "$shape" != fifo ] || path=info/exclude
  grep -qx "metadata $path: <changed>" "$TMP/changes" || { echo "metadata $shape missed" >&2; exit 1; }
done
echo 'hostile metadata types PASS'
fixture
snap "$TMP/before"
git -C "$R" -c user.name=Foreign -c user.email=foreign@example.invalid commit -qm injected --allow-empty
# Pins docs/commands.md Limits: forged remote refs can conceal foreign history.
git -C "$R" update-ref refs/remotes/origin/zz HEAD
snap "$TMP/after"
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
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
  rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
done
fixture
git -C "$R" config branch.main.remote origin
git -C "$R" config branch.main.merge refs/heads/main
snap "$TMP/before"
git -C "$R" config branch.main.remote .
git -C "$R" config branch.main.merge refs/heads/redirected
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
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
check_key core.hooksPath $'/tmp/hooks\ninjected\r\177' 2
grep -Fq '\x0a' "$TMP/changes" || { echo 'value newline was not escaped' >&2; exit 1; }
[ "$(grep -c '^injected' "$TMP/changes")" = 0 ] || fail "newline injected a display record"
# History metadata must be critical, including when it conceals a foreign commit.
for history in graft foreign-graft shallow; do
  fixture
  git -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm second --allow-empty
  snap "$TMP/before"
  if [ "$history" = foreign-graft ]; then
    git -C "$R" -c user.name=Foreign -c user.email=foreign@example.invalid commit -qm foreign --allow-empty
    git -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm tip --allow-empty
  fi
  sha=$(git -C "$R" rev-parse HEAD)
  if [ "$history" = shallow ]; then
    printf '%s\n' "$sha" > "$R/.git/shallow"
  else
    printf '%s\n' "$sha" > "$R/.git/info/grafts"
  fi
  snap "$TMP/after"
  rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
  if [ "$history" = foreign-graft ]; then
    grep -q '^commit ' "$TMP/changes" || { echo 'graft concealed foreign commit' >&2; exit 1; }
  fi
done
# A real concurrent pull must remain a warning.
fixture
snap "$TMP/before"
upstream="$TMP/upstream"; mkdir "$upstream"
[ -n "$upstream" ] || exit 1
git -C "$upstream" clone -q -b main "$R.git" .
git -C "$upstream" -c user.name=Foreign -c user.email=foreign@example.invalid commit -qm upstream --allow-empty
git -C "$upstream" -c user.name=Fixture -c user.email=fixture@example.invalid push -q origin main
git -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid pull -q --ff-only origin main
snap "$TMP/after"
rc_is 1 compare "$TMP/before" "$TMP/after" "$TMP/changes"
for key in core.pager $'example.sub\033section.value'; do
  check_key "$key" $'pager\033[2J' 2
  if LC_ALL=C grep -q $'\033' "$TMP/changes"; then echo 'raw terminal control byte' >&2; exit 1; fi
  grep -Fq '\x1b' "$TMP/changes" || { echo 'missing escaped control byte' >&2; exit 1; }
done
fixture
rm "$R/.git/info/exclude"
mkfifo "$R/.git/info/exclude"
snap "$TMP/before"
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q 'nonregular .*info/exclude: critical' "$TMP/changes"
fixture
key='url.https://u:pa/SECRET@h//x@y/.insteadOf'
git -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid config "$key" old
snap "$TMP/before"
git -C "$R" -c user.name=Fixture -c user.email=fixture@example.invalid config "$key" new
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
[ "$(grep -c '^config redacted\.' "$TMP/changes")" = 1 ] || { echo 'redacted key value paired incorrectly' >&2; exit 1; }
key_guess=$(printf '%s' "$key" | digest)
if grep -Eq "SECRET|${key_guess:0:12}" "$TMP/after" "$TMP/changes"; then
  fail 'redacted whole key exposes plaintext or an unsalted guess digest'
fi
echo 'repo-state tests passed'

fixture
snap "$TMP/before"
git -C "$R" -c user.name=Foreign -c user.email=foreign@example.invalid commit -qm graph --allow-empty
# A genuine graph pins the disabled optimization; forging its contents is impractical here.
git -C "$R" commit-graph write --reachable
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -q '^commit ' "$TMP/changes" || fail 'commit graph concealed foreign commit'
fixture
snap "$TMP/before"
printf hook > "$R/.git/hooks/"$'c1\xc2\x9b'
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -Fq '\xc2\x9b' "$TMP/changes" || fail 'C1 filename not escaped'
fixture
key='url.https://u:SECRET@example.invalid/.insteadOf'
snap "$TMP/before"
git -C "$R" config "$key" new
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
guess=$(printf '%s' 'u:SECRET' | digest)
! grep -Eq "SECRET|${guess:0:12}" "$TMP/changes" || fail 'redaction guess oracle'

fixture
snap "$TMP/before"
mkfifo "$R/.git/"$'fifo\ninjected'
snap "$TMP/after"
rc_is 2 compare "$TMP/before" "$TMP/after" "$TMP/changes"
grep -Fq 'fifo\x0ainjected: critical' "$TMP/changes" || fail 'nonregular filename newline not escaped'
! grep -q '^injected' "$TMP/changes" || fail 'nonregular filename injected record'

# ---------------------------------------------------------------------------
echo "PASS: repo-state-security"
