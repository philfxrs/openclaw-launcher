# uninstall.ps1 — Uninstall Entry Point
# Called by Inno Setup [UninstallRun] to clean up OpenClaw components.

[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'init.ps1')

if (-not $InstallRoot) {
    $InstallRoot = $script:InstallerRoot
}

$logRoot   = Join-Path $env:ProgramData 'OpenClawInstaller\Logs'
$statePath = Join-Path $env:ProgramData 'OpenClawInstaller\install-state.json'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$logPath = Join-Path $logRoot ("uninstall-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

Start-Transcript -Path $logPath -Force | Out-Null

try {
    Write-Log -Message 'Starting OpenClaw uninstall cleanup'

    & (Join-Path $PSScriptRoot 'steps\remove-residuals.ps1') `
        -StatePath $statePath `
        -ShortcutName $ShortcutName `
        -RemoveManagedNode `
        -RemoveManagedGit

    Write-Log -Message "Uninstall cleanup finished. Log: $logPath" -Level 'SUCCESS'
} finally {
    Stop-Transcript | Out-Null
}
