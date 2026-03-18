[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [switch]$SkipSync,
    [switch]$SkipSigning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

if (-not $SkipSync) {
    & (Join-Path $PSScriptRoot 'Sync-UpstreamAssets.ps1') -RepositoryRoot $RepositoryRoot
}

& (Join-Path $PSScriptRoot 'Build-Launcher.ps1') -RepositoryRoot $RepositoryRoot -SkipSigning

$isccCandidates = @(
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
)

$iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    throw 'ISCC.exe was not found. Install Inno Setup 6 before building the installer.'
}

$installerScript = Join-Path $RepositoryRoot 'installer\OpenClawBootstrap.iss'
Write-Host "Compiling $installerScript"
$process = Start-Process -FilePath $iscc -ArgumentList @($installerScript) -NoNewWindow -PassThru -Wait
if ($process.ExitCode -ne 0) {
    throw "ISCC.exe failed with exit code $($process.ExitCode)."
}

if (-not $SkipSigning) {
    & (Join-Path $PSScriptRoot 'Sign-Artifacts.ps1') -RepositoryRoot $RepositoryRoot -FilePaths @(
        (Join-Path $RepositoryRoot 'artifacts\launcher\OpenClawLauncher.exe'),
        (Join-Path $RepositoryRoot 'artifacts\installer\OpenClawSetup.exe')
    )
}

Write-Host "Installer build finished. Output folder: $(Join-Path $RepositoryRoot 'artifacts\installer')"
