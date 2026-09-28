#!/usr/bin/env python3
"""Check release URLs, bundle version, and update metadata before upload."""
import base64
from pathlib import Path
import plistlib
import sys
import subprocess
import tempfile
import zipfile
import xml.etree.ElementTree as ET
from release_metadata import ROOT, load_config, bundle_values


def validate(out, require_universal=False):
    config = load_config(require_key=True)
    version = config["version"]
    archive = out / f"AgentProfiles-{version}.zip"
    ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    items = ET.parse(out / "appcast.xml").getroot().findall("channel/item")
    assert len(items) == 1, "Expected exactly one current release"
    item = items[0]
    enclosure = item.find("enclosure")
    assert enclosure is not None, "Missing update archive"
    expected_url = f'https://github.com/{config["repository"]}/releases/download/v{version}/{archive.name}'
    assert enclosure.attrib["url"] == expected_url, "Wrong archive URL"
    assert int(enclosure.attrib["length"]) == archive.stat().st_size, "Wrong archive size"
    assert len(base64.b64decode(enclosure.attrib[f'{{{ns["sparkle"]}}}edSignature'], validate=True)) == 64
    assert item.findtext("sparkle:version", namespaces=ns) == str(config["build"]), "Wrong build number"
    assert item.findtext("sparkle:shortVersionString", namespaces=ns) == version, "Wrong release version"
    assert item.findtext("sparkle:minimumSystemVersion", namespaces=ns) == "14.0", "Wrong minimum OS"
    with zipfile.ZipFile(archive) as zipped:
        info = plistlib.loads(zipped.read("Agent Profiles.app/Contents/Info.plist"))
        if require_universal:
            with tempfile.TemporaryDirectory() as folder:
                executable = Path(folder, "AgentProfiles")
                executable.write_bytes(zipped.read("Agent Profiles.app/Contents/MacOS/AgentProfiles"))
                subprocess.run(["lipo", str(executable), "-verify_arch", "arm64", "x86_64"], check=True)
    for key, expected in bundle_values(config).items():
        assert info.get(key) == expected, f"Bundle metadata mismatch: {key}"
    print("Release URLs, archive length, version, minimum OS, and embedded update settings verified")


if __name__ == "__main__":
    validate(Path(sys.argv[1]), require_universal="--universal" in sys.argv[2:])
