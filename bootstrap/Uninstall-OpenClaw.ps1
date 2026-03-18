[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\Installer.Common.ps1')

if (-not $InstallRoot) {
    $InstallRoot = Split-Path -Parent $PSScriptRoot
}

$logRoot = Join-Path $env:ProgramData 'OpenClawInstaller\Logs'
$statePath = Join-Path $env:ProgramData 'OpenClawInstaller\install-state.json'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$logPath = Join-Path $logRoot ("uninstall-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

Start-Transcript -Path $logPath -Force | Out-Null

try {
    Write-Log -Message 'Starting OpenClaw uninstall cleanup'
    & (Join-Path $repositoryRoot 'scripts\Remove-Residuals.ps1') -StatePath $statePath -ShortcutName $ShortcutName -RemoveManagedNode -RemoveManagedGit
    Write-Log -Message "OpenClaw uninstall cleanup finished. Log: $logPath" -Level 'SUCCESS'
} finally {
    Stop-Transcript | Out-Null
}
