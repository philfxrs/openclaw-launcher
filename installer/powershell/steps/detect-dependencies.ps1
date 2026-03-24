# detect-dependencies.ps1 — Steps 5-8: Dependency Detection
# Detects Node.js, npm, Git, WebView2, OpenClaw, Edge.
# Returns an ordered hashtable with detection results for each dependency.

[CmdletBinding()]
param(
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1')

Refresh-ProcessPath

$manifest = $null
if ($ManifestPath -and (Test-Path $ManifestPath)) {
    $manifest = Read-JsonFile -Path $ManifestPath
}

$minimumNodeMajor = if ($manifest -and $manifest.node -and $manifest.node.minimumMajor) {
    [int]$manifest.node.minimumMajor
} else {
    22
}

# ── Step 5: Node.js ──────────────────────────────────────────────────────
$nodeInfo = Get-NodeVersionInfo
$nodeResult = [ordered]@{
    installed    = [bool]$nodeInfo
    version      = if ($nodeInfo) { $nodeInfo.raw } else { $null }
    major        = if ($nodeInfo) { $nodeInfo.major } else { $null }
    meetsMinimum = [bool]($nodeInfo -and $nodeInfo.major -ge $minimumNodeMajor)
    minimumMajor = $minimumNodeMajor
}
Write-Log -Message ("Node.js: installed={0}, version={1}, meetsMinimum={2}" -f $nodeResult.installed, $nodeResult.version, $nodeResult.meetsMinimum)

# ── Step 6: npm ──────────────────────────────────────────────────────────
$npmPath = Get-CommandPath -Candidates @('npm.cmd', 'npm.exe', 'npm')
$npmResult = [ordered]@{
    installed = [bool]$npmPath
    path      = $npmPath
}
Write-Log -Message ("npm: installed={0}, path={1}" -f $npmResult.installed, $npmResult.path)

# ── Step 7: Git ──────────────────────────────────────────────────────────
$gitPath = Get-GitCommandPath
$gitResult = [ordered]@{
    installed = [bool]$gitPath
    path      = $gitPath
}
Write-Log -Message ("Git: installed={0}, path={1}" -f $gitResult.installed, $gitResult.path)

# ── Step 8: Other Dependencies (WebView2, Edge, OpenClaw) ────────────────
$webView2Version = Get-WebView2RuntimeVersion
$openclawPath    = Get-OpenClawCommandPath
$edgePath        = Get-EdgePath

$webview2Result = [ordered]@{
    installed = [bool]$webView2Version
    version   = $webView2Version
}

$openclawResult = [ordered]@{
    installed = [bool]$openclawPath
    path      = $openclawPath
}

$edgeResult = [ordered]@{
    installed = [bool]$edgePath
    path      = $edgePath
}

Write-Log -Message ("WebView2: installed={0}, version={1}" -f $webview2Result.installed, $webview2Result.version)
Write-Log -Message ("OpenClaw: installed={0}, path={1}" -f $openclawResult.installed, $openclawResult.path)
Write-Log -Message ("Edge: installed={0}" -f $edgeResult.installed)

# ── Summary ──────────────────────────────────────────────────────────────
$result = [ordered]@{
    generatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    isAdministrator = (
        New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    powershellMajor = $PSVersionTable.PSVersion.Major
    node            = $nodeResult
    npm             = $npmResult
    git             = $gitResult
    webview2        = $webview2Result
    openclaw        = $openclawResult
    edge            = $edgeResult
}

$missing = @()
if (-not $nodeResult.meetsMinimum) { $missing += 'Node.js' }
if (-not $gitResult.installed)     { $missing += 'Git' }
if (-not $webview2Result.installed) { $missing += 'WebView2 Runtime' }

if ($missing.Count -gt 0) {
    Write-Log -Message ("Missing dependencies: {0}" -f ([string]::Join(', ', $missing))) -Level 'WARN'
} else {
    Write-Log -Message 'All runtime dependencies are present.' -Level 'SUCCESS'
}

return [pscustomobject]$result
