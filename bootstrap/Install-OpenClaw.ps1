[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$ManifestPath,
    [string]$OfficialScriptPath,
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw',
    [string]$Channel = 'latest'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\Installer.Common.ps1')

if (-not $InstallRoot) {
    $InstallRoot = Split-Path -Parent $PSScriptRoot
}

if (-not $ManifestPath) {
    $ManifestPath = Join-Path $InstallRoot 'resources\manifests\dependencies.json'
}
if (-not $OfficialScriptPath) {
    $OfficialScriptPath = Join-Path $InstallRoot 'resources\upstream\openclaw-install.ps1'
}
if (-not $LauncherPath) {
    $LauncherPath = Join-Path $InstallRoot 'bin\OpenClawLauncher.exe'
}

$logRoot = Join-Path $env:ProgramData 'OpenClawInstaller\Logs'
$stateRoot = Join-Path $env:ProgramData 'OpenClawInstaller'
$statePath = Join-Path $stateRoot 'install-state.json'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

$logPath = Join-Path $logRoot ("install-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$state = New-InstallState
Save-InstallState -State $state -Path $statePath

Start-Transcript -Path $logPath -Force | Out-Null

$exitCode = 0

try {
    Write-Stage -StageId 'start' -Percent 2 -Message 'Starting OpenClaw installation.'
    Assert-Administrator

    Write-Stage -StageId 'cleanup' -Percent 8 -Message 'Cleaning previous OpenClaw files.'
    & (Join-Path $repositoryRoot 'scripts\Remove-Residuals.ps1') -StatePath $statePath -ShortcutName $ShortcutName | Out-Null

    Write-Stage -StageId 'preflight' -Percent 16 -Message 'Checking system prerequisites.'
    $preflight = & (Join-Path $repositoryRoot 'scripts\Test-Prerequisites.ps1') -ManifestPath $ManifestPath
    Write-Log -Message ("Preflight: Node installed={0}, npm installed={1}, Git installed={2}, Edge installed={3}" -f `
        $preflight.node.installed, $preflight.npm.installed, $preflight.git.installed, $preflight.edge.installed)

    if (-not $preflight.edge.installed) {
        throw 'Microsoft Edge is required on Windows 10/11 to host the OpenClaw dashboard window.'
    }

    $additionalPathEntries = @()
    if ((-not $preflight.node.meetsMinimum) -or (-not $preflight.git.installed)) {
        Write-Stage -StageId 'dependencies' -Percent 30 -Message 'Installing runtime dependencies.'
    }

    if (-not $preflight.node.meetsMinimum) {
        $nodeInstall = & (Join-Path $repositoryRoot 'scripts\Install-Node.ps1') -ManifestPath $ManifestPath
        $state.nodeInstalledByBootstrap = $nodeInstall.installedByBootstrap
        $state.nodeProductCode = $nodeInstall.productCode
        Save-InstallState -State $state -Path $statePath
    } else {
        Write-Log -Message 'Node.js already satisfies the minimum requirement; skipping dependency install.'
    }

    if (-not $preflight.git.installed) {
        $gitInstall = & (Join-Path $repositoryRoot 'scripts\Install-Git.ps1') -ManifestPath $ManifestPath
        $state.gitInstalledByBootstrap = $gitInstall.installedByBootstrap
        $state.gitUninstallerPath = $gitInstall.uninstallerPath
        Save-InstallState -State $state -Path $statePath
        $additionalPathEntries = @($gitInstall.pathEntries)
    } else {
        Write-Log -Message 'Git already satisfies the installer requirement; skipping dependency install.'
    }

    Write-Stage -StageId 'official-install' -Percent 52 -Message 'Running official OpenClaw installer.'
    & (Join-Path $repositoryRoot 'scripts\Invoke-OfficialInstall.ps1') `
        -OfficialScriptPath $OfficialScriptPath `
        -Channel $Channel `
        -InstallMethod npm `
        -AdditionalPathEntries $additionalPathEntries `
        -SkipOnboard

    $state.officialInstallComplete = $true
    Save-InstallState -State $state -Path $statePath

    Write-Stage -StageId 'onboarding' -Percent 72 -Message 'Configuring local OpenClaw gateway.'
    $token = New-RandomBase64Token
    & (Join-Path $repositoryRoot 'scripts\Invoke-OpenClawOnboarding.ps1') -GatewayToken $token | Out-Null

    $state.onboardingComplete = $true
    Save-InstallState -State $state -Path $statePath

    Write-Stage -StageId 'shortcuts' -Percent 84 -Message 'Creating desktop and Start menu shortcuts.'
    $shortcuts = & (Join-Path $repositoryRoot 'scripts\Create-Shortcuts.ps1') -LauncherPath $LauncherPath -ShortcutName $ShortcutName
    $state.shortcuts = @($shortcuts.desktopShortcut, $shortcuts.startMenuShortcut)
    Save-InstallState -State $state -Path $statePath

    Write-Stage -StageId 'verification' -Percent 92 -Message 'Launching OpenClaw and validating the window.'
    & (Join-Path $repositoryRoot 'scripts\Test-OpenClawReady.ps1') -LauncherPath $LauncherPath -ShortcutName $ShortcutName | Out-Null

    $state.launcherValidated = $true
    Save-InstallState -State $state -Path $statePath

    Write-Stage -StageId 'complete' -Percent 100 -Message 'OpenClaw is installed and ready to use.'
    Write-Log -Message "OpenClaw installation succeeded. Log: $logPath" -Level 'SUCCESS'
} catch {
    $exitCode = 1
    $state.lastError = $_.Exception.Message
    Save-InstallState -State $state -Path $statePath
    Write-Log -Message "Installation failed: $($_.Exception.Message)" -Level 'ERROR'

    try {
        & (Join-Path $repositoryRoot 'scripts\Remove-Residuals.ps1') -StatePath $statePath -ShortcutName $ShortcutName -RemoveManagedNode -RemoveManagedGit
    } catch {
        Write-Log -Message "Rollback reported an additional error: $($_.Exception.Message)" -Level 'WARN'
    }
} finally {
    Stop-Transcript | Out-Null
}

exit $exitCode


