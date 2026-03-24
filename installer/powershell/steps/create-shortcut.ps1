# create-shortcut.ps1 — Step 13: Create Desktop and Start Menu Shortcuts
# Creates .lnk files pointing to the launcher executable.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1')

if (-not (Test-Path $LauncherPath)) {
    throw (New-InstallerException -Code 'E4002' -Message "Launcher not found: $LauncherPath")
}

$desktopShortcut   = Get-DesktopShortcutPath   -ShortcutName $ShortcutName
$startMenuShortcut = Get-StartMenuShortcutPath  -ShortcutName $ShortcutName
$workingDirectory  = Split-Path -Parent $LauncherPath

$shell = New-Object -ComObject WScript.Shell

foreach ($spec in @(
    @{ path = $desktopShortcut;   label = 'desktop shortcut' },
    @{ path = $startMenuShortcut; label = 'Start menu shortcut' }
)) {
    $dir = Split-Path -Parent $spec.path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $sc = $shell.CreateShortcut($spec.path)
    $sc.TargetPath        = $LauncherPath
    $sc.WorkingDirectory  = $workingDirectory
    $sc.IconLocation      = "$LauncherPath,0"
    $sc.Description       = 'Launch OpenClaw'
    $sc.Save()

    Write-Log -Message ("Created {0}: {1}" -f $spec.label, $spec.path) -Level 'SUCCESS'
}

return [pscustomobject]@{
    desktopShortcut   = $desktopShortcut
    startMenuShortcut = $startMenuShortcut
}
