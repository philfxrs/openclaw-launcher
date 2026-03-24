# test-openclaw-ready.ps1 — Launch Readiness Verification
# Verifies the OpenClaw gateway is reachable, launches the desktop launcher
# via shortcut, and confirms the main window appears.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installerRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $installerRoot 'powershell\init.ps1')

Refresh-ProcessPath

# ── Helper: check launcher log for readiness ─────────────────────────────

function Test-LauncherReadyLog {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][datetime]$NotBefore
    )

    if (-not (Test-Path $Path)) { return $false }

    foreach ($line in (Get-Content $Path -Tail 80 -ErrorAction SilentlyContinue)) {
        if ($line -match '^\[(?<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[(?<level>[A-Z]+)\] (?<message>.*)$') {
            try {
                $ts = [datetime]::ParseExact($matches.timestamp, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            } catch { continue }

            if ($ts -ge $NotBefore.AddSeconds(-2) -and $matches.message -eq 'Control UI is ready for use.') {
                return $true
            }
        }
    }

    return $false
}

# ── OpenClaw CLI & Gateway ───────────────────────────────────────────────

$openclawPath = Get-OpenClawCommandPath
if (-not $openclawPath) {
    throw (New-InstallerException -Code 'E3003' -Message 'OpenClaw CLI is unavailable during launch validation.')
}

$versionResult = Invoke-OpenClaw -Arguments @('--version')
$version = $versionResult.StdOut.Trim()
if (-not $version) {
    throw (New-InstallerException -Code 'E3003' -Message 'Unable to resolve OpenClaw version during launch validation.')
}

Write-Log -Message "Validating OpenClaw launch readiness, version $version"
Invoke-OpenClaw -Arguments @('gateway', 'start') -AllowNonZeroExit | Out-Null

Wait-Until -Description 'OpenClaw dashboard endpoint' -TimeoutSeconds 90 -PollSeconds 3 -Condition {
    return (Test-HttpEndpoint -Url 'http://127.0.0.1:18789/' -TimeoutSeconds 5)
}

# ── Desktop shortcut target check ────────────────────────────────────────

$desktopShortcut = Get-DesktopShortcutPath -ShortcutName $ShortcutName
if (-not (Test-Path $desktopShortcut)) {
    throw (New-InstallerException -Code 'E4002' -Message "Desktop shortcut not found: $desktopShortcut")
}

$shell    = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($desktopShortcut)
if ([string]::Compare($shortcut.TargetPath, $LauncherPath, $true) -ne 0) {
    throw (New-InstallerException -Code 'E4002' -Message (
        "Desktop shortcut target mismatch. Expected {0}, got {1}." -f $LauncherPath, $shortcut.TargetPath
    ))
}

Write-Log -Message 'Desktop shortcut target validated.' -Level 'SUCCESS'

# ── Launch via shortcut & window validation ──────────────────────────────

$processIdsBefore = @(Get-Process OpenClawLauncher -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$launcherLogPath  = Join-Path $env:LOCALAPPDATA 'OpenClaw\logs\launcher.log'
$launchStartedAt  = Get-Date
Start-Process $desktopShortcut

Wait-Until -Description 'OpenClaw desktop window (shortcut launch)' -TimeoutSeconds 90 -PollSeconds 2 -Condition {
    $procs = Get-Process OpenClawLauncher -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($processIdsBefore -contains $p.Id) { continue }
        try {
            $p.Refresh()
            if ($p.MainWindowHandle -ne 0 -and (Test-LauncherReadyLog -Path $launcherLogPath -NotBefore $launchStartedAt)) {
                return $true
            }
        } catch { }
    }
    return $false
}

Write-Log -Message 'Desktop shortcut launch validated.' -Level 'SUCCESS'

return [pscustomobject]@{
    version          = $version
    desktopShortcut  = $desktopShortcut
    launcherLogPath  = $launcherLogPath
}
