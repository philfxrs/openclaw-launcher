[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$version = '1.0.3719.77'
$packageRoot = Join-Path $RepositoryRoot ('resources\webview2\' + $version)
$requiredFiles = @(
    'Microsoft.Web.WebView2.Core.dll',
    'Microsoft.Web.WebView2.WinForms.dll',
    'WebView2Loader.dll'
)

$allPresent = $true
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path (Join-Path $packageRoot $requiredFile))) {
        $allPresent = $false
        break
    }
}

if (-not $allPresent) {
    $downloadRoot = Join-Path $env:TEMP 'OpenClawInstaller\WebView2'
    $packagePath = Join-Path $downloadRoot ("Microsoft.Web.WebView2." + $version + '.nupkg')
    $zipPath = Join-Path $downloadRoot ("Microsoft.Web.WebView2." + $version + '.zip')
    $extractRoot = Join-Path $downloadRoot ('extract-' + $version)
    $packageUrl = "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$version"

    New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null

    if (-not (Test-Path $packagePath)) {
        Write-Host "Downloading WebView2 SDK $version"
        Invoke-WebRequest -UseBasicParsing -Uri $packageUrl -OutFile $packagePath
    }

    Copy-Item -Path $packagePath -Destination $zipPath -Force
    if (Test-Path $extractRoot) {
        Remove-Item -Path $extractRoot -Recurse -Force
    }
    Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force

    Copy-Item -Path (Join-Path $extractRoot 'lib\net462\Microsoft.Web.WebView2.Core.dll') -Destination $packageRoot -Force
    Copy-Item -Path (Join-Path $extractRoot 'lib\net462\Microsoft.Web.WebView2.WinForms.dll') -Destination $packageRoot -Force
    Copy-Item -Path (Join-Path $extractRoot 'runtimes\win-x64\native\WebView2Loader.dll') -Destination $packageRoot -Force
}

return [pscustomobject]@{
    version = $version
    packageRoot = $packageRoot
    coreDll = (Join-Path $packageRoot 'Microsoft.Web.WebView2.Core.dll')
    winFormsDll = (Join-Path $packageRoot 'Microsoft.Web.WebView2.WinForms.dll')
    loaderDll = (Join-Path $packageRoot 'WebView2Loader.dll')
}
