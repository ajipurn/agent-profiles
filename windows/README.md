# Agent Profiles for Windows

The tray app (`AgentProfiles.exe`, C# / WPF) and the engine (`agent-profiles.exe`,
the Swift CLI) ship side by side in one folder. The design, and what is still
open, is in [docs/WINDOWS.md](../docs/WINDOWS.md).

## Try a build

Every push builds `AgentProfiles-Windows-x64.zip` in GitHub Actions: workflow
**Windows app**, artifact **AgentProfiles-Windows-x64**.

1. Download the zip and unzip it to a folder of your own, for example
   `%LOCALAPPDATA%\Programs\Agent Profiles`.
2. Run `AgentProfiles.exe`. Its icon appears in the notification area.
3. Click the icon for the panel. Right-click it for Settings and Quit.

The build is not signed yet, so SmartScreen may ask once ("More info" →
"Run anyway").

## Build it yourself

You need the Swift toolchain for Windows and the .NET 8 SDK:

```powershell
swift build -c release --product agent-profiles
dotnet publish windows\AgentProfiles.Windows -c Release -r win-x64 --self-contained -o out\app
copy .build\release\agent-profiles.exe out\app\
```

Copy the Swift runtime DLLs next to `agent-profiles.exe` as well; the CI
workflow shows how. `AGENT_PROFILES_ENGINE` points the tray at another
`agent-profiles.exe` while developing.

On macOS and Linux, `dotnet build windows/AgentProfiles.Windows` compiles the
tray (`EnableWindowsTargeting`), but it only runs on Windows.
