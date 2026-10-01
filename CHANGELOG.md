# Changelog

## 1.2.0

- New "Follow the active app" option (Settings → General): bringing Claude or the Codex app to the front switches the menu bar icon to that provider; other apps, including terminals, keep the last one
- Picking a tab in the menu still switches the icon right away

## 1.1.0

- Picking Claude or Codex in the menu now also switches the menu bar icon (and Settings' "Show usage for") to that provider
- Usage bars share one color across providers, so remaining limits read the same at a glance
- Claude and Codex brand logos (from Lobe Icons) in the menu tabs and Settings sidebar

## 1.0.1

- Update Sparkle, the app updater, to 2.10.0

## 1.0.0

- One menu for Claude and Codex: usage card with session and weekly bars, reset countdowns, and the other accounts to switch to
- Menu bar icon with session and weekly meters for the provider you pick in Settings
- Settings window for profiles, accounts, shared session history, Claude Code (CLI) profiles and updates
- Existing logins are picked up without a sign-in step
- Hotkeys: ⌘⌥1…9 for Claude profiles, ⌃⌥1…9 for Codex accounts
- `agentprofiles://` URLs for Raycast, Alfred and scripts; `claudeprofiles://` keeps working
- Low-limit alerts for both providers, with one-click switching to the account with the most left
- Keeps the data folders of both old apps, so existing profiles and accounts appear as they are
