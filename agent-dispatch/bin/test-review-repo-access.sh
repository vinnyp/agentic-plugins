#!/usr/bin/env bash
# Enumerate repository-opening operations, including wrappers and file reads.
set -eu
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
python3 - "$SELF_DIR" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
files = ['dispatch-worker', 'review-pin.sh', 'lib/repo-state.sh', 'lib/review-clone.sh']
# These are child entrypoints or their transitive helpers. Adding a repository
# read to parent setup requires an explicit new bounded entrypoint here.
bounded_worker = {'review_launch_probe', 'review_reap_unbounded', 'review_reap_prune_child'}
pattern = re.compile(r'\b(?:git|_repo_state_git|_review_clone_git|find|cat)\b|<\s*"\$(?:file|before|after|marker|saltfile|common)')
failed = False
for name in files:
    function = ''
    for number, line in enumerate((root / name).read_text().splitlines(), 1):
        definition = re.match(r'([a-zA-Z_][a-zA-Z_0-9]*)\(\)\s*[({]', line)
        if definition:
            function = definition[1]
        if not pattern.search(line) or line.lstrip().startswith('#'):
            continue
        # Ignore prose and heredoc/prompt plumbing. Still enumerate those hits
        # below, but require that they contain no executable repository command.
        command = re.search(r'(?:\$\(|[;|(&]|^|then\s|!\s)\s*(?:[a-zA-Z_][a-zA-Z_0-9]*=\S+\s+)*(git|_repo_state_git|_review_clone_git|find|cat)\s', line)
        metadata_read = re.search(r'<\s*"\$(?:file|before|after|marker|saltfile|common)', line)
        if '--local-env-vars' in line:
            classification = 'exempt: rev-parse --local-env-vars'
        elif not command and not metadata_read:
            classification = 'text: no repository command'
        elif name.startswith('lib/'):
            classification = 'bounded: library child or file-interface helper'
        elif name == 'review-pin.sh' and function in {'review_pin_operation', 'load_marker'}:
            classification = 'bounded: review_pin_operation child'
        elif name == 'dispatch-worker' and function in bounded_worker:
            classification = 'bounded: worker child'
        elif name == 'dispatch-worker' and function == 'review_private_config':
            assert '-C "$REVIEW_STATE_DIR"' in line and 'GIT_CEILING_DIRECTORIES=' in line
            classification = 'private: isolated config directory (also bounded)'
        elif command and command[1] == 'cat' and ('$BRIEF' in line or '<<' in line):
            classification = 'input: prompt or usage, no repository metadata'
        else:
            print(f'FAIL: unmarked repository access {name}:{number}: {line.strip()}')
            failed = True
            continue
        print(f'{name}:{number}: {classification}: {line.strip()}')
if failed:
    sys.exit(1)
PY
