[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [switch]$SkipSigning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$sourcePath = Join-Path $RepositoryRoot 'configurator\OpenClawConfigurator.cs'
$outputDir = Join-Path $RepositoryRoot 'artifacts\configurator'
$outputPath = Join-Path $outputDir 'OpenClawConfigurator.exe'

$compilerCandidates = @(
    'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe',
    'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
)

$compiler = $compilerCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $compiler) {
    throw 'Unable to locate csc.exe from .NET Framework 4.x.'
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$arguments = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    "/out:$outputPath",
    '/r:System.dll',
    '/r:System.Core.dll',
    '/r:System.Drawing.dll',
    '/r:System.Web.Extensions.dll',
    '/r:System.Windows.Forms.dll',
    $sourcePath
)

Write-Host "Compiling configurator with $compiler"
$process = Start-Process -FilePath $compiler -ArgumentList $arguments -NoNewWindow -PassThru -Wait
if ($process.ExitCode -ne 0) {
    throw "Configurator compilation failed with exit code $($process.ExitCode)."
}

if (-not $SkipSigning) {
    & (Join-Path $PSScriptRoot 'Sign-Artifacts.ps1') -RepositoryRoot $RepositoryRoot -FilePaths @($outputPath)
}

Write-Host "Built $outputPath"
