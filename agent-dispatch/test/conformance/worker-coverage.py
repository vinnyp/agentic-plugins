"""Fail-closed inventory accounting and independent worker scenario assertions."""
import csv
from pathlib import Path
import sys

root = Path(sys.argv[1])
actual = Path(sys.argv[2]) if len(sys.argv) > 2 else None


def rows(name):
    return list(csv.reader((root / name).open(), delimiter='\t'))


inventory = {tuple(r) for r in rows('contract/inventory.tsv')
             if len(r) == 5 and r[0] == 'dispatch-worker'
             and r[1] in ('exit', 'line', 'flag', 'env')}
covered, exempt = rows('worker-coverage.tsv'), rows('worker-exemptions.tsv')
seen = set()
for row in covered + exempt:
    key = tuple(row[:5])
    assert key in inventory and key not in seen, f'stale/duplicate coverage: {row}'
    seen.add(key)
for row in exempt:
    assert len(row) == 6 and row[5].strip(), row
for row in covered:
    assert len(row) == 7 and row[5].startswith('worker-'), row
    assert (root / 'scenarios' / row[5] / 'scenario.sh').is_file(), row
    if actual:
        directory = actual / row[5]
        observation = row[6]
        if observation.startswith('rc='):
            assert (directory / 'rc').read_text().strip() == observation[3:], row
        else:
            file, fragment = observation.split(':', 1)
            assert fragment in (directory / file).read_text(), row
assert seen == inventory, f'uncovered inventory rows: {inventory - seen}'
if not actual:
    sys.exit(0)

for name, expected in rows('worker-expectations.tsv'):
    assert (actual / name / 'rc').read_text().strip() == expected, name
    assert 'missing recording' not in (actual / name / 'stderr').read_text(), name


def read(name, file):
    return (actual / ('worker-' + name) / file).read_text()


for runtime in ('codex', 'claude'):
    assert '--sandbox read-only' in read('codex-review', 'argv')
    assert '--permission-mode plan' in read('claude-review', 'argv')
    assert '--dangerously-skip-permissions' in read('claude-edit', 'argv')
    assert '--sandbox danger-full-access' in read('codex-edit', 'argv')
    # These runtimes intentionally do not enforce agy's body gates.
    assert 'DISPATCH_REVIEW_STATE=clean original_rc=0' in read(runtime+'-review', 'stderr')
assert read('agy-review', 'argv').splitlines()[0:2] == ['agy models', 'agy agent']
assert '--agent=fixture-reviewer --dangerously-skip-permissions' in read('agy-review', 'argv')
assert '--dangerously-skip-permissions' not in read('agy-edit', 'argv')
assert 'AUTONOMOUS-EXECUTION MODE' in read('agy-edit', 'stdin.agy.3')
assert 'READ-ONLY REVIEW MODE' in read('agy-review', 'stdin.agy.3')
assert read('codex-review', 'stdin.codex.1') == 'Review tracked.txt.\n'
assert read('claude-review', 'stdin.claude.1') == 'Review tracked.txt.\n'
for name in ('agy-dirty', 'agy-allow-dirty', 'agy-allow-env'):
    assert ' M tracked.txt' in read(name, 'state'), name
assert read('agy-dirty', 'argv').splitlines() == ['agy models', 'agy agent']
assert 'brief names uncommitted files: tracked.txt' in read('agy-dirty', 'stderr')
for name in ('agy-allow-dirty', 'agy-allow-env'):
    assert len(read(name, 'argv').splitlines()) == 3
for runtime in ('codex', 'agy', 'claude'):
    assert 'config' in read(runtime+'-drift', 'stderr')
    assert 'critical(' in read(runtime+'-drift', 'stderr')
    assert 'drift = true' not in read(runtime+'-review', 'stderr')
assert len(read('agy-missing-model', 'argv').splitlines()) == 1
assert len(read('agy-auth', 'argv').splitlines()) == 1
for name in ('agy-retry', 'agy-retry-blocked', 'agy-timeout'):
    assert len(read(name, 'argv').splitlines()) == 4, name
    assert read(name, 'stdin.agy.3') == read(name, 'stdin.agy.4'), name
    assert 'retrying ONCE' in read(name, 'stderr')
assert 'output too short' in read('agy-floor', 'stderr')
assert 'no labelled severity' in read('agy-evidence', 'stderr')
assert 'DISPATCH_REVIEW_STATE=clean original_rc=0' in read('agy-spoof', 'stdout')
assert 'DISPATCH_REVIEW_STATE=clean original_rc=8' in read('agy-spoof', 'stderr')
assert '| R1.1 | ALIGN |\n| E1 | OBJECT |\n| M1 | ABSTAIN |' in read('agy-rows', 'stdout')
assert 'CODING_DISPATCH_CHILD_ENV=fixture' in read('codex-child-env', 'stdout')
assert 'result 1' in read('codex-orphan', 'state')
tags = {r[0]: r for r in rows('goldens.tsv')[1:]}
for name in ('codex-child-env', 'codex-orphan'):
    assert tags['worker-'+name][1:3] == ['known-defect', 'README.md#worker-known-defects']
assert sum(int(r[3]) * (1 + int(r[4])) for r in tags.values()
           if r[0].startswith('worker-')) < 400

for name in ('row-align', 'row-object', 'row-abstain'):
    assert len(read('agy-'+name, 'stdout')) < 1200
assert 'DISPATCH_REVIEW_STATE=clean original_rc=0' in read('agy-spoof-valid', 'stderr')

assert read('agy-timeout', 'stdout').count('Minor: tracked.txt:1') == 2

assert 'MISSING promised dep' in read('codex-dep', 'stderr')
assert 'dep present: example.invalid/required' in read('codex-dep-pass', 'stderr')
assert read('pin-fail', 'argv') == ''
for runtime in ('codex', 'agy', 'claude'):
    call = read(runtime + '-review', 'call.' + runtime + ('.3' if runtime == 'agy' else '.1'))
    assert 'source-review-pinned 1' in call
    assert 'review-pinned 0' in read(runtime + '-review', 'state')
assert 'repository different-clone' in read('agy-review', 'call.agy.3')
assert 'repository source' in read('codex-review', 'call.codex.1')
assert read('env', 'state').endswith('worktree-directories\n')
