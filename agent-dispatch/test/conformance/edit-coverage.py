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
             and row[1] in ('exit', 'line')}
covered = rows('edit-coverage.tsv')
exempt = rows('edit-line-exemptions.tsv')
seen = set()
for row in covered + exempt:
    key = tuple(row[:5])
    assert key in inventory and key not in seen, f'stale/duplicate coverage: {row}'
    seen.add(key)
for row in exempt:
    assert len(row) == 6 and row[1] == 'line' and row[5].strip(), row
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
        if name in ('scope', 'marker', 'fm4', 'noop-missing'):
            assert text.count('DISPATCH=fail:') == 2, scenario
            assert tags[scenario][1:3] == ['known-defect', 'cutover-change-12'], scenario
    assert tags['edit-newdir'][1:3] == ['known-defect', 'vinnyp/foundry#275']
    assert sum(int(row[3]) * (1 + int(row[4])) for row in tags.values()
               if row[0].startswith('edit-')) < 420
