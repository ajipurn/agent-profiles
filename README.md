# Agent Profiles

<img src="docs/icon.png" width="128" alt="Agent Profiles icon">

A macOS menu bar app for switching Claude and Codex accounts and keeping an
eye on their usage limits. It merges
[Claude Profiles](https://github.com/ajipurn/claude-profiles) and
[Codex Profiles](https://github.com/ajipurn/codex-profiles) into one app.

Requires macOS 14 or later, on Apple Silicon or Intel.

Independently developed. Not affiliated with or endorsed by Anthropic or OpenAI.

## Install

1. Download `AgentProfiles-<version>.zip` from [Releases](https://github.com/ajipurn/agent-profiles/releases/latest).
2. Unzip it and move **Agent Profiles.app** to **Applications**.
3. Quit Claude Profiles and Codex Profiles if you use them; Agent Profiles picks up their profiles and accounts as they are.
4. Open Agent Profiles and click its icon in the menu bar.

Releases are ad-hoc signed and **not Apple-notarized**, so macOS blocks the first launch. After checking where the download came from, use **Open Anyway** in **System Settings → Privacy & Security**. Later updates are verified by Sparkle's own signatures.

## Try it

```sh
make test   # Codex checks + Claude core tests
make demo   # preview mode: sample accounts in temporary folders
make run    # real mode: manages your actual accounts
```

Preview mode (`--demo`) keeps its sample accounts in temporary folders and never
quits or relaunches Claude or ChatGPT, so it is safe to run next to the old
apps. It also opens Settings right away.

Real mode works on the same files as the old apps. If Claude Profiles or Codex
Profiles is running, it asks to quit them first and does not start otherwise.

## What it looks like

The menu follows [CodexBar](https://github.com/steipete/CodexBar)'s design:

- **Menu bar:** a two-bar icon, with the session window on top and the weekly
  window below, plus the session percentage. It shows the provider picked in
  Settings → General (Claude or Codex).
- **Menu (either click):** Claude | Codex tabs, the selected provider's card
  (account, freshness, Session and Weekly bars with reset countdowns), the
  other accounts to switch to, and actions. Claude also gets a Claude Code
  profile submenu once CLI profiles are set up.
- **Settings window:** General (menu bar, launch at login, updates), Claude
  (profiles, Desktop and CLI switching, rename, delete, order, shared session
  history, CLI setup), Codex (accounts, favorites, rename, remove, sign-in,
  options), About.

Everything both old apps did is still there.

The app icon, two switches offset like ⇄ in Claude's orange and Codex's teal,
is drawn in code: `swift scripts/make-icon.swift` regenerates
`Resources/AppIcon.icns` and `docs/icon.png`.

## Existing logins

No sign-in step for sessions that are already on the Mac:

- **Codex:** a login in `~/.codex/auth.json` that no saved account matches is
  saved automatically, named after its email. Removing the active account
  in Settings keeps it from being saved again.
- **Claude:** if Claude is signed in but profiles were never set up, the
  current login becomes the first profile ("main") on its own, but only
  while Claude.app is quit, so nothing restarts. With Claude running, use
  Set Up Profiles… in the menu.

## Shortcuts and scripting

- **⌘⌥1…9:** switch to the Nth Claude profile, in the order set in Settings.
- **⌃⌥1…9:** switch to the Nth Codex account, favorites first, then by name.
- **URLs** (Raycast, Alfred, shell):

  | URL | Does |
  | --- | --- |
  | `agentprofiles://claude/<name>` | switches Claude Desktop |
  | `agentprofiles://claude-cli/<name>` | switches the Claude Code profile (`Default` = plain `~/.claude`) |
  | `agentprofiles://codex/<name>` | switches Codex (saved name, label or email) |
  | `agentprofiles://open[/<pane>]` | opens Settings (`general`, `claude`, `codex`, `about`) |

  Claude Profiles' `claudeprofiles://switch|switch-cli|open` still work.
- **Notifications:** a switch started from the menu, a hotkey or a URL
  reports when it is done. When the active account of either provider drops
  to 10% of its session window, a notification suggests the account with
  the most left; clicking it switches.

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
Sources/AgentUI/                menu card, bars, switcher, menu bar icon (shared)
Sources/CodexProfilesUI/        Codex model, settings pane, updater    ← codex-profiles
Sources/AgentProfiles/          app shell, menu, Settings, Claude pane ← claude-profiles
Tests/ClaudeProfilesCoreTests/  Swift Testing (ported from XCTest)
Tests/CodexProfilesCheck/       plain executable checks
```

The code was imported from codex-profiles@47210c3 and claude-profiles@0c934d9.
The first commit holds it unchanged; the second holds the changes for the
merge. Earlier history stays in the original repositories.

Every target builds in Swift 6 language mode (strict concurrency).

## Building without Xcode

The scripts need only the Command Line Tools. They use SwiftPM's native build
system and, when the default SDK is macOS 27, build against the macOS 26 SDK.
`scripts/swift-env.sh` explains why. Set `SDKROOT` or `SWIFT_BUILD_SYSTEM` to
override.

## Next

- A last release of Claude Profiles and Codex Profiles that points their users
  here.

See [Privacy](PRIVACY.md), [Security](SECURITY.md), [Contributing](CONTRIBUTING.md) and the [release guide](docs/RELEASING.md).

## License

[MIT](LICENSE). Bundled dependencies keep their own
[licenses and notices](THIRD_PARTY_NOTICES.md).
