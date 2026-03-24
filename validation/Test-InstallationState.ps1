[CmdletBinding()]
param(
    [string]$ManifestPath,
    [Parameter(Mandatory = $true)]
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw',
    [ValidateSet('Prerequisites', 'Installed', 'Launch')]
    [string]$Scenario = 'Installed'
)

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\Installer.Common.ps1')

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

$nodeInfo = Get-NodeVersionInfo
$npmPath = Get-CommandPath -Candidates @('npm.cmd', 'npm.exe', 'npm')
$gitPath = Get-GitCommandPath
$openclawPath = Get-OpenClawCommandPath
$webView2Version = Get-WebView2RuntimeVersion
$desktopShortcut = Get-DesktopShortcutPath -ShortcutName $ShortcutName
$startMenuShortcut = Get-StartMenuShortcutPath -ShortcutName $ShortcutName
$shortcutTargetValid = $false

if (Test-Path $desktopShortcut) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $desktopShortcutObject = $shell.CreateShortcut($desktopShortcut)
        $shortcutTargetValid = [bool]($desktopShortcutObject.TargetPath -and (Test-Path $desktopShortcutObject.TargetPath))
    } catch {
        $shortcutTargetValid = $false
    }
}

$result = [ordered]@{
    scenario = $Scenario
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
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
    webview2 = [ordered]@{
        installed = [bool]$webView2Version
        version = $webView2Version
    }
    openclaw = [ordered]@{
        installed = [bool]$openclawPath
        path = $openclawPath
    }
    launcher = [ordered]@{
        exists = [bool](Test-Path $LauncherPath)
        path = $LauncherPath
    }
    shortcuts = [ordered]@{
        desktopExists = [bool](Test-Path $desktopShortcut)
        desktopPath = $desktopShortcut
        desktopTargetValid = $shortcutTargetValid
        startMenuExists = [bool](Test-Path $startMenuShortcut)
        startMenuPath = $startMenuShortcut
    }
}

if (-not $result.node.meetsMinimum) {
    $detectedNodeVersion = if ($result.node.version) { $result.node.version } else { 'missing' }
    throw (New-InstallerException -Code 'E2002' -Message ("Node.js v{0}+ is required, but validation found {1}." -f $minimumNodeMajor, $detectedNodeVersion))
}

if (-not $result.npm.installed) {
    throw (New-InstallerException -Code 'E2003' -Message 'npm is not available after dependency installation.')
}

if (-not $result.git.installed) {
    throw (New-InstallerException -Code 'E2004' -Message 'Git is not available after dependency installation.')
}

if (-not $result.webview2.installed) {
    throw (New-InstallerException -Code 'E2005' -Message 'WebView2 Runtime is not installed. The desktop launcher requires the Evergreen WebView2 Runtime.')
}

if ($Scenario -in @('Installed', 'Launch')) {
    if (-not $result.openclaw.installed) {
        throw (New-InstallerException -Code 'E3003' -Message 'OpenClaw CLI is not available after the official install step.')
    }

    if (-not $result.launcher.exists) {
        throw (New-InstallerException -Code 'E3003' -Message ("Launcher executable is missing: {0}" -f $LauncherPath))
    }
}

if ($Scenario -eq 'Launch') {
    if (-not $result.shortcuts.desktopExists) {
        throw (New-InstallerException -Code 'E4002' -Message 'Desktop shortcut is missing after shortcut creation step.')
    }

    if (-not $result.shortcuts.desktopTargetValid) {
        throw (New-InstallerException -Code 'E4002' -Message 'Desktop shortcut target is invalid after shortcut creation step.')
    }

    & (Join-Path $repositoryRoot 'scripts\Test-OpenClawReady.ps1') -LauncherPath $LauncherPath -ShortcutName $ShortcutName | Out-Null
}

Write-Log -Message ("Validation succeeded for scenario {0}." -f $Scenario) -Level 'SUCCESS'
return [pscustomobject]$result