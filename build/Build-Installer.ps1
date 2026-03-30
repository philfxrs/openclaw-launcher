[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$DiagnosticsUploadUri,
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

$configuratorSource = Join-Path $RepositoryRoot 'configurator\OpenClawConfigurator.cs'
$configuratorOutputDir = Join-Path $RepositoryRoot 'artifacts\configurator'
$launcherOutputDir = Join-Path $RepositoryRoot 'artifacts\launcher'

$latestConfiguratorArtifact = Get-ChildItem -Path $configuratorOutputDir -Filter 'OpenClawConfigurator*.exe' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1

if (-not $latestConfiguratorArtifact -or $latestConfiguratorArtifact.LastWriteTimeUtc -lt (Get-Item $configuratorSource).LastWriteTimeUtc) {
    & (Join-Path $PSScriptRoot 'Build-Configurator.ps1') -RepositoryRoot $RepositoryRoot -SkipSigning:$SkipSigning
    $latestConfiguratorArtifact = Get-ChildItem -Path $configuratorOutputDir -Filter 'OpenClawConfigurator*.exe' |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

if (-not $latestConfiguratorArtifact) {
    throw 'OpenClawConfigurator.exe was not produced. Build-Configurator.ps1 did not create any configurator artifact.'
}

New-Item -ItemType Directory -Force -Path $launcherOutputDir | Out-Null
Copy-Item -Path $latestConfiguratorArtifact.FullName -Destination (Join-Path $launcherOutputDir 'OpenClawConfigurator.exe') -Force

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

$installerScript = Join-Path $RepositoryRoot 'installer\inno\OpenClawSetup.iss'
Write-Host "Compiling $installerScript"

$previousDiagnosticsUploadUri = $env:OPENCLAW_DIAGNOSTICS_UPLOAD_URI
if ($PSBoundParameters.ContainsKey('DiagnosticsUploadUri')) {
    $env:OPENCLAW_DIAGNOSTICS_UPLOAD_URI = $DiagnosticsUploadUri
    Write-Host "Using diagnostics upload URL: $DiagnosticsUploadUri"
}

try {
    $process = Start-Process -FilePath $iscc -ArgumentList @($installerScript) -NoNewWindow -PassThru -Wait
} finally {
    if ($PSBoundParameters.ContainsKey('DiagnosticsUploadUri')) {
        if ($null -eq $previousDiagnosticsUploadUri) {
            Remove-Item Env:OPENCLAW_DIAGNOSTICS_UPLOAD_URI -ErrorAction SilentlyContinue
        } else {
            $env:OPENCLAW_DIAGNOSTICS_UPLOAD_URI = $previousDiagnosticsUploadUri
        }
    }
}

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
