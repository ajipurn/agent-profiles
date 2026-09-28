#!/usr/bin/env python3
"""Validate release metadata and keep SwiftPM and Xcode bundle metadata identical."""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parent.parent


def load_config(path=ROOT / "Config/release.json", require_key=False):
    config = json.loads(path.read_text())
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", config["version"]):
        raise ValueError("version must be a stable MAJOR.MINOR.PATCH version")
    if type(config["build"]) is not int or not 1 <= config["build"] <= 999999999:
        raise ValueError("build must be a positive, increasing integer")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+", config["repository"]):
        raise ValueError("repository must be a GitHub owner/repository")
    key = config["sparkle_public_key"]
    if key:
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError("Sparkle public key must encode 32 bytes")
    elif require_key:
        raise ValueError("Configure the Sparkle signing key before building a distributable release")
    return config


def bundle_values(config):
    return {
        "CFBundleExecutable": "AgentProfiles",
        "CFBundleIdentifier": "dev.aji.AgentProfiles",
        "CFBundleShortVersionString": config["version"],
        "CFBundleVersion": str(config["build"]),
        "LSMinimumSystemVersion": "14.0",
        "SUFeedURL": f'https://github.com/{config["repository"]}/releases/latest/download/appcast.xml',
        "SUPublicEDKey": config["sparkle_public_key"],
        "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": False,
        "SUScheduledCheckInterval": 86400,
        "SUEnableSystemProfiling": False,
        "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
        "CPRepositoryURL": f'https://github.com/{config["repository"]}',
        "NSAppleEventsUsageDescription": "Agent Profiles opens Terminal for Codex sign-in and can restart the ChatGPT app after switching accounts.",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "sync", "get"])
    parser.add_argument("field", nargs="?")
    parser.add_argument("--require-key", action="store_true")
    parser.add_argument("--tag")
    args = parser.parse_args()
    config = load_config(require_key=args.require_key)
    if args.tag and args.tag != "v" + config["version"]:
        raise ValueError("Release tag does not match Config/release.json")
    if args.command == "get":
        print(config[args.field])
        return
    path = ROOT / "Support/Info.plist"
    info = plistlib.loads(path.read_bytes())
    expected = bundle_values(config)
    if args.command == "sync":
        info.update(expected)
        path.write_bytes(plistlib.dumps(info, sort_keys=False))
        print("Updated Support/Info.plist")
    else:
        mismatched = [key for key, value in expected.items() if info.get(key) != value]
        if mismatched:
            raise ValueError("Run python3 scripts/release_metadata.py sync; mismatched keys: " + ", ".join(mismatched))
        print(f'Release metadata valid: {config["version"]} ({config["build"]})')


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError) as error:
        sys.exit(str(error))
