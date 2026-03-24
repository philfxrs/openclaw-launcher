[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw'
)

$repositoryRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $repositoryRoot 'scripts\Create-Shortcuts.ps1') -LauncherPath $LauncherPath -ShortcutName $ShortcutName