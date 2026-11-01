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
for pattern in home username email token wrapped; do
  case "$pattern" in
    home) printf '%s/file\n' "$HOME" ;;
    username) printf '%s\n' "$USER" ;;
    email) printf 'person@example.invalid\n' ;;
    token) printf 'sk-abcdefghijklmnopqrstuvwxyz123456\n' ;;
    wrapped) printf 'sk-abcdefghijklm\nnopqrstuvwxyz123456\n' ;;
  esac > "$work/input/stdout"
  cp "$work/input/stdout" "$work/before"
  if bash "$here/conformance/scrub.sh" "$work/input" > "$work/output" 2>&1; then
    fail "$pattern refused"
  fi
  [ ! -s "$work/output" ] || fail "$pattern writes nothing"
  cmp "$work/before" "$work/input/stdout" || fail "$pattern modified input"
done
printf 'public fixture output\n' > "$work/input/stdout"
bash "$here/conformance/scrub.sh" "$work/input" || fail 'clean fixture passes'
# Copy the recorder so no test recording can reach the source tree.
mkdir -p "$work/harness" "$work/stubs" "$work/root" "$work/agent-tmp"
cp "$here/conformance/record.sh" "$here/conformance/scrub.sh" "$work/harness/"
cat > "$work/stubs/codex" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$PWD" in "$DISPATCH_CONFORMANCE_ROOT"/record.*/repo) ;; *) exit 91 ;; esac
[ -d .git ] || exit 92
printf '%s\n' "${RECORD_TEST_OUTPUT:-public transcript}"
printf 'public diagnostic\n' >&2
exit 7
STUB
chmod +x "$work/stubs/codex"
TMPDIR="$work/agent-tmp" PATH="$work/stubs:$PATH" DISPATCH_CONFORMANCE_ROOT="$work/root" bash "$work/harness/record.sh" codex clean
[ "$(cat "$work/harness/recordings/codex/clean/rc")" = 7 ] || fail 'agent status recorded'
[ "$(cat "$work/harness/recordings/codex/clean/stdout")" = 'public transcript' ] || fail 'stdout recorded'
if TMPDIR="$work/agent-tmp" PATH="$work/stubs:$PATH" DISPATCH_CONFORMANCE_ROOT="$work/root" RECORD_TEST_OUTPUT='person@example.invalid' bash "$work/harness/record.sh" codex refused; then
  fail 'unsafe recording refused'
fi
[ ! -e "$work/harness/recordings/codex/refused" ] || fail 'refused recording published'
[ -z "$(ls -A "$work/root")" ] || fail 'scratch cleaned'
echo 'PASS: conformance scrub and recorder'
