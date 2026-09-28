#!/usr/bin/env python3
"""Prevent publishing an older version or a reused Sparkle build number."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from release_metadata import load_config


def version_tuple(tag):
    if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
        raise ValueError('Unexpected stable release tag: ' + tag)
    return tuple(map(int, tag[1:].split('.')))


def main():
    config = load_config(require_key=True)
    repository = config['repository']
    releases = json.loads(subprocess.check_output([
        'gh', 'release', 'list', '--repo', repository, '--limit', '100',
        '--json', 'tagName,isDraft,isPrerelease',
    ]))
    stable = [r for r in releases if not r['isDraft'] and not r['isPrerelease']]
    if not stable:
        print('No published stable release yet; preparing the first release')
        return
    newest = max(stable, key=lambda r: version_tuple(r['tagName']))
    if version_tuple('v' + config['version']) <= version_tuple(newest['tagName']):
        raise ValueError('Version must be newer than the published stable release')
    with tempfile.TemporaryDirectory() as folder:
        subprocess.run(['gh', 'release', 'download', newest['tagName'], '--repo', repository,
                        '--pattern', 'appcast.xml', '--dir', folder], check=True)
        ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
        feed = ET.parse(Path(folder, 'appcast.xml'))
        previous = [int(item.findtext('sparkle:version', namespaces=ns)) for item in feed.findall('channel/item')]
        if not previous or config['build'] <= max(previous):
            raise ValueError('Sparkle build number must increase for every release')
    print('Release version and Sparkle build number both increase')


if __name__ == '__main__':
    main()
