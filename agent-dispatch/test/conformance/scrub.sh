#!/usr/bin/env bash
# Read-only, silent refusal: never echo the sensitive match.
set -eu
[ "$#" -eq 1 ] || exit 1
python3 - "$1" <<'PY'
import os
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
patterns = [
    rb'[A-Za-z0-9.!#$%&\x27*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
    rb'(?:sk-(?:proj-|ant-)?|gh[pousr]_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{16,}',
    rb'AKIA[A-Z0-9]{16}',
    rb'-----BEGIN(?: RSA| OPENSSH| EC)? PRIVATE KEY-----',
    rb'(?i)(?:api[_-]?key|access[_-]?token|authorization)[=:][\s"\x27]*(?:Bearer\s+)?[A-Za-z0-9_./+-]{16,}',
]
private = [os.fsencode(os.environ[k]) for k in ('HOME', 'USER', 'LOGNAME')
           if os.environ.get(k)]
try:
    if not root.is_dir() or root.is_symlink():
        sys.exit(1)
    for directory, dirs, files in os.walk(root):
        for name in dirs + files:
            path = Path(directory) / name
            if path.is_symlink():
                sys.exit(1)
            if path.is_dir():
                continue
            if not path.is_file():
                sys.exit(1)
            data = path.read_bytes()
            # Join line wraps before token detection, including CRLF and indent.
            joined = re.sub(rb'\r?\n[ \t]*', b'', data)
            if any(value in data or value in joined for value in private):
                sys.exit(1)
            if any(re.search(pattern, value) for pattern in patterns
                   for value in (data, joined)):
                sys.exit(1)
except OSError:
    sys.exit(1)
PY
