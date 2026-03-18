[CmdletBinding()]
param(
    [string]$ManifestPath,
    [switch]$AsJson
)

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

Refresh-ProcessPath

$manifest = $null
if ($ManifestPath -and (Test-Path $ManifestPath)) {
    $manifest = Read-JsonFile -Path $ManifestPath
}

$minimumNodeMajor = if ($manifest) { [int]$manifest.node.minimumMajor } else { 22 }
$nodeInfo = Get-NodeVersionInfo
$npmPath = Get-CommandPath -Candidates @('npm.cmd', 'npm.exe', 'npm')
$gitPath = Get-GitCommandPath
$openclawPath = Get-OpenClawCommandPath
$edgePath = Get-EdgePath

$result = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    isAdministrator = (
        New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    powershellMajor = $PSVersionTable.PSVersion.Major
    node = [ordered]@{
        installed = [bool]$nodeInfo
        version = if ($nodeInfo) { $nodeInfo.raw } else { $null }
        major = if ($nodeInfo) { $nodeInfo.major } else { $null }
        meetsMinimum = [bool]($nodeInfo -and $nodeInfo.major -ge $minimumNodeMajor)
        minimumMajor = $minimumNodeMajor
    }
    npm = [ordered]@{
        installed = [bool]$npmPath
        path = $npmPath
    }
    git = [ordered]@{
        installed = [bool]$gitPath
        path = $gitPath
    }
    openclaw = [ordered]@{
        installed = [bool]$openclawPath
        path = $openclawPath
    }
    edge = [ordered]@{
        installed = [bool]$edgePath
        path = $edgePath
    }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
} else {
    [pscustomobject]$result
}
