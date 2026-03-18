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
    $shortcut.TargetPath = $LauncherPath
    $shortcut.WorkingDirectory = $workingDirectory
    $shortcut.IconLocation = "$LauncherPath,0"
    $shortcut.Description = 'Launch OpenClaw'
    $shortcut.Save()

    Write-Log -Message ("Created {0}." -f $shortcutSpec.label) -Level 'SUCCESS'
}

return [pscustomobject]@{
    desktopShortcut = $desktopShortcut
    startMenuShortcut = $startMenuShortcut
}
