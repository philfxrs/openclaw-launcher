[CmdletBinding()]
param(
    [string]$ConfiguratorPath,

    [string]$LauncherPath,

    [string]$ReportPath,

    [int]$LauncherPort = 18893,

    [int]$UiTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class OpenClawUiNativeMethods
{
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@

$repositoryRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfiguratorPath) {
    $ConfiguratorPath = Join-Path $repositoryRoot 'artifacts\configurator\OpenClawConfigurator.exe'
}

if (-not $LauncherPath) {
    $LauncherPath = Join-Path $repositoryRoot 'artifacts\launcher\OpenClawLauncher.exe'
}

if (-not $ReportPath) {
    $reportRoot = Join-Path $repositoryRoot 'artifacts\test'
    New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
    $ReportPath = Join-Path $reportRoot ('models-raw-json-preservation-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
}

$configRoot = Join-Path $env:USERPROFILE '.openclaw'
$configPath = Join-Path $configRoot 'openclaw.json'
$backupPath = Join-Path $configRoot ('openclaw.models-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
$launcherLogPath = Join-Path $env:TEMP ('openclaw-models-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

$result = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    configuratorPath = $ConfiguratorPath
    launcherPath = $LauncherPath
    launcherLogPath = $launcherLogPath
    configuratorLaunch = $false
    saveCompleted = $false
    modelsProvidersEdited = $false
    tokenPersisted = $false
    portPersisted = $false
    modelsProvidersPreserved = $false
    modelArrayPreserved = $false
    legacyProviderObjectPresent = $false
    systemObjectLeak = $false
    cliValidation = 'NOT_RUN'
    launcherRuntimeTargetFollowed = $false
    launcherReady = $false
    overall = 'FAIL'
    error = $null
}

$configuratorProcess = $null
$launcherProcess = $null
$originalConfigExisted = Test-Path $configPath

function Wait-LocalUntil {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Condition,
        [int]$TimeoutSeconds = 10,
        [int]$IntervalMilliseconds = 250
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) {
            return $true
        }

        Start-Sleep -Milliseconds $IntervalMilliseconds
    }

    return $false
}

function Get-WindowElement {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProcessId,
        [int]$TimeoutSeconds = 30
    )

    $propertyCondition = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
        $ProcessId
    )

    $script:OpenClawModelsWindow = $null
    $found = Wait-LocalUntil -TimeoutSeconds $TimeoutSeconds -Condition {
        $script:OpenClawModelsWindow = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children,
            $propertyCondition
        )

        return $null -ne $script:OpenClawModelsWindow
    }

    if (-not $found) {
        throw 'Timed out waiting for the Configurator main window.'
    }

    return $script:OpenClawModelsWindow
}

function Find-DescendantByAutomationId {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Automation.AutomationElement]$Root,
        [Parameter(Mandatory = $true)]
        [string]$AutomationId,
        [int]$TimeoutSeconds = 15
    )

    $script:OpenClawModelsElement = $null
    $found = Wait-LocalUntil -TimeoutSeconds $TimeoutSeconds -Condition {
        $propertyCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
            $AutomationId
        )
        $script:OpenClawModelsElement = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $propertyCondition)
        return $null -ne $script:OpenClawModelsElement
    }

    if (-not $found) {
        throw ('Timed out waiting for AutomationId ' + $AutomationId)
    }

    return $script:OpenClawModelsElement
}

function Invoke-UiElement {
    param([Parameter(Mandatory = $true)][System.Windows.Automation.AutomationElement]$Element)

    $selectionPattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$selectionPattern)) {
        $selectionPattern.Select()
        return
    }

    $invokePattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invokePattern)) {
        $invokePattern.Invoke()
        return
    }

    throw 'UI element does not expose InvokePattern or SelectionItemPattern.'
}

function Set-UiText {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Automation.AutomationElement]$Element,
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [switch]$UseKeyboardInput,
        [IntPtr]$WindowHandle = [IntPtr]::Zero
    )

    $valuePattern = $null
    if (-not $UseKeyboardInput -and $Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
        $valuePattern.SetValue($Text)
        return
    }

    if ($WindowHandle -ne [IntPtr]::Zero) {
        [OpenClawUiNativeMethods]::ShowWindow($WindowHandle, 5) | Out-Null
        [OpenClawUiNativeMethods]::SetForegroundWindow($WindowHandle) | Out-Null
        Start-Sleep -Milliseconds 250
    }

    $Element.SetFocus()
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.Clipboard]::SetText($Text)
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 250
}

function Stop-ProcessSafely {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return
    }

    try {
        if (-not $Process.HasExited) {
            $null = $Process.CloseMainWindow()
            if (-not $Process.WaitForExit(3000)) {
                $Process.Kill()
                $Process.WaitForExit()
            }
        }
    }
    catch {
    }
}

function Resolve-OpenClawCommand {
    foreach ($candidate in @('openclaw.cmd', 'openclaw.exe', 'openclaw')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command -and $command.Source) {
            return $command.Source
        }
    }

    $npmCandidate = Join-Path $env:APPDATA 'npm\openclaw.cmd'
    if (Test-Path $npmCandidate) {
        return $npmCandidate
    }

    return $null
}

try {
    if (-not (Test-Path $ConfiguratorPath)) {
        throw 'Configurator executable was not found.'
    }

    if (-not (Test-Path $LauncherPath)) {
        throw 'Launcher executable was not found.'
    }

    New-Item -ItemType Directory -Force -Path $configRoot | Out-Null
    if ($originalConfigExisted) {
        Copy-Item -Path $configPath -Destination $backupPath -Force
    }

        $rawJson = @"
{
    "meta": {
        "lastTouchedVersion": "local-models-smoke",
        "lastTouchedAt": "$(Get-Date -Format o)"
    },
  "gateway": {
    "mode": "local",
    "bind": "loopback",
        "port": $LauncherPort,
    "auth": {
      "mode": "token",
            "token": "smoketoken-models"
    },
    "controlUi": {
      "enabled": true,
      "allowedOrigins": ["http://localhost:3000", "https://example.test"]
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "openai": {
        "baseUrl": "https://api.openai.com/v1",
        "apiKey": "raw-provider-key",
        "auth": "api-key",
        "api": "openai-responses",
        "models": [
          {
            "id": "gpt-4.1-mini",
            "name": "GPT-4.1 Mini",
            "api": "openai-responses",
            "contextWindow": 128000,
            "maxTokens": 16384
          }
        ]
      }
    },
    "bedrockDiscovery": {
      "enabled": true,
      "region": "us-east-1",
      "refreshInterval": 60
    }
  }
}
"@
    [System.IO.File]::WriteAllText($configPath, $rawJson, (New-Object System.Text.UTF8Encoding($false)))

    $configuratorProcess = Start-Process -FilePath $ConfiguratorPath -ArgumentList @('--tab', 'models') -PassThru
    $window = Get-WindowElement -ProcessId $configuratorProcess.Id -TimeoutSeconds $UiTimeoutSeconds
    $result.configuratorLaunch = $true

    $providersInput = Find-DescendantByAutomationId -Root $window -AutomationId 'input-models-providers' -TimeoutSeconds $UiTimeoutSeconds
    $providersJson = @"
{
    "openai": {
        "baseUrl": "https://api.openai.com/v1",
        "apiKey": "ui-provider-key",
        "auth": "api-key",
        "api": "openai-responses",
        "models": [
            {
                "id": "gpt-4.1-mini",
                "name": "GPT-4.1 Mini",
                "api": "openai-responses",
                "contextWindow": 128000,
                "maxTokens": 16384
            },
            {
                "id": "gpt-4.1",
                "name": "GPT-4.1",
                "api": "openai-responses",
                "contextWindow": 256000,
                "maxTokens": 32768
            }
        ]
    }
}
"@
    Set-UiText -Element $providersInput -Text $providersJson -UseKeyboardInput -WindowHandle $configuratorProcess.MainWindowHandle

    $saveButton = Find-DescendantByAutomationId -Root $window -AutomationId 'action-save-config' -TimeoutSeconds $UiTimeoutSeconds
    Invoke-UiElement -Element $saveButton

    $saved = Wait-LocalUntil -TimeoutSeconds 20 -Condition {
        if (-not (Test-Path $configPath)) {
            return $false
        }

        $content = Get-Content -Path $configPath -Raw
        return $content -match 'smoketoken-models' -and
            $content -match ('"port"\s*:\s*' + $LauncherPort) -and
            $content -match 'ui-provider-key' -and
            $content -match '"gpt-4\.1"'
    }

    if (-not $saved) {
        throw 'Configurator save did not write the updated models.providers payload to openclaw.json.'
    }

    $result.saveCompleted = $true
    $savedJson = Get-Content -Path $configPath -Raw
    $savedObject = $savedJson | ConvertFrom-Json
    $provider = $savedObject.models.providers.openai
    $result.modelsProvidersEdited = $savedJson -match 'ui-provider-key' -and $savedJson -match '"gpt-4\.1"'

    $result.tokenPersisted = $savedJson -match 'smoketoken-models'
    $result.portPersisted = $savedJson -match ('"port"\s*:\s*' + $LauncherPort)
    $result.modelsProvidersPreserved = $null -ne $provider -and
        $provider.baseUrl -eq 'https://api.openai.com/v1' -and
        $provider.auth -eq 'api-key' -and
        $provider.api -eq 'openai-responses' -and
        $provider.apiKey -eq 'ui-provider-key'
    $result.modelArrayPreserved = $null -ne $provider -and
        $provider.models.Count -ge 2 -and
        $provider.models[0].id -eq 'gpt-4.1-mini' -and
        $provider.models[0].name -eq 'GPT-4.1 Mini' -and
        $provider.models[1].id -eq 'gpt-4.1' -and
        $provider.models[1].name -eq 'GPT-4.1'
    $result.legacyProviderObjectPresent = $savedObject.PSObject.Properties.Name -contains 'provider'
    $result.systemObjectLeak = $savedJson -match 'System\.Object\[\]'

    Stop-ProcessSafely -Process $configuratorProcess
    $configuratorProcess = $null

    $openClawCommand = Resolve-OpenClawCommand
    if ($openClawCommand) {
        $modeOutput = & $openClawCommand config get models.mode 2>$null
        if ($LASTEXITCODE -eq 0 -and (($modeOutput | Out-String).Trim() -eq 'merge')) {
            $result.cliValidation = 'PASS'
        }
        else {
            $result.cliValidation = 'FAIL'
            throw 'OpenClaw CLI could not read models.mode from the saved configuration.'
        }
    }
    else {
        $result.cliValidation = 'SKIPPED'
    }

    if (Test-Path $launcherLogPath) {
        Remove-Item -Path $launcherLogPath -Force
    }

    $launcherProcess = Start-Process -FilePath $LauncherPath -ArgumentList @('--log', $launcherLogPath, '--timeout', '45', '--quiet-errors') -PassThru

    $result.launcherRuntimeTargetFollowed = Wait-LocalUntil -TimeoutSeconds 60 -Condition {
        if (-not (Test-Path $launcherLogPath)) {
            return $false
        }

        $content = Get-Content -Path $launcherLogPath -Raw -ErrorAction SilentlyContinue
        return $content -match ('Gateway runtime target: .*port=' + $LauncherPort)
    }

    $result.launcherReady = Wait-LocalUntil -TimeoutSeconds 60 -Condition {
        if (-not (Test-Path $launcherLogPath)) {
            return $false
        }

        $content = Get-Content -Path $launcherLogPath -Raw -ErrorAction SilentlyContinue
        return $content -match 'Control UI is ready for use\.'
    }

    if ($result.configuratorLaunch -and
        $result.saveCompleted -and
        $result.modelsProvidersEdited -and
        $result.tokenPersisted -and
        $result.portPersisted -and
        $result.modelsProvidersPreserved -and
        $result.modelArrayPreserved -and
        -not $result.legacyProviderObjectPresent -and
        -not $result.systemObjectLeak -and
        ($result.cliValidation -eq 'PASS' -or $result.cliValidation -eq 'SKIPPED') -and
        $result.launcherRuntimeTargetFollowed) {
        $result.overall = 'PASS'
    }
}
catch {
    $result.error = $_.Exception.Message
}
finally {
    Stop-ProcessSafely -Process $configuratorProcess
    Stop-ProcessSafely -Process $launcherProcess

    if ($originalConfigExisted -and (Test-Path $backupPath)) {
        Move-Item -Path $backupPath -Destination $configPath -Force
    }
    elseif (-not $originalConfigExisted -and (Test-Path $configPath)) {
        Remove-Item -Path $configPath -Force
    }

    $result | ConvertTo-Json -Depth 8 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Host ('Models raw JSON preservation report: ' + $ReportPath)

    if ($result.overall -ne 'PASS') {
        throw ('Models raw JSON preservation failed: ' + $result.error)
    }
}