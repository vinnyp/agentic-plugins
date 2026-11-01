#!/usr/bin/env bash
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/conformance-scrub-test.XXXXXX")
[ -n "$work" ] || exit 1
work=$(CDPATH='' cd -- "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$here/conformance/scrub.sh" ] || fail 'scrub.sh missing'
mkdir "$work/input"
for pattern in home username email token wrapped google api jwt basic bearer github slack aws pem access refresh secret key password host wrappedhome crlf; do
  case "$pattern" in
    google) prefix='ya29.'; body='abcdefghijklmnop'; printf '%s%s\n' "$prefix" "$body" ;;
    api) prefix='AIza'; body='abcdefghijklmnopqrstuvwxyz123456789'; printf '%s%s\n' "$prefix" "$body" ;;
    jwt) prefix='eyJ'; body='hbGciOiJIUzI1NiJ9.abcdefgh.ijklmnop'; printf '%s%s\n' "$prefix" "$body" ;;
    basic) scheme='Basic'; body='abcdef=='; printf 'Authorization: %s %s\n' "$scheme" "$body" ;;
    bearer) scheme='Bearer'; body='abcdef'; printf 'Authorization: %s %s\n' "$scheme" "$body" ;;
    github) prefix='github_pat_'; body='abcdefghijklmnopqrstuv'; printf '%s%s\n' "$prefix" "$body" ;;
    slack) prefix='xoxb-'; body='abcdefghijklmnopqrstuv'; printf '%s%s\n' "$prefix" "$body" ;;
    aws) prefix='AKIA'; body='ABCDEFGHIJKLMNOP'; printf '%s%s\n' "$prefix" "$body" ;;
    pem) prefix='-----BEGIN'; body=' CERTIFICATE-----'; printf '%s%s\n' "$prefix" "$body" ;;
    access|refresh|secret|key|password)
      case "$pattern" in access) key=access_token ;; refresh) key=refresh_token ;; secret) key=client_secret ;; key) key=api_key ;; password) key=password ;; esac
      prefix='secret-'; body='value'; printf '{"%s": "%s%s"}\n' "$key" "$prefix" "$body" ;;
    host) hostname ;;
    wrappedhome) printf '%s' "$HOME" | sed 's|/|/ \\\n|g' ;;
    crlf) prefix='ya29.'; body='abc'; tail='defghijklmnop'; printf '%s%s\r\n  %s\n' "$prefix" "$body" "$tail" ;;
    home) printf '%s/file\n' "$HOME" ;;
    username) printf '%s\n' "$(id -un)" ;;
    email) printf 'person@example.invalid\n' ;;
    token) prefix='sk-'; body='abcdefghijklmnopqrstuvwxyz123456'; printf '%s%s\n' "$prefix" "$body" ;;
    wrapped) prefix='sk-'; body='abcdefghijklm'; tail='nopqrstuvwxyz123456'; printf '%s%s\n%s\n' "$prefix" "$body" "$tail" ;;
  esac > "$work/input/stdout"
  cp "$work/input/stdout" "$work/before"
  if bash "$here/conformance/scrub.sh" "$work/input" > "$work/output" 2>&1; then
    fail "$pattern refused"
  fi
  [ ! -s "$work/output" ] || fail "$pattern writes nothing"
  cmp "$work/before" "$work/input/stdout" || fail "$pattern modified input"
done
printf "public fixture\n" > "$work/input/stdout"
mkdir "$work/input/nested"
scheme='Bearer'; body='secret'
printf 'Authorization: %s %s' "$scheme" "$body" > "$work/input/nested/stderr"
if bash "$here/conformance/scrub.sh" "$work/input"; then fail 'nested stderr accepted'; fi
rm "$work/input/nested/stderr"
ln -s "$work/before" "$work/input/link"
if bash "$here/conformance/scrub.sh" "$work/input"; then fail 'symlink accepted'; fi
rm "$work/input/link"
bash "$here/conformance/scrub.sh" "$here/conformance/recordings" || fail 'committed recordings refused'
printf 'public fixture output\n' > "$work/input/stdout"
bash "$here/conformance/scrub.sh" "$work/input" || fail 'clean fixture passes'
# Copy the recorder so no test recording can reach the source tree.
mkdir -p "$work/harness/test/conformance" "$work/stubs" "$work/root" "$work/agent-tmp"
cp "$here/conformance/record.sh" "$here/conformance/scrub.sh" "$work/harness/test/conformance/"
mkdir -p "$work/harness/bin/lib"
cp "$here/../bin/lib/timeout-bin.sh" "$here/../bin/lib/portable-timeout" "$work/harness/bin/lib/"
cat > "$work/stubs/codex" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$PWD" in "$DISPATCH_CONFORMANCE_ROOT"/record.*/repo) ;; *) exit 91 ;; esac
[ -d .git ] || exit 92
case "$(basename "$0"):$*" in
  codex:*'--sandbox read-only'*) ;;
  claude:*'--permission-mode plan'*) ;;
  agy:*'--add-dir'*) ;;
  *) exit 93 ;;
esac
printf '%s\n' "${RECORD_TEST_OUTPUT:-public transcript}"
printf 'public diagnostic\n' >&2
exit 7
STUB
chmod +x "$work/stubs/codex"
cp "$work/stubs/codex" "$work/stubs/agy"
cp "$work/stubs/codex" "$work/stubs/claude"
for runtime in agy claude; do
  TMPDIR="$work/agent-tmp" PATH="$work/stubs:$PATH" DISPATCH_CONFORMANCE_ROOT="$work/root" bash "$work/harness/test/conformance/record.sh" "$runtime" clean
  [ "$(cat "$work/harness/test/conformance/recordings/$runtime/clean/rc")" = 7 ] || fail "$runtime flags"
done
for name in ../escape . bad.name; do
  if TMPDIR="$work/agent-tmp" DISPATCH_CONFORMANCE_ROOT="$work/root" bash "$work/harness/test/conformance/record.sh" codex "$name"; then fail 'invalid name accepted'; fi
done
if TMPDIR="$work" DISPATCH_CONFORMANCE_ROOT="$work/root" bash "$work/harness/test/conformance/record.sh" codex tmp; then fail 'TMPDIR accepted'; fi
TMPDIR="$work/agent-tmp" PATH="$work/stubs:$PATH" DISPATCH_CONFORMANCE_ROOT="$work/root" bash "$work/harness/test/conformance/record.sh" codex clean
[ "$(cat "$work/harness/test/conformance/recordings/codex/clean/rc")" = 7 ] || fail 'agent status recorded'
[ "$(cat "$work/harness/test/conformance/recordings/codex/clean/stdout")" = 'public transcript' ] || fail 'stdout recorded'
if TMPDIR="$work/agent-tmp" PATH="$work/stubs:$PATH" DISPATCH_CONFORMANCE_ROOT="$work/root" RECORD_TEST_OUTPUT='person@example.invalid' bash "$work/harness/test/conformance/record.sh" codex refused; then
  fail 'unsafe recording refused'
fi
[ ! -e "$work/harness/test/conformance/recordings/codex/refused" ] || fail 'refused recording published'
[ -z "$(ls -A "$work/root")" ] || fail 'scratch cleaned'
if TMPDIR="$work/agent-tmp" PATH="$work/stubs:$PATH" DISPATCH_CONFORMANCE_ROOT="$work/root" bash "$work/harness/test/conformance/record.sh" codex clean; then fail 'overwrite accepted'; fi
echo 'PASS: conformance scrub and recorder'
