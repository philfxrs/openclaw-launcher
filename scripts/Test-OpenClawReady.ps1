[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw'
)

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

Refresh-ProcessPath

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

Wait-Until -Description 'OpenClaw dashboard endpoint' -TimeoutSeconds 90 -PollSeconds 3 -Condition {
    return (Test-HttpEndpoint -Url 'http://127.0.0.1:18789/' -TimeoutSeconds 5)
}

$desktopShortcut = Get-DesktopShortcutPath -ShortcutName $ShortcutName
if (-not (Test-Path $desktopShortcut)) {
    throw "Desktop shortcut was not created: $desktopShortcut"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($desktopShortcut)
if ([string]::Compare($shortcut.TargetPath, $LauncherPath, $true) -ne 0) {
    throw "Desktop shortcut does not point to the launcher. Expected $LauncherPath, got $($shortcut.TargetPath)"
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

return [pscustomobject]@{
    version = $version
    desktopShortcut = $desktopShortcut
    launcherLogPath = $launcherLogPath
}
