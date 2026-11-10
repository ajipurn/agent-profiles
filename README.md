<div align="center">

<img src="docs/icon.png" width="112" alt="Agent Profiles icon: two usage meters, orange over blue">

# Agent Profiles

**Switch Claude, Codex and Antigravity accounts and watch every AI coding
tool's usage limits from the macOS menu bar.**

[![Latest release](https://img.shields.io/github/v/release/ajipurn/agent-profiles?label=release)](https://github.com/ajipurn/agent-profiles/releases/latest)
[![CI](https://github.com/ajipurn/agent-profiles/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ajipurn/agent-profiles/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#requirements)
[![License: MIT](https://img.shields.io/github/license/ajipurn/agent-profiles)](LICENSE)

[Download](https://github.com/ajipurn/agent-profiles/releases/latest) ·
[Features](#features) ·
[Install](#installation) ·
[Usage](#usage) ·
[Changelog](CHANGELOG.md) ·
[Privacy](PRIVACY.md)

<img src="docs/screenshot.png" width="340" alt="Agent Profiles panel: estimated cost ring with 30-day history, provider tabs, Session and Weekly bars with pace, accounts to switch to with their 5-hour and weekly meters, and actions">

</div>

## Contents

- [Why Agent Profiles](#why-agent-profiles)
- [Features](#features)
- [Supported providers](#supported-providers)
- [Installation](#installation)
- [Getting started](#getting-started)
- [Usage](#usage)
- [Privacy and security](#privacy-and-security)
- [FAQ](#faq)
- [Building from source](#building-from-source)
- [Contributing](#contributing)
- [Acknowledgements](#acknowledgements)
- [License](#license)

## Why Agent Profiles

If you have more than one Claude, Codex or Antigravity account, switching
means signing out and in again, and you never quite know which account still
has room. Agent Profiles keeps every account signed in, shows how much each
one has left, and switches with one click. It also shows the limits of your
other AI coding tools, so you see everything in one panel.

## Features

### Accounts

- **One-click switching** for Claude Desktop, Claude Code (CLI), Codex and
  Antigravity, including `agy`.
- **Every account at a glance.** Each row shows its 5-hour and weekly
  windows side by side with their resets, sorted by what is left, with the
  best one marked.
- **Existing logins are picked up on their own.** Settings handles naming,
  ordering, favorites, removal and sign-in.
- **Add Antigravity accounts** without signing out: *Add Account* opens
  Antigravity signed out so you can sign in with another Google account, and
  it is saved as soon as you're in.

### Usage

- **Session (5-hour) and weekly limits** with reset countdowns, plus whatever
  else the account has: Claude's per-model weekly limits and extra usage
  spend, Codex Spark windows, credits, workspace credit limits and limit
  resets.
- **Pace.** A bar turns yellow when the current burn rate would leave less
  than 10% at the reset, and red, with the projected run-out time, when it
  would run out first. A tick marks where an even burn would be.
- **Your units.** Click a percentage to switch between *left* and *used*, or
  a reset to switch between a countdown and a clock time.
- **Incidents** from each provider's status page show on its card and tab.

### Cost

- **Estimated spend** for today, yesterday and the last 30 days from local
  Claude Code and Codex logs, priced at API list rates from a bundled
  [LiteLLM](https://github.com/BerriAI/litellm) snapshot.
- **Daily chart** with the most expensive models; hover a day for its
  breakdown.

### History

- **Settings → History** shows how each account's session or weekly limit
  filled over the last 7 or 30 days, with each account's latest, peak and how
  often it reached 100%.

### Notifications

- **Low usage** at a warning and a critical level you choose (25% and 10%
  left by default), and when a limit is used up. A critical Claude or Codex
  alert suggests the account with the most left; clicking it switches.
- **Ahead of time:** "will run out before it resets", "a used-up limit has
  reset" and, if you turn it on, "weekly limit resets tomorrow with most of it
  unused".
- Each fires once per window, at the deepest level reached.

### More providers

- **Gemini, Antigravity, Cursor, GitHub Copilot, OpenCode, Kiro and Grok**,
  each turned on in Settings → More Providers. An Overview tab then lists
  every provider, closest to running out first.

  <img src="docs/overview.png" width="300" alt="Overview tab: every provider with its two main limits, closest to running out first">

### Menu bar

- **A two-bar icon**: the session window on top, the weekly one below, with
  the session, weekly or lower percentage beside it. It follows the frontmost
  Claude, Codex or Antigravity app, or the provider you pick in Settings.
- **Share safely.** *Copy Image* puts the current card on the clipboard with
  email addresses masked; the eye button masks them in the panel too.

## Supported providers

| Provider | Switch accounts | What it shows | Where the numbers come from |
| --- | :---: | --- | --- |
| Claude | ✓ | Session, weekly, per-model weekly, extra usage | Claude Desktop's own cached usage response, read from disk. No token is read and no request is made. |
| Codex | ✓ | Session, weekly, Spark, credits, credit limit, limit resets | ChatGPT's usage API, with each saved account's login. |
| Antigravity | ✓ | Weekly and 5-hour limits per model group, as Antigravity's Usage view shows them | The running Antigravity app's own quota summary when it is open; otherwise Google's Cloud Code API, with the sign-in the app and `agy` share. |
| Gemini | | Pro, Flash and Flash Lite quotas, plan | Gemini CLI's sign-in and Google's Code Assist quota API. Workspace and Code Assist Standard/Enterprise accounts only; Google moved individual and AI Pro/Ultra accounts to Antigravity in June 2026. |
| Cursor | | Plan usage, on-demand spend | The Cursor app's or `cursor-agent`'s sign-in and cursor.com's dashboard API. |
| GitHub Copilot | | Premium requests, chat, completions | The GitHub token the JetBrains, Vim and Xcode plugins or the Copilot CLI keep in plain text. |
| OpenCode | | Go plan session, weekly and monthly | OpenCode's own sign-in or `OPENCODE_API_KEY`. |
| Kiro | | Credits and overage | kiro-cli's sign-in. |
| Grok | | Weekly or monthly credits, on-demand balance | Grok CLI's sign-in. |

Providers other than Claude and Codex are off until you turn them on. They
only read the sign-in their own tool keeps on this Mac; tokens refreshed for a
request stay in memory. Only switching Antigravity accounts writes its
sign-in.

## Installation

### Requirements

- macOS 14 Sonoma or later, Apple Silicon or Intel.

### Download

1. Download `AgentProfiles-<version>.zip` from the
   [latest release](https://github.com/ajipurn/agent-profiles/releases/latest).
2. Unzip it and move **Agent Profiles.app** to **Applications**.
3. Open it and click its icon in the menu bar.

Later versions arrive through the built-in updater, which checks each
update's Ed25519 signature before installing it.

### First launch

Releases are ad-hoc signed, not notarized (that needs a paid Apple Developer
account), so macOS warns *"Apple could not verify Agent Profiles…"* the first
time. Nothing was detected. Allow it once, either way:

- **System Settings:** click **Done** in the warning, open **Privacy &
  Security**, scroll to *"Agent Profiles" was blocked…* and click **Open
  Anyway**.
- **Terminal:**

  ```sh
  xattr -dr com.apple.quarantine "/Applications/Agent Profiles.app"
  ```

Building from source avoids the warning.

### Coming from Claude Profiles or Codex Profiles

Quit them before opening Agent Profiles. It takes over their profiles,
accounts and `claudeprofiles://` links as they are, and won't run alongside
them.

## Getting started

Agent Profiles starts from the accounts you are already signed in to:

- **Claude:** if Claude is signed in but profiles were never set up, the
  current login becomes the first profile ("main") while Claude.app is quit.
  With Claude running, use *Set Up Profiles…*. Add another with
  *New Profile* in the panel or Settings → Claude.
- **Codex:** a login in `~/.codex/auth.json` that no saved account matches is
  saved on its own, named after its email. *Add Account* in the panel or
  Settings → Codex runs Codex's own sign-in for another one.
- **Antigravity:** turn it on in Settings → More Providers, then click
  *Add Account* in its tab. Once any account is saved, other accounts you sign
  in to are saved too.

Deleting accounts:

- Any Claude profile can be deleted, including the active and the last one.
  Deleting the active Desktop profile closes Claude, and deleting the active
  or last one stops automatic setup until you choose *Set Up Profiles…* again.
- Removing the active Codex account keeps it from being saved again.

**Shared session history** (Settings → Claude) merges every profile's Claude
Code sessions into one list, after a timestamped backup in your home folder.
*Restore from backup* gives each profile its own sessions back.

## Usage

### Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| <kbd>⌘</kbd><kbd>⌥</kbd><kbd>0</kbd> | Open the panel (can be turned off) |
| <kbd>⌘</kbd><kbd>⌥</kbd><kbd>1</kbd>…<kbd>9</kbd> | Switch to the Nth Claude profile, in the order set in Settings |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>1</kbd>…<kbd>9</kbd> | Switch to the Nth Codex account, favorites first, then by name |
| <kbd>⌘</kbd><kbd>R</kbd> · <kbd>⌘</kbd><kbd>,</kbd> · <kbd>⌘</kbd><kbd>Q</kbd> | Refresh, Settings and quit, while the panel is open |

### URL scheme

For Raycast, Alfred, Shortcuts or the shell (`open "agentprofiles://…"`):

| URL | Action |
| --- | --- |
| `agentprofiles://claude/<name>` | Switch Claude Desktop |
| `agentprofiles://claude-cli/<name>` | Switch the Claude Code profile (`Default` = plain `~/.claude`) |
| `agentprofiles://codex/<name>` | Switch Codex (saved name, label or email) |
| `agentprofiles://antigravity/<email>` | Switch Antigravity |
| `agentprofiles://open[/<pane>]` | Open Settings: `general`, `notifications`, `claude`, `codex`, `providers`, `history` or `about` |

Claude Profiles' `claudeprofiles://switch|switch-cli|open` links still work.

### Command line

The app carries an `agent-profiles` command. Link it into a folder on your
`PATH` once:

```sh
ln -s "/Applications/Agent Profiles.app/Contents/Helpers/agent-profiles" /usr/local/bin/
```

| Command | Output |
| --- | --- |
| `agent-profiles` (or `status`) | The active Claude Desktop profile with its usage, the Claude Code profile and the Codex account |
| `agent-profiles list [claude\|claude-cli\|codex]` | Profiles and accounts, `*` on the active ones |
| `agent-profiles usage [claude\|codex]` | Claude Desktop usage as Claude last saw it; the active Codex account's usage, fetched now |
| `agent-profiles cost` | The estimated cost, as in the panel |
| `agent-profiles history [claude\|codex] [--days N]` | Each account's peaks over the last 7 days (up to 30) and how often a limit filled up |
| `agent-profiles switch claude\|claude-cli\|codex <name>` | Switches through the app and waits until it is done (`--no-wait` doesn't) |

Add `--json` for scripts and status lines. Reading needs nothing running; a
switch opens the app if it isn't running.

## Privacy and security

- No analytics, no advertising SDK, no server of its own. The app only talks
  to the providers you use, their status pages and GitHub for updates.
- Claude profiles are folders the app moves and links; it never reads
  Claude's passwords, cookies or tokens. Saved Codex logins are local files
  with restricted permissions. Saved Antigravity sign-ins stay in your login
  Keychain, like Antigravity's own.
- Usage history is kept on this Mac only, at most one reading per account
  every ten minutes, for 30 days.

[PRIVACY.md](PRIVACY.md) lists every file read and every network request.
Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## FAQ

<details>
<summary><b>How accurate is the cost estimate?</b></summary>

It is an estimate at API list prices. Claude Desktop chats keep no local
token log, so they aren't counted, and on a subscription it is the value of
what you used, not a bill.
</details>

<details>
<summary><b>GitHub Copilot shows nothing, though I use it in VS Code.</b></summary>

VS Code keeps its GitHub sign-in in the Keychain, which Agent Profiles doesn't
read. Signing in through the Copilot CLI or a JetBrains, Vim or Xcode plugin
gives it a token to use.
</details>

<details>
<summary><b>Kiro says its sign-in has lapsed.</b></summary>

Run `kiro-cli` again to renew it; Agent Profiles doesn't renew Kiro's
sign-in.
</details>

<details>
<summary><b>Gemini shows no quota for my personal Google account.</b></summary>

Google moved individual and AI Pro/Ultra accounts from Gemini CLI to
Antigravity in June 2026. Turn on Antigravity instead.
</details>

<details>
<summary><b>Does switching Antigravity accounts sign me out?</b></summary>

No. Antigravity's own Sign Out is never used, so no saved sign-in is revoked.
Switching quits Antigravity, swaps its sign-in and opens it again if it was
open.
</details>

<details>
<summary><b>Is it affiliated with Anthropic, OpenAI or Google?</b></summary>

No. Agent Profiles is developed independently and isn't affiliated with or
endorsed by any provider.
</details>

## Building from source

Requires macOS 14+, Swift 6 and Python 3. The Command Line Tools are enough
for a build for your Mac; universal (arm64 + x86_64) builds need Xcode.

```sh
git clone https://github.com/ajipurn/agent-profiles.git
cd agent-profiles
make demo   # sample accounts in temporary folders
make run    # real mode: manages your actual accounts
```

| Command | Does |
| --- | --- |
| `make build` | Builds the app target |
| `make test` | Runs the Swift test suites and the Codex checks |
| `make demo` | Packages and opens a preview with sample accounts |
| `make run` | Packages and opens the app in real mode |
| `make icon` | Redraws the app icon (`scripts/make-icon.swift`) |

The preview (`--demo`) never quits or relaunches Claude, ChatGPT or
Antigravity and makes no usage requests, so it is safe next to the real app.
It shares the real app's preferences, though: picking a tab there changes
"Show usage for".

When the default SDK is macOS 27 and Xcode isn't installed, the scripts build
against the macOS 26 SDK; [`scripts/swift-env.sh`](scripts/swift-env.sh)
explains why.

## Contributing

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md)
for checks to run, the project layout and the paths that must not change.
Releases follow the [release guide](docs/RELEASING.md); changes are listed in
the [changelog](CHANGELOG.md).

## Acknowledgements

- The panel's design, the alerts and the extra providers follow
  [OpenUsage](https://github.com/robinebers/openusage) by Robin Ebers and
  [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger.
- Provider marks are from [Lobe Icons](https://github.com/lobehub/lobe-icons).
- Prices come from [LiteLLM](https://github.com/BerriAI/litellm), and updates
  from [Sparkle](https://sparkle-project.org).
- The code was imported from
  [claude-profiles](https://github.com/ajipurn/claude-profiles) and
  [codex-profiles](https://github.com/ajipurn/codex-profiles); earlier history
  stays in those repositories.

## License

[MIT](LICENSE). Bundled dependencies keep their own
[licenses and notices](THIRD_PARTY_NOTICES.md).
