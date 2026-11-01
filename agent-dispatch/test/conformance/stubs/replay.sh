# shellcheck shell=bash
set -eu
: "${SCN_TMP:?}" "${STUB_RECORDING:?}"
runtime=${0##*/}
{
  printf '%q' "$runtime"
  for arg in "$@"; do printf ' %q' "$arg"; done
  printf '\n'
} >> "$SCN_TMP/argv"
n=1
while [ -f "$SCN_TMP/stdin.$runtime.$n" ]; do n=$((n + 1)); done
cat > "$SCN_TMP/stdin.$runtime.$n"
recording=$STUB_RECORDING
if [ -d "$recording/$runtime/$n" ]; then
  recording=$recording/$runtime/$n
elif [ -d "$recording/$n" ]; then
  recording=$recording/$n
else
  for entry in "$recording"/* "$recording/$runtime"/*; do
    name=${entry##*/}
    case "$name" in ''|*[!0-9]*) continue ;; esac
    echo "stub $runtime: missing recording step $n" >&2
    exit 97
  done
fi
cat "$recording/stdout"
cat "$recording/stderr" >&2
rc=$(cat "$recording/rc")
case "$rc" in ''|*[!0-9]*) exit 2 ;; esac
[ "$rc" -le 255 ] || exit 2
exit "$rc"
