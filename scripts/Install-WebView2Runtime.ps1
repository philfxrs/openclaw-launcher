[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath
)

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

$manifest = Read-JsonFile -Path $ManifestPath
$existingVersion = Get-WebView2RuntimeVersion
if ($existingVersion) {
    Write-Log -Message ("WebView2 Runtime already installed: {0}" -f $existingVersion) -Level 'SUCCESS'
    return [pscustomobject]@{
        installedByBootstrap = $false
        version = $existingVersion
        source = 'existing'
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$webView2Manifest = $manifest.webview2
$packagedRelativePath = if ($webView2Manifest -and $webView2Manifest.packagedInstallerRelativePath) {
    [string]$webView2Manifest.packagedInstallerRelativePath
} else {
    'resources\tools\webview2\MicrosoftEdgeWebView2RuntimeInstallerX64.exe'
}

$packagedInstallerPath = Join-Path $repositoryRoot $packagedRelativePath
$downloadUrl = if ($webView2Manifest -and $webView2Manifest.bootstrapperUrl) {
    [string]$webView2Manifest.bootstrapperUrl
} else {
    $null
}

$installerPath = $null
$source = $null

if (Test-Path $packagedInstallerPath) {
    $installerPath = $packagedInstallerPath
    $source = 'packaged'
} elseif (-not [string]::IsNullOrWhiteSpace($downloadUrl)) {
    $downloadDirectory = Join-Path $env:TEMP 'OpenClawInstaller'
    $installerPath = Join-Path $downloadDirectory 'MicrosoftEdgeWebView2Setup.exe'
    New-Item -ItemType Directory -Force -Path $downloadDirectory | Out-Null

    Write-Log -Message ("Downloading WebView2 Runtime bootstrapper from {0}" -f $downloadUrl)
    Invoke-Retry -Description 'WebView2 Runtime bootstrapper download' -Action {
        Invoke-WebRequest -UseBasicParsing -Uri $downloadUrl -OutFile $installerPath
    }

    $source = 'downloaded-bootstrapper'
} else {
    throw (New-InstallerException -Code 'E2005' -Message 'WebView2 Runtime is missing and no bootstrapper source is configured. Package MicrosoftEdgeWebView2RuntimeInstallerX64.exe under resources/tools/webview2 or set manifest.webview2.bootstrapperUrl during build.')
}

Write-Log -Message ("Installing WebView2 Runtime from {0}" -f $installerPath)
Invoke-ExternalCommand -FilePath $installerPath -Arguments @('/silent', '/install') | Out-Null

$installedVersion = Get-WebView2RuntimeVersion
if (-not $installedVersion) {
    throw (New-InstallerException -Code 'E2005' -Message 'WebView2 Runtime installer completed, but the runtime is still not detected.')
}

Write-Log -Message ("WebView2 Runtime verified: {0}" -f $installedVersion) -Level 'SUCCESS'

return [pscustomobject]@{
    installedByBootstrap = $true
    version = $installedVersion
    source = $source
}