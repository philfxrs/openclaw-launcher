[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw'
)

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

Refresh-ProcessPath

$resolvedLauncherPath = (Resolve-Path $LauncherPath).ProviderPath

function Test-LauncherReadyLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [datetime]$NotBefore
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    foreach ($line in (Get-Content $Path -Tail 80 -ErrorAction SilentlyContinue)) {
        if ($line -match '^\[(?<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[(?<level>[A-Z]+)\] (?<message>.*)$') {
            try {
                $timestamp = [datetime]::ParseExact($matches.timestamp, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            } catch {
                continue
            }

            if ($timestamp -ge $NotBefore.AddSeconds(-2) -and $matches.message -eq 'Control UI is ready for use.') {
                return $true
            }
        }
    }

    return $false
}

function Test-GatewayReachable {
    return (Test-HttpEndpoint -Url 'http://127.0.0.1:18789/' -TimeoutSeconds 5)
}

function Start-UserSessionGateway {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenClawPath
    )

    Write-Log -Message 'Starting OpenClaw gateway in the current user session.' -Level 'WARN'
    Start-Process -FilePath $OpenClawPath -ArgumentList 'gateway' -WindowStyle Hidden | Out-Null
}

$openclawPath = Get-OpenClawCommandPath
if (-not $openclawPath) {
    throw 'OpenClaw CLI is unavailable during validation.'
}

$version = (Invoke-OpenClaw -Arguments @('--version')).StdOut.Trim()
if (-not $version) {
    throw 'Unable to resolve OpenClaw version during validation.'
}

Write-Log -Message "Validating OpenClaw version $version"
Invoke-OpenClaw -Arguments @('gateway', 'start') -AllowNonZeroExit | Out-Null

if (-not (Test-GatewayReachable)) {
    Write-Log -Message 'OpenClaw gateway was not reachable after start; running local onboarding recovery.' -Level 'WARN'
    try {
        & (Join-Path $PSScriptRoot 'Invoke-OpenClawOnboarding.ps1') | Out-Null
    } catch {
        Write-Log -Message ("Local onboarding recovery did not complete cleanly: {0}" -f $_.Exception.Message) -Level 'WARN'
    }
}

if (-not (Test-GatewayReachable)) {
    Start-UserSessionGateway -OpenClawPath $openclawPath
}

Wait-Until -Description 'OpenClaw dashboard endpoint' -TimeoutSeconds 90 -PollSeconds 3 -Condition {
    return (Test-GatewayReachable)
}

$desktopShortcut = Get-DesktopShortcutPath -ShortcutName $ShortcutName
if (-not (Test-Path $desktopShortcut)) {
    throw (New-InstallerException -Code 'E4002' -Message "Desktop shortcut was not created: $desktopShortcut")
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($desktopShortcut)
$resolvedShortcutTargetPath = if ($shortcut.TargetPath) { [System.IO.Path]::GetFullPath($shortcut.TargetPath) } else { $null }
if ([string]::Compare($resolvedShortcutTargetPath, $resolvedLauncherPath, $true) -ne 0) {
    throw (New-InstallerException -Code 'E4002' -Message "Desktop shortcut does not point to the launcher. Expected $resolvedLauncherPath, got $($shortcut.TargetPath)")
}

if (-not (Test-Path $resolvedShortcutTargetPath)) {
    throw (New-InstallerException -Code 'E4002' -Message "Desktop shortcut target does not exist: $($shortcut.TargetPath)")
}

Write-Log -Message 'Desktop shortcut target validated.' -Level 'SUCCESS'

$launcherProcessesBefore = @(Get-Process OpenClawLauncher -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$launcherLogPath = Join-Path $env:LOCALAPPDATA 'OpenClaw\logs\launcher.log'
$launchStartedAt = Get-Date
Start-Process $desktopShortcut

Wait-Until -Description 'OpenClaw desktop window from shortcut launch' -TimeoutSeconds 90 -PollSeconds 2 -Condition {
    $launcherProcessesNow = Get-Process OpenClawLauncher -ErrorAction SilentlyContinue
    foreach ($process in $launcherProcessesNow) {
        if ($launcherProcessesBefore -contains $process.Id) {
            continue
        }

        try {
            $process.Refresh()
            if ($process.MainWindowHandle -ne 0 -and (Test-LauncherReadyLog -Path $launcherLogPath -NotBefore $launchStartedAt)) {
                return $true
            }
        } catch {
        }
    }

    return $false
}

Write-Log -Message 'Desktop shortcut launch validated.' -Level 'SUCCESS'
Write-Log -Message ("Launcher log path: {0}" -f $launcherLogPath)

return [pscustomobject]@{
    version = $version
    desktopShortcut = $desktopShortcut
    launcherLogPath = $launcherLogPath
}
