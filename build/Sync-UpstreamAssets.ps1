[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [int]$PreferredNodeMajor = 24,
    [int]$MinimumNodeMajor = 22
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$resourcesRoot = Join-Path $RepositoryRoot 'installer\resources'
$upstreamRoot = Join-Path $resourcesRoot 'upstream'
$manifestRoot = Join-Path $resourcesRoot 'manifests'

New-Item -ItemType Directory -Force -Path $upstreamRoot | Out-Null
New-Item -ItemType Directory -Force -Path $manifestRoot | Out-Null

$officialInstallUrl = 'https://openclaw.ai/install.ps1'
$officialInstallPath = Join-Path $upstreamRoot 'openclaw-install.ps1'
$officialManifestPath = Join-Path $upstreamRoot 'openclaw-install.manifest.json'
$dependencyManifestPath = Join-Path $manifestRoot 'dependencies.json'

Write-Host "Syncing official OpenClaw installer script from $officialInstallUrl"
Invoke-WebRequest -UseBasicParsing -Uri $officialInstallUrl -OutFile $officialInstallPath

$officialHash = (Get-FileHash -Path $officialInstallPath -Algorithm SHA256).Hash
[ordered]@{
    sourceUrl = $officialInstallUrl
    downloadedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    sha256 = $officialHash
} | ConvertTo-Json -Depth 4 | Set-Content -Path $officialManifestPath -Encoding UTF8

Write-Host "Resolving latest Node.js LTS metadata"
$nodeIndex = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json'
$candidate = $nodeIndex |
    Where-Object {
        $_.lts -and $_.version -match "^v$PreferredNodeMajor\." -and $_.files -contains 'win-x64-msi'
    } |
    Select-Object -First 1

if (-not $candidate) {
    $candidate = $nodeIndex |
        Where-Object {
            $_.lts -and $_.version -match "^v$MinimumNodeMajor\." -and $_.files -contains 'win-x64-msi'
        } |
        Select-Object -First 1
}

if (-not $candidate) {
    throw "Unable to resolve a Windows x64 MSI for Node.js major $PreferredNodeMajor or fallback major $MinimumNodeMajor."
}

$nodeTag = $candidate.version
$nodeVersion = $nodeTag.TrimStart('v')
$nodeBaseUrl = "https://nodejs.org/dist/$($candidate.version)"
$nodeMsiName = "node-$nodeTag-x64.msi"
$nodeMsiUrl = "$nodeBaseUrl/$nodeMsiName"
$shasums = Invoke-WebRequest -UseBasicParsing -Uri "$nodeBaseUrl/SHASUMS256.txt"
$shaLine = ($shasums.Content -split "`n" | Where-Object { $_ -match [regex]::Escape($nodeMsiName) } | Select-Object -First 1)

if (-not $shaLine) {
    throw "Unable to resolve SHA256 for $nodeMsiName."
}

$nodeHash = ($shaLine -split '\s+')[0].Trim()

Write-Host 'Resolving latest Git for Windows metadata'
$gitRelease = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest'
$gitInstallerAsset = $gitRelease.assets | Where-Object { $_.name -match '^Git-.*-64-bit\.exe$' } | Select-Object -First 1
if (-not $gitInstallerAsset) {
    throw 'Unable to resolve a Git for Windows x64 installer asset.'
}

$gitDownloadRoot = Join-Path $env:TEMP 'OpenClawInstaller\GitManifest'
$gitInstallerPath = Join-Path $gitDownloadRoot $gitInstallerAsset.name
New-Item -ItemType Directory -Force -Path $gitDownloadRoot | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri $gitInstallerAsset.browser_download_url -OutFile $gitInstallerPath
$gitHash = (Get-FileHash -Path $gitInstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
$gitVersion = ($gitInstallerAsset.name -replace '^Git-(.*)-64-bit\.exe$', '$1')

[ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    node = [ordered]@{
        preferredMajor = $PreferredNodeMajor
        minimumMajor = $MinimumNodeMajor
        version = $nodeVersion
        msiUrl = $nodeMsiUrl
        sha256 = $nodeHash
    }
    git = [ordered]@{
        version = $gitVersion
        installerUrl = $gitInstallerAsset.browser_download_url
        installerSha256 = $gitHash
    }
    webview2 = [ordered]@{
        packagedInstallerRelativePath = 'resources\\tools\\webview2\\MicrosoftEdgeWebView2RuntimeInstallerX64.exe'
        bootstrapperUrl = $env:OPENCLAW_WEBVIEW2_BOOTSTRAPPER_URL
        downloadPage = 'https://developer.microsoft.com/en-us/microsoft-edge/webview2/#download-the-webview2-runtime'
        installerCommand = 'MicrosoftEdgeWebView2RuntimeInstallerX64.exe /silent /install'
    }
} | ConvertTo-Json -Depth 5 | Set-Content -Path $dependencyManifestPath -Encoding UTF8

Write-Host "Wrote $officialInstallPath"
Write-Host "Wrote $officialManifestPath"
Write-Host "Wrote $dependencyManifestPath"
