#!/usr/bin/env bash
set -eu
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/review-access-mutations.XXXXXX")
[ -n "$TASK_TMP" ] || exit 1
trap 'rm -rf "$TASK_TMP"' EXIT
mkdir "$TASK_TMP/bin"
cp "$SELF_DIR/test-review-repo-access.sh" "$SELF_DIR/dispatch-worker" "$SELF_DIR/review-pin.sh" "$TASK_TMP/bin/"
cp -R "$SELF_DIR/lib" "$TASK_TMP/bin/"
python3 - "$SELF_DIR" "$TASK_TMP/bin" <<'PYTHON'
import pathlib, subprocess, sys
source, dest = map(pathlib.Path, sys.argv[1:])
files = ['dispatch-worker', 'review-pin.sh', 'lib/review-clone.sh']
original = {name: (source/name).read_text() for name in files}
mutations = [
    ('clone function', 'lib/review-clone.sh', lambda s: s.replace('review_clone_build() {\n', 'review_clone_build() {\n  git -C "$x" rev-parse HEAD\n')),
    ('clone top level', 'lib/review-clone.sh', lambda s: s+'\ngit -C "$x" rev-parse HEAD\n'),
    ('pin top level', 'review-pin.sh', lambda s: s+'\ngit -C "$x" rev-parse HEAD\n'),
    ('worker conditional', 'dispatch-worker', lambda s: s.replace('review_launch_probe() {', 'if git -C "$x" rev-parse HEAD; then :; fi\nreview_launch_probe() {')),
    ('private ceiling', 'dispatch-worker', lambda s: s.replace('GIT_CEILING_DIRECTORIES=$(dirname "$REVIEW_STATE_DIR") ', '')),
]
for label, name, mutate in mutations:
    for file, text in original.items(): (dest/file).write_text(text)
    changed = mutate(original[name])
    assert changed != original[name], label
    (dest/name).write_text(changed)
    result = subprocess.run(['bash', str(dest/'test-review-repo-access.sh')], capture_output=True, text=True)
    assert result.returncode == 1, label+': audit accepted mutation\n'+result.stdout+result.stderr
    assert ('AssertionError' in result.stderr if label == 'private ceiling' else 'FAIL: unmarked repository access '+name+':' in result.stdout), label
    print(label+': rejected')
# Assignment values containing spaces must still reach the private-config assertion.
for value in ['$(dirname "$REVIEW_STATE_DIR")', '"value with spaces"', "'value with spaces'"]:
    for file, text in original.items(): (dest/file).write_text(text)
    text=original['dispatch-worker'].replace('GIT_CEILING_DIRECTORIES=$(dirname "$REVIEW_STATE_DIR") ', 'GIT_CEILING_DIRECTORIES='+value+' ')
    (dest/'dispatch-worker').write_text(text)
    result=subprocess.run(['bash', str(dest/'test-review-repo-access.sh')], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout+result.stderr
    assert 'private: isolated config directory' in result.stdout
print('repository access mutations PASS')
PYTHON
