<#
Agent Profiles: Windows research (port phase 0).

Records where Claude Desktop, Claude Code and Codex keep their data on this
PC, so the Windows port is designed against facts instead of guesses.

Read-only. It notes names, paths, sizes and yes/no answers only: it never
prints file contents, tokens or account ids, and it shortens the profile
path to %USERPROFILE%. The one side effect is a throwaway test folder (with a
junction inside) under %TEMP%, removed before the script ends.

Run it with Claude Desktop, Claude Code and Codex installed and signed in:

    powershell -ExecutionPolicy Bypass -File .\windows-research.ps1

It writes windows-research.txt next to itself; send that file back.
Works on Windows PowerShell 5.1 and PowerShell 7.
#>

$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.Generic.List[string]

function Hide([string]$text) {
    if ($env:USERPROFILE) { $text = $text -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%' }
    $text
}

function Say([string]$text = '') {
    $line = Hide $text
    $lines.Add($line)
    Write-Host $line
}

function Section([string]$title) {
    Say ''
    Say "## $title"
}

function Size([long]$bytes) {
    if ($bytes -ge 1MB) { return '{0:N1} MB' -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return '{0:N1} KB' -f ($bytes / 1KB) }
    "$bytes B"
}

function YesNo($value) { if ($value) { 'yes' } else { 'no' } }

# One line per top-level entry: name, kind, size; links show their target.
function ListDir([string]$path) {
    Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
        $kind = if ($_.PSIsContainer) { 'dir ' } else { 'file' }
        $link = ''
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { $link = " -> [$($_.LinkType)] $($_.Target)" }
        $size = if ($_.PSIsContainer) { '' } else { "  $(Size $_.Length)" }
        Say "    $kind  $($_.Name)$size$link"
    }
}

function Commands([string]$name) {
    $found = @(Get-Command $name -All -ErrorAction SilentlyContinue)
    if ($found.Count -eq 0) { Say "  ``$name`` on PATH: not found"; return }
    foreach ($c in $found) { Say "  ``$name`` on PATH: $($c.CommandType)  $($c.Source)" }
}

function Packages([string[]]$patterns) {
    try {
        $found = foreach ($p in $patterns) { Get-AppxPackage -Name $p -ErrorAction Stop }
        $found = @($found | Sort-Object PackageFullName -Unique)
        if ($found.Count -eq 0) { Say "  MSIX/Store packages ($($patterns -join ', ')): none" }
        foreach ($pkg in $found) {
            Say "  MSIX package: $($pkg.Name)  version $($pkg.Version)"
            Say "    family:  $($pkg.PackageFamilyName)"
            Say "    install: $($pkg.InstallLocation)"
        }
        $found
    } catch {
        Say "  MSIX packages: could not query ($($_.Exception.Message))"
    }
}

function Installs([string]$pattern) {
    $keys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $found = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pattern })
    if ($found.Count -eq 0) { Say "  Installed programs matching '$pattern': none" }
    foreach ($i in $found) {
        Say "  Installed program: $($i.DisplayName)  version $($i.DisplayVersion)  by $($i.Publisher)"
        if ($i.InstallLocation) { Say "    location: $($i.InstallLocation)" }
    }
}

function Processes([string[]]$names) {
    $found = @(Get-Process -Name $names -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Sort-Object Path -Unique)
    if ($found.Count -eq 0) { Say "  Running ($($names -join ', ')): none" }
    foreach ($p in $found) { Say "  Running: $($p.ProcessName)  $($p.Path)" }
}

# Claude Desktop's usage numbers come from its HTTP cache. Report which
# Chromium cache format this build uses, and how many cached /usage
# responses the Mac parser's rules would find (a count, never the ids).
function CacheReport([string]$dataDir) {
    $cache = Join-Path $dataDir 'Cache\Cache_Data'
    if (-not (Test-Path -LiteralPath $cache)) { Say "  Cache\Cache_Data: missing"; return }
    $files = @(Get-ChildItem -LiteralPath $cache -File -Force -ErrorAction SilentlyContinue)
    $simple = @($files | Where-Object { $_.Name -match '^[0-9a-f]{16}_0$' })
    $block = @($files | Where-Object { $_.Name -match '^(index|data_[0-9]+|f_[0-9a-f]+)$' })
    Say "  Cache\Cache_Data: $($files.Count) files; simple-cache entries (*_0): $($simple.Count); blockfile files (index, data_N, f_N): $($block.Count)"

    $magic = [byte[]](0x30, 0x5C, 0x72, 0xA7, 0x1B, 0x6D, 0xFB, 0xFC)
    $withMagic = 0; $usage = 0; $zstd = 0; $plain = 0
    foreach ($f in $simple) {
        if ($f.Length -gt 64KB -or $f.Length -lt 32) { continue }
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $ok = $true
        for ($i = 0; $i -lt 8; $i++) { if ($bytes[$i] -ne $magic[$i]) { $ok = $false; break } }
        if (-not $ok) { continue }
        $withMagic++
        $keyLength = [BitConverter]::ToInt32($bytes, 12)
        if ($keyLength -le 0 -or $keyLength -ge 4096 -or 24 + $keyLength -ge $bytes.Length) { continue }
        $key = [Text.Encoding]::UTF8.GetString($bytes, 24, $keyLength)
        if ($key -match '/api/organizations/[0-9a-f-]{36}/usage$') {
            $usage++
            $body = 24 + $keyLength
            if ($bytes[$body] -eq 0x28 -and $bytes[$body + 1] -eq 0xB5) { $zstd++ }
            elseif ($bytes[$body] -eq 0x7B) { $plain++ }
        }
    }
    Say "  simple-cache entries with the Mac header magic: $withMagic; /usage responses: $usage (zstd: $zstd, plain JSON: $plain)"

    if ($block.Count -gt 0) {
        $hits = 0
        foreach ($f in @($block | Where-Object { $_.Length -le 50MB })) {
            $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($f.FullName))
            $hits += ([regex]::Matches($text, 'organizations/[0-9a-f-]{36}/usage')).Count
        }
        Say "  /usage URLs mentioned in blockfile files: $hits"
    }
}

function ClaudeDataDir([string]$dir) {
    Say ''
    Say "  Data folder: $dir"
    if (-not (Test-Path -LiteralPath $dir)) { Say '    (does not exist)'; return }
    $item = Get-Item -LiteralPath $dir -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Say "    is a link: [$($item.LinkType)] -> $($item.Target)"
    }
    ListDir $dir

    $config = Join-Path $dir 'config.json'
    if (Test-Path -LiteralPath $config) {
        try {
            $json = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
            $orgKeys = @($json.PSObject.Properties.Name | Where-Object { $_ -match '^dxt:[^:]+:[0-9a-f-]{36}$' })
            Say "  config.json: 'dxt:<name>:<org-id>' keys (how the app finds org ids): $($orgKeys.Count)"
        } catch { Say "  config.json: unreadable as JSON" }
    } else { Say '  config.json: missing' }

    $ops = Join-Path $dir 'cowork-enabled-cli-ops.json'
    if (Test-Path -LiteralPath $ops) {
        try {
            $json = Get-Content -LiteralPath $ops -Raw | ConvertFrom-Json
            Say "  cowork-enabled-cli-ops.json: has ownerAccountId: $(YesNo ($null -ne $json.ownerAccountId))"
        } catch { Say "  cowork-enabled-cli-ops.json: unreadable as JSON" }
    } else { Say '  cowork-enabled-cli-ops.json: missing' }

    Say "  'Local State' (holds the DPAPI-wrapped key): $(YesNo (Test-Path -LiteralPath (Join-Path $dir 'Local State')))"
    foreach ($tree in 'claude-code-sessions', 'local-agent-mode-sessions') {
        Say "  ${tree}: $(YesNo (Test-Path -LiteralPath (Join-Path $dir $tree)))"
    }
    CacheReport $dir
}

Say '# Agent Profiles: Windows research'
Say "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

Section 'System'
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Say "  Windows: $($os.Caption)  build $($os.BuildNumber)  ($env:PROCESSOR_ARCHITECTURE)"
} catch { Say "  Windows: $([Environment]::OSVersion.VersionString)" }
Say "  PowerShell: $($PSVersionTable.PSVersion)"
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Say "  Running as administrator: $(YesNo $admin)"
$devMode = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
Say "  Developer Mode: $(YesNo ($devMode -eq 1))"
Say "  APPDATA: $env:APPDATA  (default location: $(YesNo ($env:APPDATA -eq (Join-Path $env:USERPROFILE 'AppData\Roaming'))))"
Say "  LOCALAPPDATA: $env:LOCALAPPDATA"

Section 'Claude Desktop'
$claudePackages = Packages @('*Claude*', '*Anthropic*')
Installs '*Claude*'
foreach ($dir in "$env:LOCALAPPDATA\AnthropicClaude", "$env:LOCALAPPDATA\Programs\Claude", "$env:ProgramFiles\Claude") {
    if (Test-Path -LiteralPath $dir) { Say "  Program folder: $dir"; ListDir $dir }
}
Processes @('claude')
$dataDirs = @("$env:APPDATA\Claude")
foreach ($pkg in @($claudePackages)) {
    if ($pkg.PackageFamilyName) { $dataDirs += "$env:LOCALAPPDATA\Packages\$($pkg.PackageFamilyName)\LocalCache\Roaming\Claude" }
}
foreach ($dir in $dataDirs) { ClaudeDataDir $dir }

Section 'Claude Code (CLI)'
Commands 'claude'
Say "  CLAUDE_CONFIG_DIR set: $(YesNo $env:CLAUDE_CONFIG_DIR)$(if ($env:CLAUDE_CONFIG_DIR) { "  ($env:CLAUDE_CONFIG_DIR)" })"
$claudeHome = Join-Path $env:USERPROFILE '.claude'
if (Test-Path -LiteralPath $claudeHome) {
    Say "  $claudeHome"
    ListDir $claudeHome
    $credentials = Join-Path $claudeHome '.credentials.json'
    Say "  .credentials.json (login stored as a file in the config dir): $(YesNo (Test-Path -LiteralPath $credentials))"
} else { Say "  $claudeHome does not exist" }
Say "  %USERPROFILE%\.claude.json: $(YesNo (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.claude.json')))"
# Only target names ("...target=<name>"), which hold no secret; matched on
# "target=" because the "Target:" label is translated.
$targets = @(cmdkey /list 2>$null | Select-String -Pattern 'target=.*(claude|anthropic)' | ForEach-Object { $_.Line.Trim() })
if ($targets.Count -eq 0) { Say '  Credential Manager entries mentioning claude/anthropic: none' }
foreach ($t in $targets) { Say "  Credential Manager entry: $t" }

Section 'Codex'
Commands 'codex'
Say "  CODEX_HOME set: $(YesNo $env:CODEX_HOME)$(if ($env:CODEX_HOME) { "  ($env:CODEX_HOME)" })"
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
if (Test-Path -LiteralPath $codexHome) {
    Say "  $codexHome"
    ListDir $codexHome
    Say "  auth.json: $(YesNo (Test-Path -LiteralPath (Join-Path $codexHome 'auth.json')))"
} else { Say "  $codexHome does not exist" }
$null = Packages @('*OpenAI*', '*ChatGPT*', '*Codex*')
Installs '*ChatGPT*'
Installs '*Codex*'
Processes @('ChatGPT', 'Codex')

# Can this account make the links the switcher needs, without admin?
Section 'Link test (in %TEMP%, removed afterwards)'
$root = Join-Path $env:TEMP "agent-profiles-research-$([guid]::NewGuid().ToString('N'))"
try {
    $target = Join-Path $root 'target'
    $null = New-Item -ItemType Directory -Path $target -Force
    Set-Content -LiteralPath (Join-Path $target 'probe.txt') -Value 'probe'

    $junction = Join-Path $root 'junction'
    $made = cmd /c "mklink /J `"$junction`" `"$target`"" 2>&1
    $works = Test-Path -LiteralPath (Join-Path $junction 'probe.txt')
    Say "  Junction (mklink /J): created: $(YesNo ($LASTEXITCODE -eq 0)); readable through: $(YesNo $works)"
    if ($LASTEXITCODE -ne 0) { Say "    $made" }
    $item = Get-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue
    if ($item) { Say "    reported as: LinkType=$($item.LinkType) Attributes=$($item.Attributes)" }
    cmd /c "rmdir `"$junction`"" 2>&1 | Out-Null
    Say "    rmdir removes only the link (target file kept): $(YesNo (Test-Path -LiteralPath (Join-Path $target 'probe.txt')))"

    $symlink = Join-Path $root 'symlink'
    $made = cmd /c "mklink /D `"$symlink`" `"$target`"" 2>&1
    Say "  Directory symlink (mklink /D): created: $(YesNo ($LASTEXITCODE -eq 0))"
    if ($LASTEXITCODE -ne 0) { Say "    $made" }
} catch {
    Say "  Link test failed: $($_.Exception.Message)"
} finally {
    foreach ($link in 'junction', 'symlink') {
        $path = Join-Path $root $link
        if (Test-Path -LiteralPath $path) { cmd /c "rmdir `"$path`"" 2>&1 | Out-Null }
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

$folder = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$report = Join-Path $folder 'windows-research.txt'
$lines | Out-File -LiteralPath $report -Encoding utf8
Write-Host ''
Write-Host "Saved to $report. Check it over, then send it back."
