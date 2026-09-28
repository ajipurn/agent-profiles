#!/usr/bin/env python3
"""Prepare, build, verify and publish a release; rerun with VERSION to resume."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.request

from release_metadata import ROOT, load_config


def run(*args, capture=False):
    return subprocess.check_output(args, text=True).strip() if capture else subprocess.run(args, check=True)


def next_version(current, requested, bump=''):
    if bump and requested:
        raise ValueError('Use either BUMP or VERSION, not both.')
    if bump not in ('', 'major', 'minor', 'patch'):
        raise ValueError('BUMP must be major, minor, or patch.')
    parts = list(map(int, current.split('.')))
    index = {'major': 0, 'minor': 1, 'patch': 2}[bump or 'patch']
    parts[index] += 1
    for trailing in range(index + 1, 3):
        parts[trailing] = 0
    version = requested or '.'.join(map(str, parts))
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('VERSION must be MAJOR.MINOR.PATCH')
    if tuple(map(int, version.split('.'))) < tuple(map(int, current.split('.'))):
        raise ValueError('VERSION cannot be older than the current version')
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='')
    parser.add_argument('--bump', default='', choices=['', 'major', 'minor', 'patch'])
    args = parser.parse_args()
    os.chdir(ROOT)
    if run('git', 'status', '--porcelain', capture=True):
        raise ValueError('Commit your changes first, then run make release again.')
    if run('git', 'branch', '--show-current', capture=True) != 'main':
        raise ValueError('Release must run from main.')
    config = load_config(require_key=True)
    repo = config['repository']
    remote = run('git', 'remote', 'get-url', 'origin', capture=True)
    if remote not in (f'https://github.com/{repo}', f'https://github.com/{repo}.git', f'git@github.com:{repo}.git'):
        raise ValueError('origin must match the configured GitHub repository.')
    run('gh', 'auth', 'status')
    run('git', 'fetch', 'origin', 'main', '--tags')
    run('git', 'merge-base', '--is-ancestor', 'origin/main', 'HEAD')
    version = next_version(config['version'], args.version, args.bump)
    tag = 'v' + version
    print(f'Releasing {tag}. To resume after a failure: make release VERSION={version}', flush=True)
    if version != config['version']:
        if run('git', 'tag', '--list', tag, capture=True):
            raise ValueError('Tag already exists; choose a newer version.')
        notes = ROOT / f'docs/releases/{version}.md'
        changes = run('git', 'log', f'v{config["version"]}..HEAD', '--format=- %s', capture=True)
        notes_text = f'# Agent Profiles {version}\n\n{changes or "- Maintenance update."}\n'
        if not notes.exists():
            notes.write_text(notes_text)
        changelog = ROOT / 'CHANGELOG.md'
        changelog.write_text(changelog.read_text().replace('# Changelog\n', f'# Changelog\n\n## {version}\n\n' + notes.read_text().split('\n', 1)[-1].strip() + '\n', 1))
        config.update(version=version, build=config['build'] + 1)
        (ROOT / 'Config/release.json').write_text(json.dumps(config, indent=2) + '\n')
        run('python3', 'scripts/release_metadata.py', 'sync')
    run('python3', 'scripts/release_metadata.py', 'check', '--require-key')
    run('python3', 'scripts/check-release-history.py')
    run('python3', 'scripts/check-repository.py')
    run('python3', '-m', 'unittest', 'discover', '-s', 'scripts/tests', '-v')
    run('make', 'test')
    run('git', 'diff', '--check')
    run('git', 'add', 'Config/release.json', 'Support/Info.plist', 'CHANGELOG.md', f'docs/releases/{version}.md')
    if run('git', 'diff', '--cached', '--name-only', capture=True):
        run('git', 'commit', '-m', f'chore: prepare release {version}')
    head = run('git', 'rev-parse', 'HEAD', capture=True)
    if run('git', 'tag', '--list', tag, capture=True):
        if run('git', 'rev-parse', f'{tag}^{{commit}}', capture=True) != head:
            raise ValueError('Existing tag does not match HEAD; do not move release tags.')
    else:
        run('git', 'tag', '-a', tag, '-m', f'Release {version}')
    run('git', 'push', '--atomic', 'origin', 'main', f'refs/tags/{tag}')
    deadline = time.monotonic() + 300
    while True:
        runs = json.loads(run('gh', 'run', 'list', '--repo', repo, '--workflow', 'release.yml', '--commit', head, '--json', 'databaseId,headBranch', capture=True))
        matching = [r for r in runs if r['headBranch'] == tag]
        if matching:
            break
        if time.monotonic() > deadline:
            raise ValueError('Workflow did not start. Inspect GitHub Actions, then resume with VERSION.')
        time.sleep(5)
    run('gh', 'run', 'watch', str(matching[0]['databaseId']), '--repo', repo, '--exit-status')
    with tempfile.TemporaryDirectory() as folder:
        run('gh', 'release', 'download', tag, '--repo', repo, '--dir', folder)
        run('python3', 'scripts/validate_artifacts.py', folder, '--universal')
        run('swift', 'scripts/verify-update.swift', f'{folder}/appcast.xml', f'{folder}/AgentProfiles-{version}.zip', config['sparkle_public_key'])
        run('gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--latest')
        with urllib.request.urlopen(f'https://github.com/{repo}/releases/latest/download/appcast.xml', timeout=30) as response:
            if response.read() != Path(folder, 'appcast.xml').read_bytes():
                raise ValueError('Published feed does not match the verified feed.')
    print(f'Published https://github.com/{repo}/releases/tag/{tag}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
