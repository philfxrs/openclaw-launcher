[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$ManifestPath,
    [string]$OfficialScriptPath,
    [string]$LauncherPath,
    [string]$ShortcutName = 'OpenClaw',
    [string]$Channel = 'latest',
    [string]$InstallerVersion = '0.1.10',
    [string]$BuildVersion = '0.1.10',
    [AllowEmptyString()]
    [string]$DiagnosticsUploadUri = '',
    [ValidateSet('Auto', 'Repair', 'Overwrite', 'SkipIfPresent')]
    [string]$ExistingInstallAction = 'Auto',
    [switch]$SkipLaunchAfterInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-BootstrapFallbackState {
    return [ordered]@{
        schemaVersion            = 2
        startedAtUtc             = (Get-Date).ToUniversalTime().ToString('o')
        lastUpdatedAtUtc         = (Get-Date).ToUniversalTime().ToString('o')
        completedAtUtc           = $null
        installRoot              = $null
        mode                     = 'Auto'
        logPaths                 = [ordered]@{ text = $null; json = $null; transcript = $null }
        steps                    = [ordered]@{}
        system                   = $null
        dependencies             = [ordered]@{ node = $null; npm = $null; git = $null; webview2 = $null; openclaw = $null }
        nodeInstalledByBootstrap = $false
        nodeProductCode          = $null
        gitInstalledByBootstrap  = $false
        gitUninstallerPath       = $null
        officialInstallComplete  = $false
        onboardingComplete       = $false
        launcherValidated        = $false
        shortcuts                = @()
        lastError                = $null
        lastErrorCode            = $null
    }
}

function Ensure-BootstrapStateShape {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    if (-not $State.logPaths) {
        $State.logPaths = [ordered]@{ text = $null; json = $null; transcript = $null }
    }

    if (-not $State.steps) {
        $State.steps = [ordered]@{}
    }

    $stepsContainer = $State.steps

    foreach ($stepId in @(
        'admin', 'logging', 'system-info', 'check-node', 'check-npm', 'check-git',
        'check-other', 'dep-install', 'dep-verify', 'official-install',
        'official-verify', 'shortcuts', 'launch', 'launch-verify', 'complete',
        'failure', 'preserve-logs'
    )) {
        $stepExists = $false
        if ($stepsContainer -is [System.Collections.IDictionary]) {
            $stepExists = $stepsContainer.Contains($stepId)
        } elseif ($stepsContainer.PSObject.Properties[$stepId]) {
            $stepExists = $true
        }

        if (-not $stepExists) {
            $stepState = [ordered]@{
                startedAtUtc   = $null
                completedAtUtc = $null
                status         = 'pending'
                code           = $null
                message        = $null
            }

            if ($stepsContainer -is [System.Collections.IDictionary]) {
                $stepsContainer[$stepId] = $stepState
            } else {
                Add-Member -InputObject $stepsContainer -MemberType NoteProperty -Name $stepId -Value $stepState
            }
        }
    }

    return $State
}

function Reset-InstallStateForNewRun {
    param(
        [object]$ExistingState
    )

    $newState = New-InstallState

    if ($null -eq $ExistingState) {
        return (Ensure-BootstrapStateShape -State $newState)
    }

    $newState.nodeInstalledByBootstrap = [bool]$ExistingState.nodeInstalledByBootstrap
    $newState.nodeProductCode = $ExistingState.nodeProductCode
    $newState.gitInstalledByBootstrap = [bool]$ExistingState.gitInstalledByBootstrap
    $newState.gitUninstallerPath = $ExistingState.gitUninstallerPath

    return (Ensure-BootstrapStateShape -State $newState)
}

$stateRoot = Join-Path $env:ProgramData 'OpenClawInstaller'
$logRoot = Join-Path $stateRoot 'Logs'
$statePath = $null
$state = New-BootstrapFallbackState

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
if (-not $DiagnosticsUploadUri) {
    $DiagnosticsUploadUri = $env:OPENCLAW_DIAGNOSTICS_UPLOAD_URI
}
if ([string]::IsNullOrWhiteSpace($DiagnosticsUploadUri)) {
    $DiagnosticsUploadUri = 'https://mingos.cc/installer-diagnostics'
}

$statePath = Join-Path $stateRoot 'install-state.json'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

$existingState = Read-InstallState -Path $statePath
if ($existingState -and $existingState.schemaVersion -eq 2) {
    $state = Reset-InstallStateForNewRun -ExistingState $existingState
} else {
    $state = Reset-InstallStateForNewRun -ExistingState $null
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
$script:ValidationRuntimeRoot = $null

function Save-State {
    if ($null -eq $state) {
        $state = New-BootstrapFallbackState
    }

    $state = Ensure-BootstrapStateShape -State $state

    if ($statePath) {
        Save-InstallState -State $state -Path $statePath
    }
}

function Initialize-ValidationRuntimeSupport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot
    )

    $runtimePowerShellRoot = Join-Path $DestinationRoot 'powershell'
    $runtimeValidationRoot = Join-Path $DestinationRoot 'validation'

    New-Item -ItemType Directory -Force -Path $runtimePowerShellRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $runtimeValidationRoot | Out-Null

    Copy-Item -Path (Join-Path $script:InstallerPSRoot '*') -Destination $runtimePowerShellRoot -Recurse -Force
    Copy-Item -Path (Join-Path $script:InstallerValidationRoot '*') -Destination $runtimeValidationRoot -Recurse -Force

    return [ordered]@{
        root       = $DestinationRoot
        validation = $runtimeValidationRoot
    }
}

function Resolve-ValidationScriptPath {
    $candidates = @()

    if ($script:ValidationRuntimeRoot) {
        $candidates += (Join-Path $script:ValidationRuntimeRoot 'validate-install.ps1')
    }

    if ($script:InstallerValidationRoot) {
        $candidates += (Join-Path $script:InstallerValidationRoot 'validate-install.ps1')
    }

    if ($InstallRoot) {
        $candidates += (Join-Path $InstallRoot 'validation\validate-install.ps1')
    }

    foreach ($candidate in ($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw (New-InstallerException -Code 'E2006' -Message ('Validation script missing. Checked: {0}' -f (($candidates | Select-Object -Unique) -join '; ')))
}

function Invoke-InstallerValidation {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Prerequisites', 'Installed', 'Launch')]
        [string]$Scenario
    )

    $validationScriptPath = Resolve-ValidationScriptPath
    Write-Log -Message ('Using validation script: {0}' -f $validationScriptPath)

    return & $validationScriptPath -ManifestPath $ManifestPath -LauncherPath $LauncherPath -ShortcutName $ShortcutName -Scenario $Scenario
}

try {
    $runtimeSupport = Initialize-ValidationRuntimeSupport -DestinationRoot (Join-Path $stateRoot 'runtime-support')
    $script:ValidationRuntimeRoot = $runtimeSupport.validation
    Write-Log -Message ('Staged validation runtime support at: {0}' -f $runtimeSupport.root) -Level 'SUCCESS'
} catch {
    Write-Log -Message ('Failed to stage validation runtime support: {0}. Falling back to installed support files.' -f $_.Exception.Message) -Level 'WARN'
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

function Publish-InstallerDiagnostics {
    param(
        [string]$ReportId,
        [string]$LogPath,
        [string]$UploadStatus
    )

    Write-Host ('@@OPENCLAW_DIAGNOSTICS|{0}|{1}|{2}' -f $ReportId, $LogPath, $UploadStatus)
}

function Invoke-DiagnosticsUploadInline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath,
        [Parameter(Mandatory = $true)]
        [string]$UploadUri
    )

    if ([string]::IsNullOrWhiteSpace($UploadUri) -or -not (Test-Path $SummaryPath)) {
        return $null
    }

    Add-Type -AssemblyName System.Net.Http

    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(3)

    try {
        $content = New-Object System.Net.Http.MultipartFormDataContent

        $summaryBytes = [System.IO.File]::ReadAllBytes($SummaryPath)
        $summaryPart = New-Object System.Net.Http.ByteArrayContent(,$summaryBytes)
        $summaryPart.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json')

        $content.Add($summaryPart, 'summary', [System.IO.Path]::GetFileName($SummaryPath))
        $content.Add((New-Object System.Net.Http.StringContent('windows-installer')), 'source')

        $response = $client.PostAsync($UploadUri, $content).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            return [pscustomobject]@{
                success = $false
                reportId = $null
                error = ('HTTP {0}: {1}' -f [int]$response.StatusCode, $body)
            }
        }

        $result = $body | ConvertFrom-Json
        $uploadResult = [pscustomobject]@{
            success = [bool]$result.success
            reportId = [string]$result.reportId
            error = $null
        }

        try {
            $resultPath = $SummaryPath + '.upload-result.json'
            Save-JsonFile -InputObject ([ordered]@{
                reportId = $uploadResult.reportId
                success = $uploadResult.success
                uploadedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            }) -Path $resultPath
        } catch { }

        return $uploadResult
    } finally {
        if ($null -ne $client) {
            $client.Dispose()
        }
    }
}

function Start-DiagnosticsUpload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SummaryPath,
        [Parameter(Mandatory = $true)]
        [string]$UploadUri
    )

    if ([string]::IsNullOrWhiteSpace($UploadUri) -or -not (Test-Path $SummaryPath)) {
        return $false
    }

    $uploadScriptPath = Join-Path $PSScriptRoot 'upload-diagnostics.ps1'
    $powerShellPath = Join-Path $PSHOME 'powershell.exe'
    $arguments = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-WindowStyle', 'Hidden'
        '-File', $uploadScriptPath
        '-SummaryPath', $SummaryPath
        '-UploadUri', $UploadUri
    )

    $null = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden
    return $true
}

function Get-UserFacingFailureMessage {
    [CmdletBinding()]
    param(
        [string]$ErrorCode
    )

    if ([string]::IsNullOrWhiteSpace($ErrorCode)) {
        return 'OpenClaw 安装未能完成。请稍后重试；如果问题持续存在，请重新下载安装包后再试。'
    }

    return 'OpenClaw 安装未能完成。请稍后重试；如果问题持续存在，请重新下载安装包后再试。'
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
    $errorCode = 'E9001'
    $stateValue = if (Get-Variable -Name state -Scope Script -ErrorAction SilentlyContinue) { $script:state } else { $null }
    $stateRootValue = if (Get-Variable -Name stateRoot -Scope Script -ErrorAction SilentlyContinue) { $script:stateRoot } else { (Join-Path $env:ProgramData 'OpenClawInstaller') }
    $logRootValue = if (Get-Variable -Name logRoot -Scope Script -ErrorAction SilentlyContinue) { $script:logRoot } else { (Join-Path $stateRootValue 'Logs') }
    $statePathValue = if (Get-Variable -Name statePath -Scope Script -ErrorAction SilentlyContinue) { $script:statePath } else { $null }
    $diagnosticsUploadUriValue = if (Get-Variable -Name DiagnosticsUploadUri -Scope Script -ErrorAction SilentlyContinue) { $script:DiagnosticsUploadUri } else { $null }

    if (Get-Command Get-InstallerErrorCode -ErrorAction SilentlyContinue) {
        $errorCode = Get-InstallerErrorCode -Exception $_.Exception -DefaultCode 'E9001'
    }
    $localLogPath = if ($stateValue -and $stateValue.logPaths -and $stateValue.logPaths.text) { $stateValue.logPaths.text } else { $logRootValue }
    $summaryPath = if ($stateValue -and $stateValue.logPaths -and $stateValue.logPaths.text) {
        [System.IO.Path]::ChangeExtension($stateValue.logPaths.text, '.summary.json')
    } else {
        Join-Path $stateRootValue 'diagnostics-summary.json'
    }
    $reportId = ''
    $uploadStatus = if ([string]::IsNullOrWhiteSpace($diagnosticsUploadUriValue)) { 'not-configured' } else { 'failed' }
    $userFacingFailureMessage = 'OpenClaw 安装未能完成。请稍后重试；如果问题持续存在，请重新下载安装包后再试。'

    if ($null -eq $stateValue) {
        $stateValue = New-BootstrapFallbackState
    }

    $stateValue = Ensure-BootstrapStateShape -State $stateValue
    $script:state = $stateValue

    $stateValue.lastError = $_.Exception.Message
    $stateValue.lastErrorCode = $errorCode
    if ($statePathValue) {
        Save-InstallState -State $stateValue -Path $statePathValue
    }

    Publish-InstallerFailure -Code $errorCode -Message $userFacingFailureMessage

    try {
        $summary = New-DiagnosticsSummary -State $stateValue -InstallerVersion $InstallerVersion -BuildVersion $BuildVersion -ErrorCode $errorCode -ErrorMessage $_.Exception.Message -LocalLogPath $localLogPath -LocalStatePath $statePathValue
        Save-JsonFile -InputObject $summary -Path $summaryPath
        Write-Log -Message ('Diagnostics summary saved: {0}' -f $summaryPath)

        if (-not [string]::IsNullOrWhiteSpace($diagnosticsUploadUriValue)) {
            try {
                $uploadResult = Invoke-DiagnosticsUploadInline -SummaryPath $summaryPath -UploadUri $diagnosticsUploadUriValue
                if ($uploadResult -and $uploadResult.success) {
                    $reportId = $uploadResult.reportId
                    $uploadStatus = 'completed'
                    Write-Log -Message ('Diagnostics uploaded. reportId={0}' -f $reportId) -Level 'SUCCESS'
                } elseif ($uploadResult) {
                    Write-Log -Message ('Inline diagnostics upload failed: {0}. Scheduling background retry.' -f $uploadResult.error) -Level 'WARN'
                    if (Start-DiagnosticsUpload -SummaryPath $summaryPath -UploadUri $diagnosticsUploadUriValue) {
                        $uploadStatus = 'scheduled'
                    }
                } else {
                    Write-Log -Message 'Inline diagnostics upload returned no result. Scheduling background retry.' -Level 'WARN'
                    if (Start-DiagnosticsUpload -SummaryPath $summaryPath -UploadUri $diagnosticsUploadUriValue) {
                        $uploadStatus = 'scheduled'
                    }
                }
            } catch {
                Write-Log -Message ('Inline diagnostics upload error: {0}. Scheduling background retry.' -f $_.Exception.Message) -Level 'WARN'
                try {
                    if (Start-DiagnosticsUpload -SummaryPath $summaryPath -UploadUri $diagnosticsUploadUriValue) {
                        $uploadStatus = 'scheduled'
                    }
                } catch {
                    Write-Log -Message ('Background diagnostics upload scheduling also failed: {0}' -f $_.Exception.Message) -Level 'WARN'
                }
            }
        } else {
            Write-Log -Message 'Diagnostics upload URI is not configured; summary upload skipped.' -Level 'WARN'
        }
    } catch {
        Write-Log -Message ('Diagnostics summary generation failed: {0}' -f $_.Exception.Message) -Level 'WARN'
    }

    Publish-InstallerDiagnostics -ReportId $reportId -LogPath $localLogPath -UploadStatus $uploadStatus

    Set-InstallerStep -StepId 'failure' -StepName '安装失败处理' -StepNumber 17
    Update-InstallStateStep -State $state -StepId 'failure' -Status 'completed' -Code $errorCode -Message $_.Exception.Message
    Save-State
    Write-Stage -StageId 'failure' -Percent 100 -Message ('步骤 17: 安装失败，错误码 {0}' -f $errorCode)
    Write-Log -Message ('Installation failed: {0}' -f $_.Exception.Message) -Level 'ERROR' -Code $errorCode

    Set-InstallerStep -StepId 'preserve-logs' -StepName '保留日志与错误码' -StepNumber 18
    Update-InstallStateStep -State $state -StepId 'preserve-logs' -Status 'completed' -Code $errorCode -Message 'State and logs preserved for retry.'
    Save-State
    Write-Log -Message 'Rollback policy: preserve-for-resume. No destructive cleanup performed.' -Level 'WARN' -Code 'E9001'
    Write-Log -Message ('日志文件: {0}' -f $(if ($state.logPaths.text) { $state.logPaths.text } else { $logRoot })) -Level 'INFO'
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
    $validation = Invoke-InstallerValidation -Scenario Prerequisites
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
        '-File', (Resolve-ValidationScriptPath),
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
    $validation = Invoke-InstallerValidation -Scenario Installed
    $state.dependencies.openclaw = $validation.openclaw
    Save-State
}
$null = Invoke-InstallerPhase -StepId 'official-verify' -StepNumber 12 -StepName '验证 OpenClaw 安装结果' -Percent 68 -FailureCode 'E3002' -Action $officialVerifyAction

$shortcutAction = {
    $shortcutResult = & (Join-Path $PSScriptRoot 'steps\create-shortcut.ps1') -LauncherPath $LauncherPath -ShortcutName $ShortcutName
    $state.shortcuts = @($shortcutResult.desktopShortcut, $shortcutResult.startMenuShortcut, $shortcutResult.configuratorDesktopShortcut, $shortcutResult.configuratorStartMenuShortcut) | Where-Object { $_ }
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
        $null = Invoke-InstallerValidation -Scenario Launch
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
