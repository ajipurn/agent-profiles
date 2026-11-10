import Foundation
import PlatformSupport

/// Quits and starts a desktop app around a switch the CLI makes by itself,
/// where there is no Mac app to hand the switch to (Windows).
public protocol DesktopAppControl: Sendable {
    /// Closes the app; false when it is still running afterwards.
    func quit() async throws -> Bool
    /// Starts the app again.
    func launch() throws
}

/// Claude Desktop on Windows, driven through Windows PowerShell, which every
/// Windows 10 and 11 has. Claude Code's own `claude.exe` has the same process
/// name, so only Claude Desktop's install folders count: the Squirrel install
/// under `%LOCALAPPDATA%\AnthropicClaude` and a Store (MSIX) package.
public final class WindowsClaudeDesktop: DesktopAppControl {
    /// Where the running app was started from, to start the same one again.
    private let lastPath = LockedValue<String?>(nil)

    public init() {}

    static let filter = #"Where-Object { $_.Path -and ($_.Path -like '*\AnthropicClaude\*' -or $_.Path -like '*\WindowsApps\*Claude*') }"#

    public func quit() async throws -> Bool {
        let script = """
            $ErrorActionPreference = 'SilentlyContinue'
            $p = @(Get-Process -Name claude | \(Self.filter))
            if ($p.Count -eq 0) { 'none'; exit }
            $p[0].Path
            $p | ForEach-Object { [void]$_.CloseMainWindow() }
            $deadline = (Get-Date).AddSeconds(6)
            while ((Get-Date) -lt $deadline -and @($p | Where-Object { -not $_.HasExited }).Count -gt 0) {
                Start-Sleep -Milliseconds 250
            }
            # Closing the window can leave it in the notification area; then it is ended.
            $p | Where-Object { -not $_.HasExited } | Stop-Process -Force
            Start-Sleep -Milliseconds 800
            if (@(Get-Process -Name claude | \(Self.filter)).Count -eq 0) { 'quit' } else { 'running' }
            """
        let lines = try PowerShell.run(script).split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first != "none" else { return true }
        if let path = lines.first, path.lowercased().hasSuffix(".exe") { lastPath.withLock { $0 = path } }
        return lines.last == "quit"
    }

    public func launch() throws {
        let known = lastPath.withLock { $0 }.map(PowerShell.quoted) ?? "$null"
        _ = try PowerShell.run("""
            $ErrorActionPreference = 'SilentlyContinue'
            $path = \(known)
            if (-not $path) {
                $stub = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\\claude.exe'
                if (Test-Path $stub) { $path = $stub }
            }
            if ($path -and $path -like '*\\WindowsApps\\*') { $path = $null }
            if ($path) {
                # A Squirrel install starts through its stub, one folder up, which picks the current version.
                $stub = Join-Path (Split-Path (Split-Path $path)) 'claude.exe'
                if ((Split-Path (Split-Path $path) -Leaf) -eq 'AnthropicClaude' -and (Test-Path $stub)) { $path = $stub }
                Start-Process -FilePath $path
                exit
            }
            $pkg = Get-AppxPackage | Where-Object { $_.Name -like '*Claude*' -and $_.Publisher -like '*Anthropic*' } | Select-Object -First 1
            if ($pkg) {
                $app = (Get-AppxPackageManifest $pkg).Package.Applications.Application | Select-Object -First 1
                Start-Process "shell:AppsFolder\\$($pkg.PackageFamilyName)!$($app.Id)"
            }
            """)
    }
}

/// Runs a script in Windows PowerShell. The script travels base64-encoded,
/// so no quoting can break it.
enum PowerShell {
    static func run(_ script: String) throws -> String {
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: systemRoot + #"\System32\WindowsPowerShell\v1.0\powershell.exe"#)
        process.arguments = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded(script)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `-EncodedCommand` takes UTF-16LE, base64.
    static func encoded(_ script: String) -> String {
        Data(script.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
    }

    /// A single-quoted PowerShell string, which takes everything literally but `'`.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
