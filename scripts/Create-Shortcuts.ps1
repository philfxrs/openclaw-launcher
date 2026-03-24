[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw'
)

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

if (-not (Test-Path $LauncherPath)) {
    throw "Launcher not found: $LauncherPath"
}

$resolvedLauncherPath = (Resolve-Path $LauncherPath).ProviderPath

$desktopShortcut = Get-DesktopShortcutPath -ShortcutName $ShortcutName
$startMenuShortcut = Get-StartMenuShortcutPath -ShortcutName $ShortcutName
$workingDirectory = Split-Path -Parent $LauncherPath

$shell = New-Object -ComObject WScript.Shell
foreach ($shortcutSpec in @(
    @{ path = $desktopShortcut; label = 'desktop shortcut' },
    @{ path = $startMenuShortcut; label = 'Start menu shortcut' }
)) {
    $shortcutPath = $shortcutSpec.path
    $directory = Split-Path -Parent $shortcutPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null

    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $resolvedLauncherPath
    $shortcut.WorkingDirectory = $workingDirectory
    $shortcut.IconLocation = "$LauncherPath,0"
    $shortcut.Description = 'Launch OpenClaw'
    $shortcut.Save()

    $savedShortcut = $shell.CreateShortcut($shortcutPath)
    $resolvedShortcutTargetPath = if ($savedShortcut.TargetPath) { [System.IO.Path]::GetFullPath($savedShortcut.TargetPath) } else { $null }
    if ([string]::Compare($resolvedShortcutTargetPath, $resolvedLauncherPath, $true) -ne 0) {
        throw (New-InstallerException -Code 'E4002' -Message ("Shortcut target is invalid for {0}. Expected {1}, got {2}." -f $shortcutSpec.label, $resolvedLauncherPath, $savedShortcut.TargetPath))
    }

    if (-not (Test-Path $resolvedShortcutTargetPath)) {
        throw (New-InstallerException -Code 'E4002' -Message ("Shortcut target does not exist for {0}: {1}" -f $shortcutSpec.label, $savedShortcut.TargetPath))
    }

    Write-Log -Message ("Created {0}." -f $shortcutSpec.label) -Level 'SUCCESS'
}

return [pscustomobject]@{
    desktopShortcut = $desktopShortcut
    startMenuShortcut = $startMenuShortcut
}
