#!/usr/bin/env bash
# Read-only, silent refusal: never echo the sensitive match.
set -eu
[ "$#" -eq 1 ] || exit 1
python3 - "$1" <<'PY'
import os
import re
import sys
import pwd
import subprocess
from pathlib import Path

root = Path(sys.argv[1])
patterns = [
    rb'[A-Za-z0-9.!#$%&\x27*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
    rb'(?:sk-(?:proj-|ant-)?|gh[pousr]_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{16,}',
    rb'ya29\.[A-Za-z0-9_-]+', rb'AIza[A-Za-z0-9_-]{20,}',
    rb'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
    rb'AKIA[A-Z0-9]{16}', rb'-----BEGIN',
    rb'(?i)authorization[\"\x27]*:[ \t]*(?:Basic|Bearer)[A-Za-z0-9_./+=-]+',
    rb'(?i)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password)[\"\x27]*[=:][\s\"\x27]*[^\s\"\x27,}]+',
]
try:
    identities = [subprocess.check_output(['id', '-un']).strip(),
                  subprocess.check_output(['hostname']).strip(),
                  os.fsencode(pwd.getpwuid(os.getuid()).pw_dir)]
except (OSError, KeyError, subprocess.SubprocessError):
    sys.exit(1)
identities += [os.fsencode(os.environ[k]) for k in ('HOME', 'USER', 'LOGNAME')
               if os.environ.get(k)]
def compact(value):
    return re.sub(rb'[\s\\]+', b'', value)
private = [compact(value) for value in identities if len(value) >= 3]
try:
    if not root.is_dir() or root.is_symlink():
        sys.exit(1)
    for directory, dirs, files in os.walk(root, onerror=lambda error: sys.exit(1)):
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
            joined = compact(data)
            if any(value in data or value in joined for value in private):
                sys.exit(1)
            if any(re.search(pattern, value) for pattern in patterns
                   for value in (data, joined)):
                sys.exit(1)
except OSError:
    sys.exit(1)
PY
