"""Exact inventory row accounting, with assertions against captured observations."""
import csv
from pathlib import Path
import sys

root = Path(sys.argv[1])
actual = Path(sys.argv[2]) if len(sys.argv) > 2 else None

def rows(name):
    with (root / name).open() as stream:
        return list(csv.reader(stream, delimiter='\t'))

inventory = {tuple(row) for row in rows('contract/inventory.tsv')
             if len(row) == 5 and row[0] in
             ('coding-dispatch.sh', 'coding-build-phase.sh')
             and row[1] in ('exit', 'line', 'flag', 'env')}
covered = rows('edit-coverage.tsv')
exempt = rows('edit-line-exemptions.tsv')
seen = set()
for row in covered + exempt:
    key = tuple(row[:5])
    assert key in inventory and key not in seen, f'stale/duplicate coverage: {row}'
    seen.add(key)
for row in exempt:
    assert len(row) == 6 and row[1] in ('line', 'flag', 'env') and row[5].strip(), row
for row in covered:
    assert len(row) == 7 and row[5].startswith('edit-'), row
    assert (root / 'scenarios' / row[5] / 'scenario.sh').is_file(), row
    if actual:
        output = actual / row[5]
        if row[6].startswith('rc='):
            assert (output / 'rc').read_text().strip() == row[6][3:], row
        else:
            text = (output / 'stdout').read_text() + (output / 'stderr').read_text()
            assert row[6] in text, f'missing output: {row}'
assert seen == inventory, f'uncovered inventory rows: {inventory - seen}'
# Inventory's exit 4 is extracted from the partial-runner signature, not an
# attainable dispatcher exit. edit-partial captures its actual refusal (2).

if actual:
    # Independently pin scenario intent, rather than blessing a misconfigured
    # fixture merely because both implementations produced identical bytes.
    expectations = {
        'empty-worktree': (1, 'empty diff'),
        'unavailable-worktree': (6, 'agent unavailable'),
        'signal-changes-worktree': (143, 'interrupted (signal)'),
        'timeout': (1, 'rc=124'),
        'exit124': (1, 'rc=124'),
        'committed-fail-worktree': (1, 'diff SALVAGED'),
        'committed-fail': (1, 'build/vet failed'),
        'keep-fail': (1, 'build/vet failed'),
        'rm-fail-worktree': (1, 'build/vet failed'),
        'base': (0, 'base_ref=main'),
        'stale-base': (2, 'is behind'),
        'allow-stale-base': (0, 'DISPATCH_BASE_STALE'),
        'mut-exempt': (0, 'override in effect: tracked.txt'),
        'agy': (0, 'agy model: fixture-model'),
        'noop-no-gate': (0, 'no build gate ran'),
        'noop-go': (0, 'go gate: build ./...'),
        'phase-build-fail': (1, 'PHASE=stopped-at:1'),
        'phase-task2-fail': (1, 'PHASE=stopped-at:2'),
        'phase-three': (0, '✓ Task 3 committed ('),
        'phase-dispatch-refused': (9, 'PHASE=refused:'),
        'ok': (0, 'DISPATCH=ok:'),
        'ok-worktree': (0, 'DISPATCH=ok worktree_ns='),
        'noop': (0, 'DISPATCH=ok-noop:'),
        'noop-worktree': (0, 'DISPATCH=ok-noop base_sha='),
        'noop-present': (0, 'DISPATCH=ok-noop:'),
        'noop-missing': (1, 'FM4: required file'),
        'noop-build': (1, 'build/vet failed'),
        'empty': (1, 'DISPATCH=fail: empty diff'),
        'build-fail': (1, 'build/vet failed'),
        'build-fail-worktree': (1, 'diff SALVAGED'),
        'scope': (1, 'scope gate: out-of-scope file changed: tracked.txt'),
        'newdir': (1, 'scope gate: out-of-scope file changed: new/'),
        'fm4': (1, 'FM4: required file'),
        'marker': (1, 'mutation marker'),
        'usage': (2, 'DISPATCH=error:'),
        'partial': (2, 'runs a partial gate'),
        'broken-install': (3, 'broken install:'),
        'unavailable': (6, 'agent unavailable'),
        'refused': (9, 'DISPATCH=refused:'),
        'signal': (143, 'interrupted (signal)'),
        'phase-ok': (0, 'PHASE=ok:'),
        'phase-worktree': (0, 'PHASE=ok worktree='),
        'phase-stopped': (1, 'PHASE=stopped-at:1'),
        'phase-blocked': (6, 'PHASE=blocked-unavailable:1'),
        'phase-refused': (9, 'PHASE=refused:'),
        'phase-usage': (2, 'must come AFTER the positionals'),
    }
    tags = {row[0]: row for row in rows('goldens.tsv')[1:]}
    for name, (rc, fragment) in expectations.items():
        scenario = 'edit-' + name
        directory = actual / scenario
        text = (directory / 'stdout').read_text() + (directory / 'stderr').read_text()
        assert (directory / 'rc').read_text().strip() == str(rc), scenario
        assert fragment in text, (scenario, fragment)
        if name in ('scope', 'marker', 'fm4', 'noop-missing', 'newdir'):
            assert text.count('DISPATCH=fail:') == 2, scenario
            stdout_count = 1 if name == 'marker' else 0
            assert (directory / 'stdout').read_text().count('DISPATCH=fail:') == stdout_count, scenario
            assert (directory / 'stderr').read_text().count('DISPATCH=fail:') == 2 - stdout_count, scenario
            assert tags[scenario][1] == 'known-defect', scenario
    assert tags['edit-newdir'][1:3] == ['known-defect', 'vinnyp/foundry#275']
    assert sum(int(row[3]) * (1 + int(row[4])) for row in tags.values()
               if row[0].startswith('edit-')) < 400

    # Failed in-place dispatches restore both HEAD and the index/worktree.
    for name in ('build-fail', 'committed-fail', 'scope', 'newdir', 'fm4',
                 'marker', 'noop-missing', 'noop-build', 'empty', 'timeout', 'exit124'):
        state = (actual / ('edit-' + name) / 'state').read_text()
        assert 'status\n\nresult 0' in state, (name, state)
        import re
        heads = re.findall(r'^HEAD ([0-9a-f]{40})$', state, re.M)
        assert len(set(heads)) == 1, (name, heads)
        if name == 'committed-fail':
            # The fixture's deterministic initial commit, shared with edit-empty.
            base = (actual / 'edit-empty' / 'state').read_text().splitlines()[0]
            assert state.splitlines()[0] == base, name
