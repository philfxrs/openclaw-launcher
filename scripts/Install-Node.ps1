[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath
)

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

$manifest = Read-JsonFile -Path $ManifestPath
$nodeInfo = Get-NodeVersionInfo
$minimumNodeMajor = [int]$manifest.node.minimumMajor

if ($nodeInfo -and $nodeInfo.major -ge $minimumNodeMajor) {
    Write-Log -Message "Node.js already satisfies minimum requirement: $($nodeInfo.raw)" -Level 'SUCCESS'
    return [pscustomobject]@{
        installedByBootstrap = $false
        productCode = $null
        version = $nodeInfo.raw
    }
}

$downloadDirectory = Join-Path $env:TEMP 'OpenClawInstaller'
New-Item -ItemType Directory -Force -Path $downloadDirectory | Out-Null

$nodeMsiPath = Join-Path $downloadDirectory ("node-" + $manifest.node.version + "-x64.msi")
Write-Log -Message "Downloading Node.js $($manifest.node.version) from $($manifest.node.msiUrl)"
Invoke-Retry -Description 'Node.js MSI download' -Action {
    Invoke-WebRequest -UseBasicParsing -Uri $manifest.node.msiUrl -OutFile $nodeMsiPath
}

$downloadHash = (Get-FileHash -Path $nodeMsiPath -Algorithm SHA256).Hash
if ($downloadHash -ne $manifest.node.sha256) {
    throw "Node.js MSI hash mismatch. Expected $($manifest.node.sha256), got $downloadHash."
}

Write-Log -Message 'Installing Node.js silently'
Invoke-ExternalCommand -FilePath 'msiexec.exe' -Arguments @(
    '/i',
    $nodeMsiPath,
    '/qn',
    '/norestart'
)

Refresh-ProcessPath

$nodeInfo = Get-NodeVersionInfo
if (-not $nodeInfo -or $nodeInfo.major -lt $minimumNodeMajor) {
    throw 'Node.js installation completed but node.exe is still unavailable or too old.'
}

$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$nodeEntry = foreach ($key in $uninstallKeys) {
    Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'Node.js' } |
        Sort-Object DisplayVersion -Descending |
        Select-Object -First 1
}

$nodeEntry = $nodeEntry | Select-Object -First 1
$productCode = $null
if ($nodeEntry -and $nodeEntry.UninstallString -match '{[^}]+}') {
    $productCode = $matches[0]
}

Write-Log -Message "Node.js installation verified: $($nodeInfo.raw)" -Level 'SUCCESS'

return [pscustomobject]@{
    installedByBootstrap = $true
    productCode = $productCode
    version = $nodeInfo.raw
}
