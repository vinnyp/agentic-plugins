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
bounded_worker = {'review_launch_probe', 'review_reap_unbounded', 'review_reap_prune_child', 'review_read_output_child'}
bounded_library = {
    'lib/repo-state.sh': {
        '_repo_state_git', '_repo_state_configs', '_repo_state_hooks',
        '_repo_state_dirty', '_repo_state_tree', '_repo_state_nonregular_text',
        '_repo_state_worktree_configs', '_repo_state_snapshot_text',
        '_repo_state_salt', '_repo_state_read_file', 'repo_state_run_bounded', '_repo_state_compare_text',
    },
    'lib/review-clone.sh': {'_review_clone_git', '_review_clone_refs', 'review_clone_build'},
}
pattern = re.compile(r'wc\s+-c\s*<|grep[^\n]*\"\$(?:file|review_outfile|agy_brief|errlog|stdoutlog)|\b(?:git|_repo_state_git|_review_clone_git|find|cat)\b|<\s*"\$(?:file|before|after|marker|saltfile|common|review_outfile|agy_brief|errlog|stdoutlog)')
failed = False
for name in files:
    function = ''
    for number, line in enumerate((root / name).read_text().splitlines(), 1):
        definition = re.match(r'([a-zA-Z_][a-zA-Z_0-9]*)\(\)\s*[({]', line)
        if definition:
            function = definition[1]
        elif re.match(r'^[})]', line):
            function = ''
        if not pattern.search(line) or line.lstrip().startswith('#'):
            continue
        # Ignore prose and heredoc/prompt plumbing. Still enumerate those hits
        # below, but require that they contain no executable repository command.
        assignment = r"[a-zA-Z_][a-zA-Z_0-9]*=(?:\$\([^)]*\)|\"[^\"]*\"|'[^']*'|[^\s]+)\s+"
        command = re.search(r'(?:\$\(|[;|(&]|^|(?:then|if|elif|else|do)\s|!\s)\s*(?:' + assignment + r')*(git|_repo_state_git|_review_clone_git|find|cat)\s', line)
        metadata_read = re.search(r'wc\s+-c\s*<|grep[^\n]*\"\$(?:file|review_outfile|agy_brief|errlog|stdoutlog)|<\s*"\$(?:file|before|after|marker|saltfile|common|review_outfile|agy_brief|errlog|stdoutlog)', line)
        if '<<<' in line:
            metadata_read = None
        if '--local-env-vars' in line:
            classification = 'exempt: rev-parse --local-env-vars'
        elif not command and not metadata_read:
            classification = 'text: no repository command'
        elif name in bounded_library and function in bounded_library[name] and (
                not command or command[1] != 'git' or function in {'_repo_state_git', '_review_clone_git'}):
            classification = 'bounded: allowlisted library function'
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
