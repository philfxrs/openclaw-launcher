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

$webView2 = & (Join-Path $PSScriptRoot 'Sync-WebView2Assets.ps1') -RepositoryRoot $RepositoryRoot

$sourcePath = Join-Path $RepositoryRoot 'launcher\OpenClawLauncher.cs'
$outputDir = Join-Path $RepositoryRoot 'artifacts\launcher'
$outputPath = Join-Path $outputDir 'OpenClawLauncher.exe'

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
    '/r:System.Management.dll',
    '/r:System.Web.Extensions.dll',
    '/r:System.Windows.Forms.dll',
    "/r:$($webView2.coreDll)",
    "/r:$($webView2.winFormsDll)",
    $sourcePath
)

Write-Host "Compiling launcher with $compiler"
$process = Start-Process -FilePath $compiler -ArgumentList $arguments -NoNewWindow -PassThru -Wait
if ($process.ExitCode -ne 0) {
    throw "Launcher compilation failed with exit code $($process.ExitCode)."
}

Copy-Item -Path $webView2.coreDll -Destination $outputDir -Force
Copy-Item -Path $webView2.winFormsDll -Destination $outputDir -Force
Copy-Item -Path $webView2.loaderDll -Destination $outputDir -Force

if (-not $SkipSigning) {
    & (Join-Path $PSScriptRoot 'Sign-Artifacts.ps1') -RepositoryRoot $RepositoryRoot -FilePaths @($outputPath)
}

Write-Host "Built $outputPath"
