# Agent Profiles

A macOS menu bar app for switching Claude and Codex accounts and keeping an
eye on their usage limits. It merges
[Claude Profiles](https://github.com/ajipurn/claude-profiles) and
[Codex Profiles](https://github.com/ajipurn/codex-profiles) into one app.

**Status: phase 1, unreleased.** Everything both apps do works side by side in
one app. The shared design, the release pipeline and the move for existing
users come next.

Independently developed. Not affiliated with or endorsed by Anthropic or OpenAI.

## Try it

```sh
make test   # Codex checks + Claude core tests
make demo   # preview mode: sample accounts in temporary folders
make run    # real mode: manages your actual accounts
```

Preview mode (`--demo`) keeps its sample accounts in temporary folders and never
quits or relaunches Claude or ChatGPT, so it is safe to run next to the old
apps. It also opens the panel as a window.

Real mode works on the same files as the old apps. If Claude Profiles or Codex
Profiles is running, it asks to quit them first and does not start otherwise.

## What's in phase 1

- **Left-click:** popover with a **Claude | Codex** switch. Each side is that
  app's own panel, unchanged apart from names.
- **Right-click:** quick-switch menu with both providers' accounts.
- **Menu bar:** the Claude gauge while Claude profiles are set up; otherwise
  the Codex one, if its "Show 5-hour remaining quota in menu bar" setting is
  on. The tooltip covers both.
- **From Claude Profiles:** Desktop and CLI profiles, shared session history,
  low-limit alerts, ⌘⌥1…9 hotkeys, `claudeprofiles://` URLs, the window view,
  launch at login.
- **From Codex Profiles:** switching through `~/.codex/auth.json`, sign-in in
  Terminal, usage refresh, search, favorites, sorting.
- **One Sparkle updater** for both, inactive until the release pipeline adds a
  feed and signing key.

The app and menu bar icons are Codex Profiles' for now.

## Compatibility with the old apps

These must not change, or existing installs break:

- `~/Library/Application Support/Claude-Profiles/` stays where it is. The
  `Claude` symlink points into it, Claude Code ties each CLI profile's login to
  its folder path, and users' `~/.zshrc` puts `_cli/bin` on `PATH`.
- `~/Library/Application Support/CodexProfiles/` stays where it is.
- The `claudeprofiles://` URL scheme stays registered.
- Agent Profiles never runs at the same time as either old app (checked at
  launch).

## Layout

```
Sources/CZstd/                  vendored zstd, decompress only (BSD)   ← claude-profiles
Sources/ClaudeProfilesCore/     Claude profile logic, no UI            ← claude-profiles
Sources/CodexProfilesCore/      Codex profile logic, no UI             ← codex-profiles
Sources/CodexProfilesUI/        Codex panel, model and updater         ← codex-profiles
Sources/AgentProfiles/          app shell and the Claude screens       ← claude-profiles
Tests/ClaudeProfilesCoreTests/  Swift Testing (ported from XCTest)
Tests/CodexProfilesCheck/       plain executable checks
```

The code was imported from codex-profiles@47210c3 and claude-profiles@0c934d9.
The first commit holds it unchanged; the second holds the changes for the
merge. Earlier history stays in the original repositories.

`ClaudeProfilesCore` and the app shell still build in Swift 5 mode. The Codex
modules keep Swift 6 strict concurrency.

## Building without Xcode

The scripts need only the Command Line Tools. They use SwiftPM's native build
system and, when the default SDK is macOS 27, build against the macOS 26 SDK.
`scripts/swift-env.sh` explains why. Set `SDKROOT` or `SWIFT_BUILD_SYSTEM` to
override.

## Next

- **Phase 2:** one design for both panels, a menu bar readout that covers both
  providers, Codex in the hotkeys, URL scheme and notifications, and the Claude
  code moved to Swift 6.
- **Phase 3:** release pipeline (universal build, Sparkle key and feed), plus a
  last release of each old app that points its users here.

## License

[MIT](LICENSE). Bundled dependencies keep their own
[licenses and notices](THIRD_PARTY_NOTICES.md).
