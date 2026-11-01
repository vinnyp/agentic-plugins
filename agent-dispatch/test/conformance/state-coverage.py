"""Exact inventory accounting plus assertions independent of baseline output."""
import csv
from pathlib import Path
import sys

root = Path(sys.argv[1])
actual = Path(sys.argv[2]) if len(sys.argv) > 2 else None
commands = {'review-pin.sh', 'review-clone.sh', 'repo-state-check',
            'run-long-gate.sh', 'gate-run.sh'}


def rows(name):
    with (root / name).open() as stream:
        return list(csv.reader(stream, delimiter='\t'))


inventory = {tuple(r) for r in rows('contract/inventory.tsv')
             if len(r) == 5 and r[0] in commands
             and r[1] in ('exit', 'line', 'flag', 'env')}
seen = set()
covered = rows('state-coverage.tsv')
for row in covered + rows('state-exemptions.tsv'):
    key = tuple(row[:5])
    assert key in inventory and key not in seen, f'stale/duplicate coverage: {row}'
    seen.add(key)
    if len(row) == 6:
        assert row[5].strip(), row
    else:
        assert len(row) == 7 and row[5].startswith('state-'), row
        assert (root / 'scenarios' / row[5] / 'scenario.sh').is_file(), row
        if actual:
            file, fragment = row[6].split(':', 1)
            assert fragment in (actual / row[5] / file).read_text(), row
assert seen == inventory, f'uncovered inventory rows: {inventory - seen}'
tags = {r[0]: r for r in rows('goldens.tsv')[1:] if r[0].startswith('state-')}
assert sum(int(r[3]) * (1 + int(r[4])) for r in tags.values()) < 400
for name in ('filter', 'socket', 'deleted', 'truncated'):
    assert tags['state-compare-'+name][1:3] == [
        'known-defect', 'README.md#state-known-defects'], name
if not actual:
    sys.exit(0)
assert set(tags) == {p.name for p in actual.iterdir() if p.is_dir()}
for name in tags:
    directory = actual / name
    expected = {
        'state-clone-nonempty': '3', 'state-clone-mode': '3',
        'state-clone-source': '3',
        'state-compare-alternates': '2', 'state-compare-grafts': '2',
        'state-compare-shallow': '2', 'state-compare-exclude': '1',
        'state-clone-filter': '4', 'state-clone-unsafe': '3',
        'state-compare-config': '2', 'state-compare-hook': '2',
        'state-compare-ref': '2', 'state-compare-filter': '2',
        'state-compare-socket': '2', 'state-compare-deleted': '3',
        'state-compare-truncated': '3', 'state-gate-fail': '7',
        'state-gate-moved': '2', 'state-long-missing': '2',
        'state-long-symlink': '2',
        'state-pin-block': '1', 'state-pin-duplicate': '1',
        'state-pin-stale': '1', 'state-pin-invalid': '2',
    }.get(name, '0')
    assert (directory / 'rc').read_text().strip() == expected, name
    assert not (directory / 'argv').read_text(), f'real/runtime call in {name}'
    assert 'Traceback' not in (directory / 'stderr').read_text(), name


def output(name):
    return (actual / ('state-' + name) / 'stdout').read_text()


for name, code in [('clean', 0), ('harmless', 0), ('config', 2), ('hook', 2),
                   ('ref', 2), ('deleted', 3), ('truncated', 3), ('filter', 2),
                   ('socket', 2)]:
    assert f'observed_rc={code}\n' in output('compare-'+name), name
for name, fragment in [('config', 'config fixture.changed'), ('hook', 'hooks pre-commit: added'),
                       ('ref', 'ref refs/replace/'), ('socket', 'nonregular'),
                       ('deleted', 'unreadable before snapshot'),
                       ('truncated', 'invalid before snapshot')]:
    assert fragment in output('compare-'+name), name
assert 'filter executed before comparison' in output('compare-filter')
assert 'observed_rc=9\n' in output('pin-block')
assert 'pinned edit unchanged; no runtime invoked' in output('pin-block')
assert 'stale age=2\nobserved_rc=1' in output('pin-stale')
assert 'stale marker removed' in output('pin-stale')
assert 'observed_rc=2' in output('pin-duplicate')
assert 'clone removed; source retained' in output('clone-isolation')
assert 'source content config refs isolated; no alternates' in output('clone-isolation')
for name, code in [('filter', 4), ('unsafe', 3)]:
    assert f'observed_rc={code}' in output('clone-'+name)
for name, code in [('pass', 0), ('fail', 7), ('moved', 2)]:
    assert f'observed_rc={code}' in output('gate-'+name)
assert 'venv fixture' in output('gate-venv') and 'Python fixture' in output('gate-venv')
for name, code in [('pass', 0), ('fail', 7)]:
    assert f'GATE_EXIT={code}' in output('long-'+name)
    assert f'observed_rc={code}' in output('long-'+name)
assert 'observed_rc=2' in output('long-symlink')
assert 'observed_rc=2' in output('long-missing')

assert 'observed_rc=3' in output('long-pending')
assert 'observed_rc=124' in output('long-pending')
assert 'observed_rc=2' in output('pin-invalid')

# These metadata paths are critical even when ordinary info files are benign.
for name in ('alternates', 'grafts', 'shallow'):
    assert 'observed_rc=2\n' in output('compare-' + name), name
    assert name in output('compare-' + name), name
assert 'observed_rc=1\n' in output('compare-exclude')
for name, reason in [('nonempty', 'destination is not empty'),
                     ('mode', 'destination mode is not 700'),
                     ('source', 'source is not a work tree')]:
    directory = actual / ('state-clone-' + name)
    assert 'observed_rc=3\n' in output('clone-' + name), name
    assert 'review-clone: ' + reason in (directory / 'stderr').read_text(), name
