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

$stateRoot = Join-Path $env:ProgramData 'OpenClawInstaller'
$logRoot = Join-Path $stateRoot 'Logs'
$statePath = Join-Path $stateRoot 'install-state.json'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

$existingState = Read-InstallState -Path $statePath
$state = if ($existingState -and $existingState.schemaVersion -eq 2) { $existingState } else { New-InstallState }
$session = Initialize-InstallerSession -ProductName 'OpenClawInstaller' -LogRoot $logRoot
$state.installRoot = $InstallRoot
$state.mode = $ExistingInstallAction
$state.logPaths.text = $session.textLogPath
$state.logPaths.json = $session.jsonLogPath
$state.logPaths.transcript = $session.transcriptPath
Save-InstallState -State $state -Path $statePath

$exitCode = 0

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

    Write-Host ("@@OPENCLAW_ERROR|{0}|{1}" -f $Code, $Message)
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
    Write-Stage -StageId $StepId -Percent $Percent -Message ("步骤 {0}/15: {1}" -f $StepNumber, $StepName)

    try {
        $result = & $Action
        if ($AllowSkip -and $null -eq $result) {
            Update-InstallStateStep -State $state -StepId $StepId -Status 'skipped' -Message "$StepName skipped"
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

try {
    Write-Stage -StageId 'start' -Percent 1 -Message '步骤 1/15: 启动安装器。'
    Write-Log -Message 'OpenClaw bootstrap install started.'
    $script:BootstrapAdditionalPathEntries = @()

    Invoke-InstallerPhase -StepId 'admin' -StepNumber 2 -StepName '检查管理员权限' -Percent 5 -FailureCode 'E1002' -Action {
        Assert-Administrator
        Write-Log -Message 'Administrator privileges confirmed.' -Level 'SUCCESS'
    } | Out-Null

    Invoke-InstallerPhase -StepId 'logging' -StepNumber 3 -StepName '初始化日志系统' -Percent 10 -FailureCode 'E1003' -Action {
        Write-Log -Message ("Log files ready at {0}" -f $state.logPaths.text) -Level 'SUCCESS'
    } | Out-Null

    Invoke-InstallerPhase -StepId 'system-info' -StepNumber 4 -StepName '检测系统信息' -Percent 14 -FailureCode 'E1004' -Action {
        $systemSummary = [ordered]@{
            osVersion = [Environment]::OSVersion.VersionString
            is64BitOs = [Environment]::Is64BitOperatingSystem
            is64BitProcess = [Environment]::Is64BitProcess
            machineName = $env:COMPUTERNAME
            powershellVersion = $PSVersionTable.PSVersion.ToString()
            installRoot = $InstallRoot
        }

        Write-Log -Message ('System summary collected.') -Data $systemSummary
        $state.system = $systemSummary
        Save-State
    } | Out-Null

    $preflight = Invoke-InstallerPhase -StepId 'dependency-detect' -StepNumber 5 -StepName '检测依赖' -Percent 20 -FailureCode 'E2001' -Action {
        $result = & (Join-Path $repositoryRoot 'scripts\Test-Prerequisites.ps1') -ManifestPath $ManifestPath
        Write-Log -Message ("Preflight: Node installed={0}, npm installed={1}, Git installed={2}, WebView2 installed={3}, OpenClaw installed={4}" -f `
            $result.node.installed, $result.npm.installed, $result.git.installed, $result.webview2.installed, $result.openclaw.installed)
        $state.dependencies.node = $result.node
        $state.dependencies.npm = $result.npm
        $state.dependencies.git = $result.git
        $state.dependencies.webview2 = $result.webview2
        $state.dependencies.openclaw = $result.openclaw
        Save-State
        return $result
    }

    $missingDependencies = Invoke-InstallerPhase -StepId 'dependency-download' -StepNumber 6 -StepName '下载缺失依赖' -Percent 28 -FailureCode 'E2006' -Action {
        $missing = @()
        if (-not $preflight.node.meetsMinimum) {
            $missing += 'Node.js'
        }
        if (-not $preflight.git.installed) {
            $missing += 'Git'
        }
        if (-not $preflight.webview2.installed) {
            $missing += 'WebView2 Runtime'
        }

        if ($missing.Count -eq 0) {
            Write-Log -Message 'No runtime downloads are required.' -Level 'SUCCESS'
            return @()
        }

        Write-Log -Message ("Bootstrap will acquire: {0}" -f ([string]::Join(', ', $missing)))
        return $missing
    }

    $additionalPathEntries = @()
    Invoke-InstallerPhase -StepId 'dependency-install' -StepNumber 7 -StepName '安装缺失依赖' -Percent 42 -FailureCode 'E2002' -Action {
        if (-not $preflight.node.meetsMinimum) {
            $nodeInstall = & (Join-Path $repositoryRoot 'scripts\Install-Node.ps1') -ManifestPath $ManifestPath
            $state.nodeInstalledByBootstrap = $nodeInstall.installedByBootstrap
            $state.nodeProductCode = $nodeInstall.productCode
            $state.dependencies.node = $nodeInstall
            Save-State
        } else {
            Write-Log -Message 'Node.js already satisfies the minimum requirement; skipping install.'
        }

        if (-not $preflight.git.installed) {
            $gitInstall = & (Join-Path $repositoryRoot 'scripts\Install-Git.ps1') -ManifestPath $ManifestPath
            $state.gitInstalledByBootstrap = $gitInstall.installedByBootstrap
            $state.gitUninstallerPath = $gitInstall.uninstallerPath
            $state.dependencies.git = $gitInstall
            Save-State
            $script:BootstrapAdditionalPathEntries = @($gitInstall.pathEntries)
        } else {
            Write-Log -Message 'Git already satisfies the installer requirement; skipping install.'
        }

        if (-not $preflight.webview2.installed) {
            & (Join-Path $repositoryRoot 'scripts\Install-WebView2Runtime.ps1') -ManifestPath $ManifestPath | Out-Null
        } else {
            Write-Log -Message 'WebView2 Runtime is already available; skipping install.'
        }
    } | Out-Null

    Invoke-InstallerPhase -StepId 'dependency-verify' -StepNumber 8 -StepName '验证依赖安装结果' -Percent 52 -FailureCode 'E2006' -Action {
        $postInstallPreflight = & (Join-Path $repositoryRoot 'scripts\Test-Prerequisites.ps1') -ManifestPath $ManifestPath
        Write-Log -Message ("Post-install preflight: Node meetsMinimum={0}, npm installed={1}, Git installed={2}, WebView2 installed={3}" -f $postInstallPreflight.node.meetsMinimum, $postInstallPreflight.npm.installed, $postInstallPreflight.git.installed, $postInstallPreflight.webview2.installed)
        $state.dependencies.node = $postInstallPreflight.node
        $state.dependencies.npm = $postInstallPreflight.npm
        $state.dependencies.git = $postInstallPreflight.git
        $state.dependencies.webview2 = $postInstallPreflight.webview2

        $validation = & (Join-Path $InstallRoot 'validation\Test-InstallationState.ps1') -ManifestPath $ManifestPath -LauncherPath $LauncherPath -ShortcutName $ShortcutName -Scenario Prerequisites
        $state.dependencies.node = $validation.node
        $state.dependencies.npm = $validation.npm
        $state.dependencies.git = $validation.git
        $state.dependencies.webview2 = $validation.webview2
        Save-State
    } | Out-Null

    $existingInstallValidated = $false
    if ($preflight.openclaw.installed) {
        try {
            & (Join-Path $InstallRoot 'validation\Test-InstallationState.ps1') -ManifestPath $ManifestPath -LauncherPath $LauncherPath -ShortcutName $ShortcutName -Scenario Installed | Out-Null
            $existingInstallValidated = $true
            Write-Log -Message ("Existing OpenClaw installation validated successfully: {0}" -f $preflight.openclaw.path) -Level 'SUCCESS'
        } catch {
            Write-Log -Message 'Existing OpenClaw installation was detected but failed validation; bootstrap will repair it.' -Level 'WARN'
        }
    }

    $officialInstallDecision = Resolve-OfficialInstallDecision -Preflight $preflight -ExistingInstallValidated:$existingInstallValidated
    if ($officialInstallDecision -eq 'skip') {
        Set-InstallerStep -StepId 'official-install' -StepName '执行 OpenClaw 正式安装' -StepNumber 9
        Update-InstallStateStep -State $state -StepId 'official-install' -Status 'skipped' -Message 'Existing validated OpenClaw install reused.'
        Save-State
        Write-Stage -StageId 'official-install' -Percent 62 -Message '步骤 9/15: 检测到可复用的 OpenClaw，跳过正式安装。'
        Write-Log -Message 'Existing OpenClaw installation is healthy; skipping official install.' -Level 'SUCCESS'
    } else {
        Invoke-InstallerPhase -StepId 'official-install' -StepNumber 9 -StepName '执行 OpenClaw 正式安装' -Percent 62 -FailureCode 'E3001' -Action {
            & (Join-Path $repositoryRoot 'scripts\Invoke-OfficialInstall.ps1') `
                -OfficialScriptPath $OfficialScriptPath `
                -Channel $Channel `
                -InstallMethod npm `
                -AdditionalPathEntries $script:BootstrapAdditionalPathEntries `
                -SkipOnboard | Out-Null

            $state.officialInstallComplete = $true
            Save-State
        } | Out-Null
    }

    Invoke-InstallerPhase -StepId 'official-verify' -StepNumber 10 -StepName '验证 OpenClaw 安装结果' -Percent 72 -FailureCode 'E3003' -Action {
        $validation = & (Join-Path $InstallRoot 'validation\Test-InstallationState.ps1') -ManifestPath $ManifestPath -LauncherPath $LauncherPath -ShortcutName $ShortcutName -Scenario Installed
        $state.dependencies.openclaw = $validation.openclaw
        Save-State

        $token = New-RandomBase64Token
        & (Join-Path $repositoryRoot 'scripts\Invoke-OpenClawOnboarding.ps1') -GatewayToken $token | Out-Null
        $state.onboardingComplete = $true
        Save-State
    } | Out-Null

    $shortcuts = Invoke-InstallerPhase -StepId 'shortcuts' -StepNumber 11 -StepName '创建桌面快捷方式' -Percent 80 -FailureCode 'E4001' -Action {
        $shortcutResult = & (Join-Path $InstallRoot 'shortcuts\Create-OpenClawShortcuts.ps1') -LauncherPath $LauncherPath -ShortcutName $ShortcutName
        $state.shortcuts = @($shortcutResult.desktopShortcut, $shortcutResult.startMenuShortcut)
        Save-State
        return $shortcutResult
    }

    if ($SkipLaunchAfterInstall) {
        Set-InstallerStep -StepId 'launch' -StepName '自动启动 OpenClaw' -StepNumber 12
        Update-InstallStateStep -State $state -StepId 'launch' -Status 'skipped' -Message 'Launch skipped by parameter.'
        Set-InstallerStep -StepId 'launch-verify' -StepName '验证启动是否成功' -StepNumber 13
        Update-InstallStateStep -State $state -StepId 'launch-verify' -Status 'skipped' -Message 'Launch verification skipped by parameter.'
        Save-State
    } else {
        Invoke-InstallerPhase -StepId 'launch' -StepNumber 12 -StepName '自动启动 OpenClaw' -Percent 88 -FailureCode 'E3002' -Action {
            Write-Log -Message 'OpenClaw launch phase started; the next validation step will perform the actual launch and readiness check.'
        } | Out-Null

        Invoke-InstallerPhase -StepId 'launch-verify' -StepNumber 13 -StepName '验证启动是否成功' -Percent 94 -FailureCode 'E5001' -Action {
            & (Join-Path $InstallRoot 'validation\Test-InstallationState.ps1') -ManifestPath $ManifestPath -LauncherPath $LauncherPath -ShortcutName $ShortcutName -Scenario Launch | Out-Null
            $state.launcherValidated = $true
            Save-State
        } | Out-Null
    }

    Invoke-InstallerPhase -StepId 'complete' -StepNumber 14 -StepName '输出最终结果' -Percent 100 -FailureCode 'E1001' -Action {
        $state.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Save-State
        Write-Log -Message ("OpenClaw installation succeeded. Logs: {0}" -f $state.logPaths.text) -Level 'SUCCESS'
    } | Out-Null
} catch {
    $exitCode = 1
    $errorCode = Get-InstallerErrorCode -Exception $_.Exception -DefaultCode 'E1001'
    $diagnosticLogPath = $state.logPaths.text
    $state.lastError = $_.Exception.Message
    $state.lastErrorCode = $errorCode
    Save-InstallState -State $state -Path $statePath
    Set-InstallerStep -StepId 'rollback' -StepName '失败恢复与日志保留' -StepNumber 15
    Update-InstallStateStep -State $state -StepId 'rollback' -Status 'completed' -Code $errorCode -Message 'Installer preserved state and logs for a retry.'
    Save-State
    Write-Stage -StageId 'failure' -Percent 100 -Message ("步骤 15/15: 安装失败，错误码 {0}。已保留日志与状态用于重试。" -f $errorCode)
    Write-Log -Message ("Installation failed: {0}" -f $_.Exception.Message) -Level 'ERROR' -Code $errorCode
    Write-Log -Message ("Diagnostic log path: {0}" -f $diagnosticLogPath) -Level 'ERROR' -Code $errorCode
    Write-Log -Message 'Rollback policy is preserve-for-resume. No destructive cleanup was executed automatically.' -Level 'WARN' -Code 'E9001'
    Publish-InstallerFailure -Code $errorCode -Message ("{0} Log: {1}" -f $_.Exception.Message, $diagnosticLogPath)
}

exit $exitCode


