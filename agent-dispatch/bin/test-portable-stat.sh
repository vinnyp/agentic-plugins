#!/usr/bin/env bash
# Exercise real tree recipes under each installed stat implementation.
set -eu
fail() { echo "FAIL: $*" >&2; exit 1; }
BIN=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-portable-stat.XXXXXX")
[ -n "$TMP" ] || fail "empty scratch directory"
trap 'chmod -R u+w "$TMP"; rm -rf "$TMP"' EXIT
mkdir "$TMP/root" "$TMP/tmp"
export TMPDIR="$TMP/tmp"
printf 'good\ncontrol\n' > "$TMP/root/subject"
printf '%s\n' "--file subject --test-cmd 'bash check' --mutate-sed 's/good/bad/' --control-sed 's/control/broken/' --expect-fail-output HAZARD --control-expect-fail-output CONTROL" > "$TMP/mutants"
cat > "$TMP/root/check" <<'CHECK'
grep -q control subject || { echo CONTROL; exit 1; }
grep -q good subject || { echo HAZARD; exit 1; }
CHECK
chmod 644 "$TMP/root/subject"
check_stat() (
  local label=$1 implementation=$2 first='' tree output n
  mkdir "$TMP/$label-bin"
  ln -s "$implementation" "$TMP/$label-bin/stat"
  export PATH="$TMP/$label-bin:$PATH"
  export _PSTAT_DIALECT=bsd
  # shellcheck source=lib/portable-stat.sh
  . "$BIN/lib/portable-stat.sh"
  [ "$(pstat_mode "$TMP/root/subject")" = 644 ] || fail "$label mode"
  [ "$(pstat_uid "$TMP/root/subject")" = "$(id -u)" ] || fail "$label uid"
  [[ "$(pstat_mtime "$TMP/root/subject")" =~ ^[0-9]+$ ]] || fail "$label mtime"
  if [ "$label" = gnu ]; then
    [[ "$(pstat_mode "$TMP/root/subject")" =~ ^[0-7]{3,4}$ ]] || fail 'inherited dialect ignored'
    if chmod 4755 "$TMP/root/subject" && [ "$(stat -c %a "$TMP/root/subject")" = 4755 ]; then
      [ "$(pstat_mode "$TMP/root/subject")" = 755 ] || fail 'GNU special bits masked'
    else
      echo 'suid assertion SKIP (chmod refused)'
    fi
    chmod 644 "$TMP/root/subject"
  fi
  cd "$TMP/root"
  if command -v xattr >/dev/null 2>&1; then xattr -d com.example.t subject 2>/dev/null || :; fi
  for n in 1 2; do
    if [ "$n" = 2 ]; then
      if command -v xattr >/dev/null 2>&1; then
        xattr -w com.example.t 1 subject || fail 'write subject xattr'
      fi
      if [ -x /bin/ls ]; then
        ln -s /bin/ls "$TMP/$label-bin/ls"
      fi
    fi
    output=$(bash "$BIN/mutation-verify.sh" --copy-root . --file subject \
      --test-cmd 'bash check' \
      --mutate-sed 's/good/bad/' --control-sed 's/control/broken/' --expect-fail-output HAZARD --control-expect-fail-output CONTROL 2>&1)
    tree=$(printf '%s\n' "$output" | sed -n 's/.* tree=//p' | tail -1)
    [[ "$tree" =~ ^[0-9]+$ ]] || fail "$label tree missing"
    if [ "$n" = 1 ]; then first=$tree; else [ "$tree" = "$first" ] || fail "$label tree changed with xattr/ls"; fi
    output=$(bash "$BIN/mutation-sweep.sh" --copy-root . --mutants "$TMP/mutants" --out "$TMP/$label-$n" -j 1)
    [ "$(printf '%s\n' "$output" | sed -n 's/^SWEEP: .* tree=//p')" = "$first" ] || fail "$label sweep tree mismatch"
    [ "$(sed -n 's/.* tree=//p' "$TMP/$label-$n/1.verdict")" = "$first" ] || fail "$label sweep tree mismatch"
  done
  printf '%s\n' "$label portable stat PASS tree=$first"
)
# Include PATH's implementation, BSD's system path where present, and GNU's
# common package-manager paths. Probe dialects instead of assuming the OS.
check_stat default "$(command -v stat)"
if [ -x /usr/bin/stat ] && ! /usr/bin/stat --version >/dev/null 2>&1; then
  check_stat bsd /usr/bin/stat
else
  echo "bsd leg SKIP (no BSD stat)"
fi
gnu_found=0
for candidate in "$(command -v stat)" "$(command -v gstat || :)" /opt/homebrew/opt/coreutils/libexec/gnubin/stat /usr/local/opt/coreutils/libexec/gnubin/stat /usr/bin/stat; do
  [ -x "$candidate" ] || continue
  if "$candidate" --version >/dev/null 2>&1; then
    gnu_found=1
    check_stat gnu "$candidate"
    break
  fi
done
[ "$gnu_found" = 1 ] || echo "gnu leg SKIP (no GNU stat)"
