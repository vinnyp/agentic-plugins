"""Deterministic side effects, captured before fixture cleanup."""
import os
from pathlib import Path
import subprocess

repo = Path(os.environ['SCN_REPO'])
def git(tree, *args):
    return subprocess.check_output(['git', '-C', str(tree), *args], text=True).rstrip('\n')

if not (repo / '.git').exists():
    print('repository absent')
else:
    print('HEAD', git(repo, 'rev-parse', 'HEAD'))
    print('branches\n' + '\n'.join(sorted(git(repo, 'branch', '--list').splitlines())))
    porcelain = git(repo, 'worktree', 'list', '--porcelain')
    print('worktrees\n' + porcelain)
    trees = [Path(line[9:]) for line in porcelain.splitlines() if line.startswith('worktree ')]
    for tree in trees:
        print('tree', tree)
        print('status\n' + git(tree, 'status', '--porcelain', '--untracked-files=all'))
        print('result', int((tree / '_coding-result.json').exists()))
        directory = Path(git(tree, 'rev-parse', '--absolute-git-dir'))
        patch = directory / 'coding-dispatch-last-fail.patch'
        print('patch', patch, int(patch.exists()), len(patch.read_bytes().splitlines()) if patch.exists() else 0)
        patches = directory / 'coding-dispatch-fail-patches'
        print('fail-patches')
        if patches.exists():
            for item in sorted(patches.rglob('*')):
                if item.is_file():
                    print(item.relative_to(directory), len(item.read_bytes().splitlines()))
    print('worktree-directories')
    directory = repo.parent / '.worktrees'
    if directory.exists():
        for item in sorted(directory.rglob('*')):
            print(item.relative_to(directory))
