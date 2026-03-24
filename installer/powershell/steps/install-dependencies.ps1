# install-dependencies.ps1 — Step 9: Install Missing Dependencies
# Downloads and silently installs Node.js, Git for Windows, and WebView2 Runtime
# as needed. Returns an object describing what was installed.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1')

$manifest = Read-JsonFile -Path $ManifestPath
$downloadDir = Join-Path $env:TEMP 'OpenClawInstaller'
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

$results = [ordered]@{
    node     = $null
    git      = $null
    webview2 = $null
    additionalPathEntries = @()
}

# ══════════════════════════════════════════════════════════════════════════
#  Node.js
# ══════════════════════════════════════════════════════════════════════════

$minimumNodeMajor = [int]$manifest.node.minimumMajor
$nodeInfo = Get-NodeVersionInfo

if ($nodeInfo -and $nodeInfo.major -ge $minimumNodeMajor) {
    Write-Log -Message "Node.js already satisfies minimum requirement: $($nodeInfo.raw)" -Level 'SUCCESS'
    $results.node = [pscustomobject]@{
        installedByBootstrap = $false
        productCode          = $null
        version              = $nodeInfo.raw
    }
} else {
    $nodeMsiPath = Join-Path $downloadDir ("node-" + $manifest.node.version + "-x64.msi")

    Write-Log -Message "Downloading Node.js $($manifest.node.version) from $($manifest.node.msiUrl)"
    Invoke-Retry -Description 'Node.js MSI download' -Action {
        Invoke-WebRequest -UseBasicParsing -Uri $manifest.node.msiUrl -OutFile $nodeMsiPath
    }

    $hash = (Get-FileHash -Path $nodeMsiPath -Algorithm SHA256).Hash
    if ($hash -ne $manifest.node.sha256) {
        throw (New-InstallerException -Code 'E2002' -Message (
            "Node.js MSI SHA256 mismatch. Expected {0}, got {1}." -f $manifest.node.sha256, $hash
        ))
    }

    Write-Log -Message 'Installing Node.js silently via msiexec'
    Invoke-ExternalCommand -FilePath 'msiexec.exe' -Arguments @('/i', $nodeMsiPath, '/qn', '/norestart')
    Refresh-ProcessPath

    $nodeInfo = Get-NodeVersionInfo
    if (-not $nodeInfo -or $nodeInfo.major -lt $minimumNodeMajor) {
        throw (New-InstallerException -Code 'E2002' -Message 'Node.js installation completed but node.exe is still unavailable or below minimum version.')
    }

    $productCode = $null
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($key in $uninstallKeys) {
        $entry = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -eq 'Node.js' } |
            Sort-Object DisplayVersion -Descending |
            Select-Object -First 1

        if ($entry -and $entry.UninstallString -match '{[^}]+}') {
            $productCode = $matches[0]
            break
        }
    }

    Write-Log -Message "Node.js $($nodeInfo.raw) installed successfully." -Level 'SUCCESS'
    $results.node = [pscustomobject]@{
        installedByBootstrap = $true
        productCode          = $productCode
        version              = $nodeInfo.raw
    }
}

# ══════════════════════════════════════════════════════════════════════════
#  Git for Windows
# ══════════════════════════════════════════════════════════════════════════

function Get-GitInstallRoot {
    foreach ($candidate in @('C:\Program Files\Git', 'C:\Program Files (x86)\Git')) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Get-GitUninstallerPath {
    $entries = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -eq 'Git' -and
            $_.PSObject.Properties['UninstallString'] -and $_.UninstallString
        }

    foreach ($entry in $entries) {
        if ($entry.UninstallString -match '"([^"]+unins\d+\.exe)"') {
            $candidate = $matches[1]
            if (Test-Path $candidate) { return $candidate }
        }
    }

    $installRoot = Get-GitInstallRoot
    if ($installRoot) {
        $fallback = Join-Path $installRoot 'unins000.exe'
        if (Test-Path $fallback) { return $fallback }
    }

    return $null
}

function Get-GitPathEntries {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    return @(
        (Join-Path $InstallRoot 'cmd'),
        (Join-Path $InstallRoot 'mingw64\bin'),
        (Join-Path $InstallRoot 'usr\bin')
    ) | Where-Object { Test-Path $_ }
}

function Wait-ForGitInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$InstallerBaseName,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $gitPath = Get-GitCommandPath
        $installerProcs = @(
            Get-CimInstance Win32_Process -Filter ("Name LIKE '{0}%'" -f $InstallerBaseName.Replace("'", "''")) -ErrorAction SilentlyContinue
        )

        if ($gitPath -and $installerProcs.Count -eq 0) { return $gitPath }
        Start-Sleep -Seconds 2
        Refresh-ProcessPath
    }

    throw (New-InstallerException -Code 'E2005' -Message "Git installer did not finish within $TimeoutSeconds seconds.")
}

$existingGit = Get-GitCommandPath
if ($existingGit) {
    Write-Log -Message "Git already available: $existingGit" -Level 'SUCCESS'
    $results.git = [pscustomobject]@{
        installedByBootstrap = $false
        gitPath              = $existingGit
        pathEntries          = @()
        uninstallerPath      = (Get-GitUninstallerPath)
    }
} else {
    $gitInfo = $manifest.git
    if (-not $gitInfo -or -not $gitInfo.installerUrl) {
        throw (New-InstallerException -Code 'E2005' -Message 'Git metadata is missing from the dependency manifest. Run Sync-UpstreamAssets.ps1 first.')
    }

    $installerPath = Join-Path $downloadDir ("Git-" + $gitInfo.version + "-64-bit.exe")

    if (-not (Test-Path $installerPath)) {
        Write-Log -Message "Downloading Git for Windows $($gitInfo.version) from $($gitInfo.installerUrl)"
        Invoke-Retry -Description 'Git installer download' -Action {
            Invoke-WebRequest -UseBasicParsing -Uri $gitInfo.installerUrl -OutFile $installerPath
        }
    }

    $gitHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($gitHash -ne $gitInfo.installerSha256.ToLowerInvariant()) {
        Remove-Item -Force $installerPath -ErrorAction SilentlyContinue
        throw (New-InstallerException -Code 'E2005' -Message (
            "Git installer SHA256 mismatch. Expected {0}, got {1}." -f $gitInfo.installerSha256, $gitHash
        ))
    }

    $installerArgs = @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-',
        '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS',
        '/o:PathOption=Cmd', '/o:SSHOption=OpenSSH', '/o:CURLOption=WinSSL'
    )

    Write-Log -Message "Installing Git for Windows $($gitInfo.version) silently"
    $proc = Start-Process -FilePath $installerPath -ArgumentList $installerArgs -WindowStyle Hidden -PassThru
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($installerPath)
    $gitPath = Wait-ForGitInstaller -InstallerBaseName $baseName

    Refresh-ProcessPath
    $gitPath = Get-GitCommandPath
    if (-not $gitPath) {
        throw (New-InstallerException -Code 'E2005' -Message 'Git installer completed, but git.exe is still unavailable.')
    }

    $installRoot = Get-GitInstallRoot
    if (-not $installRoot) {
        throw (New-InstallerException -Code 'E2005' -Message 'Git installer completed, but install directory not found.')
    }

    $pathEntries = Get-GitPathEntries -InstallRoot $installRoot
    $uninstallerPath = Get-GitUninstallerPath

    Write-Log -Message "Git for Windows ready: $gitPath" -Level 'SUCCESS'
    $results.git = [pscustomobject]@{
        installedByBootstrap = $true
        gitPath              = $gitPath
        pathEntries          = $pathEntries
        installRoot          = $installRoot
        uninstallerPath      = $uninstallerPath
    }
    $results.additionalPathEntries = @($pathEntries)
}

# ══════════════════════════════════════════════════════════════════════════
#  WebView2 Runtime
# ══════════════════════════════════════════════════════════════════════════

$existingWv2 = Get-WebView2RuntimeVersion
if ($existingWv2) {
    Write-Log -Message "WebView2 Runtime already installed: $existingWv2" -Level 'SUCCESS'
    $results.webview2 = [pscustomobject]@{
        installedByBootstrap = $false
        version              = $existingWv2
        source               = 'existing'
    }
} else {
    $wv2Manifest = $manifest.webview2
    $packagedRelPath = if ($wv2Manifest -and $wv2Manifest.packagedInstallerRelativePath) {
        [string]$wv2Manifest.packagedInstallerRelativePath
    } else {
        'resources\tools\webview2\MicrosoftEdgeWebView2RuntimeInstallerX64.exe'
    }

    $packagedPath = Join-Path $script:InstallerRoot $packagedRelPath
    $bootstrapperUrl = if ($wv2Manifest -and $wv2Manifest.bootstrapperUrl) {
        [string]$wv2Manifest.bootstrapperUrl
    } else {
        $null
    }

    $wv2InstallerPath = $null
    $wv2Source = $null

    if (Test-Path $packagedPath) {
        $wv2InstallerPath = $packagedPath
        $wv2Source = 'packaged'
    } elseif (-not [string]::IsNullOrWhiteSpace($bootstrapperUrl)) {
        $wv2InstallerPath = Join-Path $downloadDir 'MicrosoftEdgeWebView2Setup.exe'
        Write-Log -Message "Downloading WebView2 Runtime bootstrapper from $bootstrapperUrl"
        Invoke-Retry -Description 'WebView2 bootstrapper download' -Action {
            Invoke-WebRequest -UseBasicParsing -Uri $bootstrapperUrl -OutFile $wv2InstallerPath
        }
        $wv2Source = 'downloaded-bootstrapper'
    } else {
        throw (New-InstallerException -Code 'E2006' -Message (
            'WebView2 Runtime is missing and no installer source is configured. ' +
            'Package MicrosoftEdgeWebView2RuntimeInstallerX64.exe or set manifest.webview2.bootstrapperUrl.'
        ))
    }

    Write-Log -Message "Installing WebView2 Runtime from $wv2InstallerPath"
    Invoke-ExternalCommand -FilePath $wv2InstallerPath -Arguments @('/silent', '/install') | Out-Null

    $installedVersion = Get-WebView2RuntimeVersion
    if (-not $installedVersion) {
        throw (New-InstallerException -Code 'E2006' -Message 'WebView2 installer completed, but the runtime is still not detected.')
    }

    Write-Log -Message "WebView2 Runtime verified: $installedVersion" -Level 'SUCCESS'
    $results.webview2 = [pscustomobject]@{
        installedByBootstrap = $true
        version              = $installedVersion
        source               = $wv2Source
    }
}

return [pscustomobject]$results
