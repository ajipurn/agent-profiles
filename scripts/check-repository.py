#!/usr/bin/env python3
"""Check tracked and publishable files without printing any matched secret values."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SECRET_PATTERNS = [
    re.compile(rb'gh[pousr]_[A-Za-z0-9]{30,}'),
    re.compile(rb'github_pat_[A-Za-z0-9_]{40,}'),
    re.compile(rb'sk-(?:proj-)?[A-Za-z0-9_-]{40,}'),
    re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
]


def forbidden_path(path):
    return (path.name == 'auth.json' or path.name.startswith('.env')
            or path.suffix in {'.p12', '.p8', '.pem', '.key'}
            or any(part in {'.local', 'xcuserdata'} for part in path.parts))


def main():
    files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT)
    failures = []
    for raw in set(files.split(b'\0')) - {b''}:
        relative = Path(raw.decode())
        path = ROOT / relative
        if forbidden_path(relative):
            failures.append(f'{relative}: credential or local-state file must not be published')
        elif path.is_file() and path.suffix not in {'.png', '.icns'}:
            data = path.read_bytes()
            if any(pattern.search(data) for pattern in SECRET_PATTERNS):
                failures.append(f'{relative}: possible secret detected (value omitted)')
    if failures:
        sys.exit('\n'.join(failures))
    print('Repository hygiene check passed')


if __name__ == '__main__':
    main()
