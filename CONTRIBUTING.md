# Contributing

Requires macOS 14+, Swift 6+ and Python 3. The Command Line Tools are enough for a build for your Mac; universal (arm64 + x86_64) builds need Xcode. `scripts/swift-env.sh` explains how the scripts build without Xcode.

## Checks

```sh
make build
make test
python3 -m unittest discover -s scripts/tests -v
python3 scripts/release_metadata.py check
python3 scripts/check-repository.py
make demo
```

Keep account tests isolated with the temporary homes and sample identities the test suites already use. Do not use real authentication tokens or profile folders in fixtures, logs, issues or screenshots; `make demo` gives safe screenshots.

## Pull requests

Use conventional commit prefixes such as `feat:`, `fix:`, `docs:` or `chore:`. Explain behavior changes and validation in the pull request. Keep the paths under [Compatibility with the old apps](#compatibility-with-the-old-apps) unchanged.

`Config/release.json` is the release metadata source. After changing it, run `python3 scripts/release_metadata.py sync`. The app icon is drawn by `scripts/make-icon.swift` (`make icon`).

The update signing key is not needed for development or pull-request checks. See [docs/RELEASING.md](docs/RELEASING.md).

## Layout

```
Sources/PlatformSupport/     paths, links, file modes per OS
Sources/CZstd/               vendored zstd, decompress only (BSD)
Sources/ClaudeProfilesCore/  Claude profiles and cached usage, no UI
Sources/CodexProfilesCore/   Codex accounts and usage API, no UI
Sources/ProvidersCore/       extra providers, Antigravity accounts, status pages, no UI
Sources/UsageCostCore/       cost estimate from local logs, no UI
Sources/UsageHistoryCore/    a month of usage readings for History, no UI
Sources/AgentCLI/            the agent-profiles command, no UI
Sources/AgentProfilesCLI/    its executable
Sources/AgentUI/             panel cards, bars, alerts, menu bar icon
Sources/CodexProfilesUI/     Codex model, settings pane, updater
Sources/AgentProfiles/       app shell, panel, Settings, Claude pane
Tests/                       Swift Testing suites, plus plain Codex checks
```

## Compatibility with the old apps

Agent Profiles replaces Claude Profiles and Codex Profiles. These must not change, or existing installs break:

- `~/Library/Application Support/Claude-Profiles/` stays where it is. The `Claude` symlink points into it, Claude Code ties each CLI profile's login to its folder path, and users' `~/.zshrc` puts `_cli/bin` on `PATH`.
- `~/Library/Application Support/CodexProfiles/` stays where it is.
- The `claudeprofiles://` URL scheme stays registered.
- Agent Profiles never runs at the same time as either old app (checked at launch).

The code was imported from [claude-profiles](https://github.com/ajipurn/claude-profiles)@0c934d9 and [codex-profiles](https://github.com/ajipurn/codex-profiles)@47210c3; earlier history stays in those repositories.
