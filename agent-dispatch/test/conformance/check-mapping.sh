#!/usr/bin/env bash
# Census content remains external. Test refs are plugin-relative path#case-name.
# A case name must be a literal quoted label, shell case label, or '# case: name'.
set -eu
here=$(CDPATH='' cd "$(dirname "$0")" && pwd -P)
python3 - "$here" "$@" <<'PY'
import csv
import re
import sys
from pathlib import Path

here = Path(sys.argv[1]).resolve()
root = here.parent.parent
unmapped = 0
errors = []


def safe_path(base, value):
    path = Path(value)
    if path.is_absolute() or '..' in path.parts or not value:
        raise ValueError('invalid reference path')
    resolved = (base / path).resolve()
    if base != resolved and base not in resolved.parents:
        raise ValueError('reference escapes its root')
    return resolved


def valid_ref(kind, ref):
    if kind == 'scenario':
        return safe_path(here / 'scenarios', ref).is_dir()
    if kind == 'test':
        filename, separator, name = ref.partition('#')
        if not separator or not name or not filename.endswith('.sh'):
            return False
        path = safe_path(root, filename)
        if not path.is_file():
            return False
        source = path.read_text()
        # Match full labels, never an arbitrary prose substring.
        label = re.escape(name)
        return bool(re.search(r"(['\"])" + label + r"\1", source) or
                    re.search(r'^\s*#\s*case:\s*' + label + r'\s*$', source, re.M) or
                    re.search(r'^\s*' + label + r'\)', source, re.M))
    if kind == 'smoke':
        source = (here / 'live-smoke.sh').read_text()
        return bool(re.search(r'^probe\s+' + re.escape(ref) + r'\s', source, re.M))
    return False


try:
    args = sys.argv[2:]
    if not args:
        raise ValueError('usage: check-mapping.sh <census.csv> [--extra <ids>]')
    census = args.pop(0)
    extras = set()
    while args:
        if len(args) < 2 or args.pop(0) != '--extra':
            raise ValueError('expected --extra <comma-separated ids>')
        ids = re.split(r'[,\s]+', args.pop(0).strip())
        if not all(ids):
            raise ValueError('empty extra id')
        extras.update(ids)
    selected = set(extras)
    with open(census, newline='', encoding='utf-8-sig') as stream:
        reader = csv.DictReader(stream)
        required = {'id', 'scope', 'encodes_environmental_knowledge'}
        if not required.issubset(reader.fieldnames or []):
            raise ValueError('census requires id, scope, encodes_environmental_knowledge')
        for row in reader:
            if row['scope'] == 'in' and row['encodes_environmental_knowledge'] == 'Y':
                if not row['id']:
                    raise ValueError('empty census id')
                selected.add(row['id'])
    unmapped = len(selected)
    mapped = set()
    with (here / 'targets.tsv').open(newline='', encoding='utf-8') as stream:
        reader = csv.DictReader(stream, delimiter='\t')
        if reader.fieldnames != ['census_id', 'kind', 'ref', 'how']:
            raise ValueError('invalid targets header')
        for number, row in enumerate(reader, 2):
            if (not row['census_id'] or None in row or
                    any(v is None for v in row.values()) or not row['how'].strip()):
                errors.append('invalid target row {}'.format(number))
                continue
            mapped.add(row['census_id'])
            try:
                valid = valid_ref(row['kind'], row['ref'])
            except (ValueError, OSError):
                valid = False
            if not valid:
                errors.append('invalid target reference at row {}'.format(number))
    unmapped = len(selected - mapped)
except (ValueError, OSError, csv.Error) as error:
    # Do not echo external census text or its private path.
    errors.append('mapping input invalid ({})'.format(type(error).__name__))
finally:
    print('unmapped targets: {}'.format(unmapped))
for error in errors:
    print(error, file=sys.stderr)
sys.exit(1 if errors or unmapped else 0)
PY
