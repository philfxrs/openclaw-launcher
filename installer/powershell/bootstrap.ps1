[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$ManifestPath,
    [string]$OfficialScriptPath,
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw',
    [string]$Channel = 'latest',
    [ValidateSet('Auto', 'Repair', 'Overwrite', 'SkipIfPresent')]
    [string]$ExistingInstallAction = 'Auto',
    [switch]$SkipLaunchAfterInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'init.ps1')

if (-not $InstallRoot) {
    $InstallRoot = $script:InstallerRoot
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

$stateRoot = Join-Path $env:ProgramData 'OpenClawInstaller'
$logRoot = Join-Path $stateRoot 'Logs'
$statePath = Join-Path $stateRoot 'install-state.json'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

$existingState = Read-InstallState -Path $statePath
if ($existingState -and $existingState.schemaVersion -eq 2) {
    $state = $existingState
} else {
    $state = New-InstallState
}

$session = Initialize-InstallerSession -ProductName 'OpenClawInstaller' -LogRoot $logRoot
$state.installRoot = $InstallRoot
$state.mode = $ExistingInstallAction
$state.logPaths.text = $session.textLogPath
$state.logPaths.json = $session.jsonLogPath
$state.logPaths.transcript = $session.transcriptPath
Save-InstallState -State $state -Path $statePath

$exitCode = 0
$script:BootstrapAdditionalPathEntries = @()

function Save-State {
    Save-InstallState -State $state -Path $statePath
}

function Publish-InstallerFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ('@@OPENCLAW_ERROR|{0}|{1}' -f $Code, $Message)
}

function Invoke-InstallerPhase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StepId,
        [Parameter(Mandatory = $true)]
        [int]$StepNumber,
        [Parameter(Mandatory = $true)]
        [string]$StepName,
        [Parameter(Mandatory = $true)]
        [int]$Percent,
        [Parameter(Mandatory = $true)]
        [string]$FailureCode,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [switch]$AllowSkip
    )

    Set-InstallerStep -StepId $StepId -StepName $StepName -StepNumber $StepNumber
    Update-InstallStateStep -State $state -StepId $StepId -Status 'running' -Message $StepName
    Save-State
    Write-Stage -StageId $StepId -Percent $Percent -Message ('步骤 {0}/16: {1}' -f $StepNumber, $StepName)

    try {
        $result = & $Action
        if ($AllowSkip -and $null -eq $result) {
            Update-InstallStateStep -State $state -StepId $StepId -Status 'skipped' -Message ($StepName + ' skipped')
        } else {
            Update-InstallStateStep -State $state -StepId $StepId -Status 'completed' -Message $StepName
        }
        Save-State
        return $result
    } catch {
        $wrapped = New-InstallerException -Code $FailureCode -Message $_.Exception.Message -InnerException $_.Exception
        Update-InstallStateStep -State $state -StepId $StepId -Status 'failed' -Code $FailureCode -Message $wrapped.Message
        Save-State
        throw $wrapped
    }
}

function Resolve-OfficialInstallDecision {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Preflight,
        [bool]$ExistingInstallValidated
    )

    switch ($ExistingInstallAction) {
        'Overwrite' { return 'install' }
        'Repair' { return 'install' }
        'SkipIfPresent' {
            if ($Preflight.openclaw.installed) {
                return 'skip'
            }
            return 'install'
        }
        default {
            if ($Preflight.openclaw.installed -and $ExistingInstallValidated) {
                return 'skip'
            }
            return 'install'
        }
    }
}

trap {
    $exitCode = 1
    $errorCode = Get-InstallerErrorCode -Exception $_.Exception -DefaultCode 'E9001'

    $state.lastError = $_.Exception.Message
    $state.lastErrorCode = $errorCode
    Save-InstallState -State $state -Path $statePath

    Set-InstallerStep -StepId 'failure' -StepName '安装失败处理' -StepNumber 17
    Update-InstallStateStep -State $state -StepId 'failure' -Status 'completed' -Code $errorCode -Message $_.Exception.Message
    Save-State
    Write-Stage -StageId 'failure' -Percent 100 -Message ('步骤 17: 安装失败，错误码 {0}' -f $errorCode)
    Write-Log -Message ('Installation failed: {0}' -f $_.Exception.Message) -Level 'ERROR' -Code $errorCode

    Set-InstallerStep -StepId 'preserve-logs' -StepName '保留日志与错误码' -StepNumber 18
    Update-InstallStateStep -State $state -StepId 'preserve-logs' -Status 'completed' -Code $errorCode -Message 'State and logs preserved for retry.'
    Save-State
    Write-Log -Message 'Rollback policy: preserve-for-resume. No destructive cleanup performed.' -Level 'WARN' -Code 'E9001'
    Write-Log -Message ('日志文件: {0}' -f $state.logPaths.text) -Level 'INFO'
    Publish-InstallerFailure -Code $errorCode -Message $_.Exception.Message
    exit $exitCode
}

Write-Stage -StageId 'start' -Percent 0 -Message '正在启动 OpenClaw 安装'
Write-Log -Message 'OpenClaw bootstrap install started.'

$adminAction = {
    Assert-Administrator
    Write-Log -Message 'Administrator privileges confirmed.' -Level 'SUCCESS'
}
$null = Invoke-InstallerPhase -StepId 'admin' -StepNumber 2 -StepName '检查管理员权限' -Percent 3 -FailureCode 'E1002' -Action $adminAction

$loggingAction = {
    Write-Log -Message ('Text log: {0}' -f $state.logPaths.text) -Level 'SUCCESS'
    Write-Log -Message ('JSONL log: {0}' -f $state.logPaths.json) -Level 'SUCCESS'
}
$null = Invoke-InstallerPhase -StepId 'logging' -StepNumber 3 -StepName '初始化安装日志' -Percent 6 -FailureCode 'E1003' -Action $loggingAction

$systemInfoAction = {
    $sysInfo = [ordered]@{
        osVersion = [Environment]::OSVersion.VersionString
        is64BitOs = [Environment]::Is64BitOperatingSystem
        is64BitProcess = [Environment]::Is64BitProcess
        machineName = $env:COMPUTERNAME
        psVersion = $PSVersionTable.PSVersion.ToString()
        installRoot = $InstallRoot
    }
    Write-Log -Message 'System information collected.' -Data $sysInfo
    $state.system = $sysInfo
    Save-State
}
$null = Invoke-InstallerPhase -StepId 'system-info' -StepNumber 4 -StepName '收集系统信息' -Percent 10 -FailureCode 'E1004' -Action $systemInfoAction

$checkNodeAction = {
    Refresh-ProcessPath
    $nodeInfo = Get-NodeVersionInfo
    $minimumMajor = 22
    $versionText = 'N/A'
    if ($ManifestPath -and (Test-Path $ManifestPath)) {
        $manifest = Read-JsonFile -Path $ManifestPath
        $minimumMajor = [int]$manifest.node.minimumMajor
    }
    if ($nodeInfo) {
        $versionText = $nodeInfo.raw
    }
    $nodeOk = [bool]($nodeInfo -and $nodeInfo.major -ge $minimumMajor)
    Write-Log -Message ('Node.js: installed={0}, version={1}, meetsMinimum={2}' -f [bool]$nodeInfo, $versionText, $nodeOk)
}
$null = Invoke-InstallerPhase -StepId 'check-node' -StepNumber 5 -StepName '检查 Node.js' -Percent 15 -FailureCode 'E2001' -Action $checkNodeAction

$checkNpmAction = {
    $npmPath = Get-CommandPath -Candidates @('npm.cmd', 'npm.exe', 'npm')
    Write-Log -Message ('npm: installed={0}, path={1}' -f [bool]$npmPath, $npmPath)
}
$null = Invoke-InstallerPhase -StepId 'check-npm' -StepNumber 6 -StepName '检查 npm' -Percent 18 -FailureCode 'E2003' -Action $checkNpmAction

$checkGitAction = {
    $gitPath = Get-GitCommandPath
    Write-Log -Message ('Git: installed={0}, path={1}' -f [bool]$gitPath, $gitPath)
}
$null = Invoke-InstallerPhase -StepId 'check-git' -StepNumber 7 -StepName '检查 Git' -Percent 21 -FailureCode 'E2004' -Action $checkGitAction

$checkOtherAction = {
    $wv2 = Get-WebView2RuntimeVersion
    $openclawPath = Get-OpenClawCommandPath
    Write-Log -Message ('WebView2: installed={0}, version={1}' -f [bool]$wv2, $wv2)
    Write-Log -Message ('OpenClaw CLI: installed={0}, path={1}' -f [bool]$openclawPath, $openclawPath)
}
$null = Invoke-InstallerPhase -StepId 'check-other' -StepNumber 8 -StepName '检查 WebView2 及其他条件' -Percent 25 -FailureCode 'E2006' -Action $checkOtherAction

$preflight = & (Join-Path $PSScriptRoot 'steps\detect-dependencies.ps1') -ManifestPath $ManifestPath
$state.dependencies.node = $preflight.node
$state.dependencies.npm = $preflight.npm
$state.dependencies.git = $preflight.git
$state.dependencies.webview2 = $preflight.webview2
$state.dependencies.openclaw = $preflight.openclaw
Save-State

$depInstallAction = {
    $depResult = & (Join-Path $PSScriptRoot 'steps\install-dependencies.ps1') -ManifestPath $ManifestPath

    if ($depResult.node) {
        $state.nodeInstalledByBootstrap = $depResult.node.installedByBootstrap
        $state.nodeProductCode = $depResult.node.productCode
        $state.dependencies.node = $depResult.node
    }

    if ($depResult.git) {
        $state.gitInstalledByBootstrap = $depResult.git.installedByBootstrap
        if ($depResult.git.PSObject.Properties['uninstallerPath']) {
            $state.gitUninstallerPath = $depResult.git.uninstallerPath
        }
        $state.dependencies.git = $depResult.git
        if ($depResult.additionalPathEntries) {
            $script:BootstrapAdditionalPathEntries = @($depResult.additionalPathEntries)
        }
    }

    if ($depResult.webview2) {
        $state.dependencies.webview2 = $depResult.webview2
    }

    Save-State
}
$null = Invoke-InstallerPhase -StepId 'dep-install' -StepNumber 9 -StepName '下载并安装缺失依赖' -Percent 35 -FailureCode 'E2002' -Action $depInstallAction

$depVerifyAction = {
    $validation = & (Join-Path $InstallRoot 'validation\validate-install.ps1') -ManifestPath $ManifestPath -LauncherPath $LauncherPath -ShortcutName $ShortcutName -Scenario Prerequisites
    $state.dependencies.node = $validation.node
    $state.dependencies.npm = $validation.npm
    $state.dependencies.git = $validation.git
    $state.dependencies.webview2 = $validation.webview2
    Save-State
}
$null = Invoke-InstallerPhase -StepId 'dep-verify' -StepNumber 10 -StepName '验证依赖安装结果' -Percent 48 -FailureCode 'E2006' -Action $depVerifyAction

$existingInstallValidated = $false
if ($preflight.openclaw.installed) {
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $validationArgs = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $InstallRoot 'validation\validate-install.ps1'),
        '-ManifestPath', $ManifestPath,
        '-LauncherPath', $LauncherPath,
        '-ShortcutName', $ShortcutName,
        '-Scenario', 'Installed'
    )
    $validationProcess = Invoke-ExternalCommand -FilePath $powershellPath -Arguments $validationArgs -AllowNonZeroExit
    if ($validationProcess.ExitCode -eq 0) {
        $existingInstallValidated = $true
    } else {
        Write-Log -Message 'Existing OpenClaw detected but failed validation; will repair.' -Level 'WARN'
    }
}

$decision = Resolve-OfficialInstallDecision -Preflight $preflight -ExistingInstallValidated $existingInstallValidated

if ($decision -eq 'skip') {
    Set-InstallerStep -StepId 'official-install' -StepName '执行 OpenClaw 官方安装' -StepNumber 11
    Update-InstallStateStep -State $state -StepId 'official-install' -Status 'skipped' -Message 'Existing validated install reused.'
    Save-State
    Write-Stage -StageId 'official-install' -Percent 60 -Message '步骤 11/16: 检测到已有 OpenClaw，跳过安装。'
    Write-Log -Message 'Existing OpenClaw installation is healthy; skipping official install.' -Level 'SUCCESS'
}
else
{
    $officialInstallAction = {
        $null = & (Join-Path $PSScriptRoot 'steps\install-openclaw.ps1') -OfficialScriptPath $OfficialScriptPath -Channel $Channel -InstallMethod npm -AdditionalPathEntries $script:BootstrapAdditionalPathEntries
        $state.officialInstallComplete = $true
        $state.onboardingComplete = $true
        Save-State
    }
    $null = Invoke-InstallerPhase -StepId 'official-install' -StepNumber 11 -StepName '执行 OpenClaw 官方安装' -Percent 55 -FailureCode 'E3001' -Action $officialInstallAction
}

$officialVerifyAction = {
    $validation = & (Join-Path $InstallRoot 'validation\validate-install.ps1') -ManifestPath $ManifestPath -LauncherPath $LauncherPath -ShortcutName $ShortcutName -Scenario Installed
    $state.dependencies.openclaw = $validation.openclaw
    Save-State
}
$null = Invoke-InstallerPhase -StepId 'official-verify' -StepNumber 12 -StepName '验证 OpenClaw 安装结果' -Percent 68 -FailureCode 'E3002' -Action $officialVerifyAction

$shortcutAction = {
    $shortcutResult = & (Join-Path $PSScriptRoot 'steps\create-shortcut.ps1') -LauncherPath $LauncherPath -ShortcutName $ShortcutName
    $state.shortcuts = @($shortcutResult.desktopShortcut, $shortcutResult.startMenuShortcut)
    Save-State
    return $shortcutResult
}
$null = Invoke-InstallerPhase -StepId 'shortcuts' -StepNumber 13 -StepName '创建桌面快捷方式' -Percent 76 -FailureCode 'E4001' -Action $shortcutAction

if ($SkipLaunchAfterInstall) {
    Set-InstallerStep -StepId 'launch' -StepName '自动启动 OpenClaw' -StepNumber 14
    Update-InstallStateStep -State $state -StepId 'launch' -Status 'skipped' -Message 'Launch skipped by parameter.'
    Set-InstallerStep -StepId 'launch-verify' -StepName '验证 OpenClaw 启动结果' -StepNumber 15
    Update-InstallStateStep -State $state -StepId 'launch-verify' -Status 'skipped' -Message 'Launch verification skipped.'
    Save-State
} else {
    $launchAction = {
        Write-Log -Message 'Launch phase started; delegating to launch validation.'
    }
    $null = Invoke-InstallerPhase -StepId 'launch' -StepNumber 14 -StepName '自动启动 OpenClaw' -Percent 84 -FailureCode 'E3003' -Action $launchAction

    $launchVerifyAction = {
        $null = & (Join-Path $InstallRoot 'validation\validate-install.ps1') -ManifestPath $ManifestPath -LauncherPath $LauncherPath -ShortcutName $ShortcutName -Scenario Launch
        $state.launcherValidated = $true
        Save-State
    }
    $null = Invoke-InstallerPhase -StepId 'launch-verify' -StepNumber 15 -StepName '验证 OpenClaw 启动结果' -Percent 92 -FailureCode 'E3003' -Action $launchVerifyAction
}

$completeAction = {
    $state.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-State
    Write-Log -Message ('OpenClaw installation succeeded. Logs: {0}' -f $state.logPaths.text) -Level 'SUCCESS'
}
$null = Invoke-InstallerPhase -StepId 'complete' -StepNumber 16 -StepName '安装完成' -Percent 100 -FailureCode 'E1001' -Action $completeAction

exit $exitCode
