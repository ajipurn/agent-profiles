# Changelog

## 1.4.6

- Antigravity's card now matches Antigravity's own Usage view: its limits are grouped as Gemini Models, Claude and GPT models and Gemini 4 Argon, weekly before 5-hour. While Antigravity is open, the numbers come from the app itself, the only source of the Gemini 4 Argon allowance.
- Fixed Antigravity's Gemini limits showing 100% left after using Gemini in the Antigravity app.
- With "Follow the active app" on, bringing Antigravity to the front now switches the menu bar icon to it, as Claude and Codex do. Turn Antigravity on in Settings → More Providers first.

## 1.4.5

- Antigravity usage now shows when you are signed in to the Antigravity app. Agent Profiles reads the sign-in the app keeps in the Keychain through macOS's own `security` tool, which that sign-in already trusts, so there is no Keychain prompt. Before, only the `agy` CLI's sign-in file was read, and app users saw "No Antigravity sign-in file found".
- When Antigravity's sign-in expires while the app is closed, Agent Profiles renews it in memory and keeps showing your quota, instead of asking you to open Antigravity.

## 1.4.4

- Fixed new Claude sessions going unsaved, and then disappearing, after switching to an account that belongs to two organizations while shared history is on. Since Claude Desktop 4.23118, Claude will not save into a linked session folder; the shared history now moves into the organization Claude actually uses.
- If Claude moves to another organization while it is running, Agent Profiles notices that new sessions cannot be saved and offers to restart Claude to fix it.
- Cost estimates now price Claude Haiku 5.5, including its higher rates for prompts over 100,000 tokens, and bill Claude Sonnet 5.5 cache reads at $0.10 per million tokens instead of twice that. New OpenAI models are priced too.

## 1.4.3

- Switch Account is laid out as a small table with "5h" and "Week" columns: each shows what is left over a wider bar, and when that limit resets underneath once it has been used. Long account names get more room, and the tooltip shows the full name.
- A used-up limit's bar is tinted red instead of looking empty, so it no longer reads as missing data.

## 1.4.2

- Switch Account shows when each account's 5-hour and weekly limits reset, next to their meters, so you can see when a used-up account is usable again without hovering. Resets follow the "Show resets as clock times" setting.

## 1.4.1

- Fixed "100%" wrapping onto two lines in Switch Account and the Overview tab; the meters stay aligned.
- "Most left" now marks an account only when it has more left than every other one, so accounts that are all at 100% get no mark.

## 1.4.0

- Switch Account shows each account's 5-hour and weekly limits side by side, sorted by what is left, with the account that has the most left marked.
- Claude shows its per-model weekly limits (Sonnet, Opus) and extra usage spend; Codex shows Spark limits, credits, a workspace credit limit and limit resets waiting to be used.
- More providers: Gemini, Antigravity, Cursor, GitHub Copilot, OpenCode, Kiro and Grok, each off until turned on in Settings → More Providers. They read the sign-in their own tool keeps on this Mac and never change it. An Overview tab lists every provider, closest to running out first. These are new; please report any that show the wrong numbers.
- Notifications at a warning and a critical level you choose, when a limit will run out before it resets, when a used-up limit has reset, when a sign-in stops working and, if turned on, a day before a weekly limit resets with most of it unused. They replace the single 10% alert and live in Settings → Notifications.
- Status-page incidents for each provider show on its card and tab.
- The cost card opens a 30-day chart with the most expensive models; hover a day for its breakdown.
- Settings → History charts each account's session and weekly usage over the last 7 or 30 days, from readings kept on this Mac.
- An `agent-profiles` command for scripts and status lines: status, list, usage, cost, history and switch, each with `--json`. It ships inside the app; the README shows how to link it onto your PATH.
- Click a percentage to show used instead of left, or a reset to show a clock time. Also new: hide email addresses, Copy Image, ⌘⌥0 to open the panel, a choice of window for the menu bar percentage, and following whichever provider has less left.
- New app icon, the menu bar's two-bar meter, and a refreshed panel.
- Fixed restoring shared session history from a backup after a profile was renamed: each profile now gets its own sessions back.

## 1.3.9

- Claude profiles can now be deleted down to an empty list, including the active and last profile, so you can keep only Codex or only Claude profiles.
- Deleting the active Claude Desktop profile closes Claude and removes its folder link. Automatic setup stays disabled until you choose Set Up Profiles again.
- Claude Code profiles remain manageable after the last Desktop profile is deleted. Shared session history and the default Claude Code configuration are preserved.

## 1.3.8

- Fixed Add Account returning to the active Codex account when an outdated CLI could not read the current configuration. Sign-in now prefers the CLI bundled with ChatGPT or Codex.
- Codex sign-in now saves credentials where Agent Profiles manages accounts, even when Terminal uses a different Codex home or credential store.
- Improved cross-platform core support, including Windows directory junctions and Codex CLI discovery.

## 1.3.7

- Codex is now blue, matching its app icon: in the cost ring, the Codex tab, Settings and the app icon's Codex arc

## 1.3.6

- Refined app icon: larger, bolder gauge arcs that fill the dial, with a softly lit center

## 1.3.5

- More accurate cost estimate: Codex turns on the priority (or flex) tier and long prompts are priced at their own rates, Claude fast mode at its 2x rate, US-only inference at 1.1x, and web searches at $10 per 1,000
- Model prices refreshed from LiteLLM

## 1.3.4

- Fix: clicking the menu bar icon while the panel is open closes it. In 1.3.3 the panel flickered and opened again
- Right-clicking the icon while the panel is open closes the panel before showing the menu

## 1.3.3

- Fix: the panel opens again when you click the menu bar icon. In 1.3.1 and 1.3.2 it opened with zero size and stayed invisible
- Right-click (or Control-click) the menu bar icon for Settings, Check for Updates and Quit, which work even if the panel doesn't

## 1.3.2

- Fix: clicking the menu bar icon opens the panel again. In 1.3.1 the panel closed itself the moment it opened

## 1.3.1

- The panel is now its own rounded window under the menu bar icon, so it always fits its content (no more grey edges when data loads after opening)
- Click outside, click the icon again, or press Esc to close it

## 1.3.0

- New panel in place of the menu, in the style of OpenUsage: provider tabs, a usage card per provider, accounts to switch to, and action buttons
- Estimated cost card: Today, Yesterday and 30 Days per provider, read from local Claude Code and Codex logs and priced at API list rates (turn it off in Settings → General)
- Pace on usage bars: blue when on course, yellow when cutting it close, red with the projected run-out time
- New app icon

## 1.2.1

- "Follow the active app" is now on by default: bringing Claude or the Codex app to the front switches the menu bar icon to that provider. Turn it off in Settings → General

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
