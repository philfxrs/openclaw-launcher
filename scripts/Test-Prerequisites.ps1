[CmdletBinding()]
param(
    [string]$ManifestPath,
    [switch]$AsJson
)

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

Refresh-ProcessPath

function Get-CommandProbeResult {
    param(
        [string]$CommandPath,
        [string[]]$Arguments = @('--version')
    )

    if (-not $CommandPath) {
        return [pscustomobject]@{
            executable = $false
            version = $null
            issue = 'not-found'
        }
    }

    try {
        $probe = Invoke-ExternalCommand -FilePath $CommandPath -Arguments $Arguments -AllowNonZeroExit
        $versionText = $probe.StdOut.Trim()
        if ([string]::IsNullOrWhiteSpace($versionText)) {
            $versionText = $probe.StdErr.Trim()
        }

        return [pscustomobject]@{
            executable = ($probe.ExitCode -eq 0)
            version = $versionText
            issue = if ($probe.ExitCode -eq 0) { $null } else { 'non-zero-exit' }
        }
    } catch {
        return [pscustomobject]@{
            executable = $false
            version = $null
            issue = $_.Exception.Message
        }
    }
}

$manifest = $null
if ($ManifestPath -and (Test-Path $ManifestPath)) {
    $manifest = Read-JsonFile -Path $ManifestPath
}

$minimumNodeMajor = if ($manifest) { [int]$manifest.node.minimumMajor } else { 22 }
$nodePath = Get-NodeCommandPath
$nodeInfo = Get-NodeVersionInfo
$npmPath = Get-NpmCommandPath -ErrorAction SilentlyContinue
$gitPath = Get-GitCommandPath
$openclawPath = Get-OpenClawCommandPath
$edgePath = Get-EdgePath
$webView2Version = Get-WebView2RuntimeVersion
$npmProbe = Get-CommandProbeResult -CommandPath $npmPath
$gitProbe = Get-CommandProbeResult -CommandPath $gitPath

$result = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    isAdministrator = (
        New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    powershellMajor = $PSVersionTable.PSVersion.Major
    node = [ordered]@{
        installed = [bool]$nodeInfo
        path = $nodePath
        version = if ($nodeInfo) { $nodeInfo.raw } else { $null }
        major = if ($nodeInfo) { $nodeInfo.major } else { $null }
        meetsMinimum = [bool]($nodeInfo -and $nodeInfo.major -ge $minimumNodeMajor)
        minimumMajor = $minimumNodeMajor
        issue = if ($nodeInfo) {
            if ($nodeInfo.major -lt $minimumNodeMajor) { 'version-too-old' } else { $null }
        } else { 'not-found-or-not-executable' }
    }
    npm = [ordered]@{
        installed = [bool]($npmPath -and $npmProbe.executable)
        path = $npmPath
        version = $npmProbe.version
        executable = $npmProbe.executable
        issue = $npmProbe.issue
    }
    git = [ordered]@{
        installed = [bool]($gitPath -and $gitProbe.executable)
        path = $gitPath
        version = $gitProbe.version
        executable = $gitProbe.executable
        issue = $gitProbe.issue
    }
    webview2 = [ordered]@{
        installed = [bool]$webView2Version
        version = $webView2Version
        required = $true
        issue = if ($webView2Version) { $null } else { 'runtime-missing' }
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

Write-Log -Message ("Prerequisite summary: Node meetsMinimum={0}, npm executable={1}, Git executable={2}, WebView2 installed={3}" -f $result.node.meetsMinimum, $result.npm.executable, $result.git.executable, $result.webview2.installed)

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
} else {
    [pscustomobject]$result
}
