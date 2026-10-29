#!/usr/bin/env bash
set -eu
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-access-mutations.XXXXXX")
[ -n "$TASK_TMP" ] || exit 1
trap 'rm -rf "$TASK_TMP"' EXIT
mkdir "$TASK_TMP/bin"
cp "$SELF_DIR/test-review-repo-access.sh" "$SELF_DIR/dispatch-worker" "$SELF_DIR/review-pin.sh" "$TASK_TMP/bin/"
cp -R "$SELF_DIR/lib" "$TASK_TMP/bin/"
for mode in function top-level; do
  python3 - "$SELF_DIR/lib/review-clone.sh" "$TASK_TMP/bin/lib/review-clone.sh" "$mode" <<'PY'
import pathlib, sys
source, dest = map(pathlib.Path, sys.argv[1:3])
line = '  git -C "$src" rev-parse HEAD\n'
text=source.read_text()
if sys.argv[3]=='function': text=text.replace('review_clone_build() {\n','review_clone_build() {\n'+line)
else: text += '\n'+line.lstrip()
dest.write_text(text)
PY
  rc=0
  bash "$TASK_TMP/bin/test-review-repo-access.sh" > "$TASK_TMP/out" 2>&1 || rc=$?
  [ "$rc" = 1 ] && grep -q 'FAIL: unmarked repository access lib/review-clone.sh:' "$TASK_TMP/out" || {
    echo "FAIL: repository access audit accepted raw git in $mode"; exit 1;
  }
  grep 'FAIL: unmarked repository access lib/review-clone.sh:' "$TASK_TMP/out"
done
echo 'repository access mutations PASS'
