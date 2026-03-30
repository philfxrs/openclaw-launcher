[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfiguratorPath,

    [Parameter(Mandatory = $true)]
    [string]$LauncherPath,

    [string]$ReportPath,

    [int]$LauncherPort = 18892,

    [int]$UiTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

if (-not $ReportPath) {
    $reportRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\test'
    New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
    $ReportPath = Join-Path $reportRoot ('installed-configurator-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
}

$installRoot = Split-Path -Parent (Split-Path -Parent $LauncherPath)
$validateScript = Join-Path $installRoot 'validation\validate-install.ps1'
$manifestPath = Join-Path $installRoot 'resources\manifests\dependencies.json'
$configRoot = Join-Path $env:USERPROFILE '.openclaw'
$configPath = Join-Path $configRoot 'openclaw.json'
$backupPath = Join-Path $configRoot ('openclaw.smoke-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
$launcherLogPath = Join-Path $env:TEMP ('openclaw-launcher-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

$result = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    configuratorPath = $ConfiguratorPath
    launcherPath = $LauncherPath
    launcherLogPath = $launcherLogPath
    installValidation = 'NOT_RUN'
    launchValidation = 'NOT_RUN'
    configuratorLaunch = $false
    rawJsonApply = $false
    tokenPersisted = $false
    portPersisted = $false
    rawArrayPreserved = $false
    derivedKeysPersisted = $false
    systemObjectLeak = $false
    launcherRuntimeTargetFollowed = $false
    launcherReady = $false
    overall = 'FAIL'
    error = $null
}

$configuratorProcess = $null
$launcherProcess = $null
$originalConfigExisted = Test-Path $configPath

function Wait-SmokeUntil {
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

    $script:OpenClawSmokeWindow = $null
    $found = Wait-SmokeUntil -TimeoutSeconds $TimeoutSeconds -Condition {
        $script:OpenClawSmokeWindow = [System.Windows.Automation.AutomationElement]::RootElement.FindFirst(
            [System.Windows.Automation.TreeScope]::Children,
            $propertyCondition
        )

        return $null -ne $script:OpenClawSmokeWindow
    }

    if (-not $found) {
        throw 'Timed out waiting for the Configurator main window.'
    }

    return $script:OpenClawSmokeWindow
}

function Find-DescendantByAutomationId {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Automation.AutomationElement]$Root,
        [Parameter(Mandatory = $true)]
        [string]$AutomationId,
        [int]$TimeoutSeconds = 15
    )

    $script:OpenClawSmokeElement = $null
    $found = Wait-SmokeUntil -TimeoutSeconds $TimeoutSeconds -Condition {
        $propertyCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
            $AutomationId
        )
        $script:OpenClawSmokeElement = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $propertyCondition)
        return $null -ne $script:OpenClawSmokeElement
    }

    if (-not $found) {
        throw ('Timed out waiting for AutomationId ' + $AutomationId)
    }

    return $script:OpenClawSmokeElement
}

function Find-DescendantByName {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Automation.AutomationElement]$Root,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [int]$TimeoutSeconds = 15
    )

    $script:OpenClawSmokeElement = $null
    $found = Wait-SmokeUntil -TimeoutSeconds $TimeoutSeconds -Condition {
        $propertyCondition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty,
            $Name
        )
        $script:OpenClawSmokeElement = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $propertyCondition)
        return $null -ne $script:OpenClawSmokeElement
    }

    if (-not $found) {
        throw ('Timed out waiting for control named ' + $Name)
    }

    return $script:OpenClawSmokeElement
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
        [string]$Text
    )

    $valuePattern = $null
    if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {
        $valuePattern.SetValue($Text)
        return
    }

    $Element.SetFocus()
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.SendKeys]::SendWait($Text)
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
    } catch {
    }
}

try {
    if (-not (Test-Path $ConfiguratorPath)) {
        throw 'Configurator executable was not found.'
    }

    if (-not (Test-Path $LauncherPath)) {
        throw 'Launcher executable was not found.'
    }

    if (-not (Test-Path $validateScript)) {
        throw 'Installed validation script was not found.'
    }

    New-Item -ItemType Directory -Force -Path $configRoot | Out-Null
    & $validateScript -ManifestPath $manifestPath -LauncherPath $LauncherPath -Scenario Installed | Out-Null
    $result.installValidation = 'PASS'

        if ($originalConfigExisted) {
                Copy-Item -Path $configPath -Destination $backupPath -Force
        }

        $rawJson = @"
{
    "gateway": {
        "mode": "local",
        "bind": "loopback",
        "port": 18891,
        "auth": {
            "mode": "token",
            "token": "rawseedtoken"
        },
        "controlUi": {
            "enabled": true,
            "allowedOrigins": ["http://localhost:3000", "https://example.test"]
        }
    },
    "models": {
        "mode": "merge",
        "bedrockDiscovery": {
            "enabled": true,
            "region": "us-east-1",
            "refreshInterval": 60
        }
    }
}
"@
        [System.IO.File]::WriteAllText($configPath, $rawJson, (New-Object System.Text.UTF8Encoding($false)))

    $configuratorProcess = Start-Process -FilePath $ConfiguratorPath -PassThru
    $window = Get-WindowElement -ProcessId $configuratorProcess.Id -TimeoutSeconds $UiTimeoutSeconds
    $result.configuratorLaunch = $true

    $tokenInput = Find-DescendantByAutomationId -Root $window -AutomationId 'input-gateway-auth-token' -TimeoutSeconds $UiTimeoutSeconds
    Set-UiText -Element $tokenInput -Text 'smoketokenuia1'

    $portInput = Find-DescendantByAutomationId -Root $window -AutomationId 'input-gateway-port' -TimeoutSeconds $UiTimeoutSeconds
    Set-UiText -Element $portInput -Text ([string]$LauncherPort)

    $saveButton = Find-DescendantByAutomationId -Root $window -AutomationId 'action-save-config' -TimeoutSeconds $UiTimeoutSeconds
    Invoke-UiElement -Element $saveButton

    $saved = Wait-SmokeUntil -TimeoutSeconds 20 -Condition {
        if (-not (Test-Path $configPath)) {
            return $false
        }

        $content = Get-Content -Path $configPath -Raw
        return $content -match 'smoketokenuia1' -and $content -match ('"port"\s*:\s*' + $LauncherPort)
    }

    if (-not $saved) {
        throw 'Configurator smoke save did not update token/port in openclaw.json.'
    }

    $savedJson = Get-Content -Path $configPath -Raw
    $result.tokenPersisted = $savedJson -match 'smoketokenuia1'
    $result.portPersisted = $savedJson -match ('"port"\s*:\s*' + $LauncherPort)
    $result.rawArrayPreserved = $savedJson -match 'http://localhost:3000' -and $savedJson -match 'https://example.test'
    $result.rawJsonApply = $result.rawArrayPreserved
    $result.derivedKeysPersisted = $savedJson -match 'healthcheck' -or $savedJson -match 'dashboard'
    $result.systemObjectLeak = $savedJson -match 'System\.Object\[\]'

    Stop-ProcessSafely -Process $configuratorProcess
    $configuratorProcess = $null

    if (Test-Path $launcherLogPath) {
        Remove-Item -Path $launcherLogPath -Force
    }

    $launcherProcess = Start-Process -FilePath $LauncherPath -ArgumentList @('--log', $launcherLogPath, '--timeout', '45', '--quiet-errors') -PassThru

    $result.launcherRuntimeTargetFollowed = Wait-SmokeUntil -TimeoutSeconds 60 -Condition {
        if (-not (Test-Path $launcherLogPath)) {
            return $false
        }

        $content = Get-Content -Path $launcherLogPath -Raw -ErrorAction SilentlyContinue
        return $content -match ('Gateway runtime target: .*port=' + $LauncherPort)
    }

    $result.launcherReady = Wait-SmokeUntil -TimeoutSeconds 60 -Condition {
        if (-not (Test-Path $launcherLogPath)) {
            return $false
        }

        $content = Get-Content -Path $launcherLogPath -Raw -ErrorAction SilentlyContinue
        return $content -match 'Control UI is ready for use\.'
    }

    Stop-ProcessSafely -Process $launcherProcess
    $launcherProcess = $null

    & $validateScript -ManifestPath $manifestPath -LauncherPath $LauncherPath -Scenario Launch | Out-Null
    $result.launchValidation = 'PASS'

    if ($result.configuratorLaunch -and $result.rawJsonApply -and $result.tokenPersisted -and $result.portPersisted -and $result.rawArrayPreserved -and -not $result.derivedKeysPersisted -and -not $result.systemObjectLeak -and $result.launcherRuntimeTargetFollowed) {
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
    Write-Host ('Installed configurator smoke report: ' + $ReportPath)

    if ($result.overall -ne 'PASS') {
        throw ('Installed configurator smoke failed: ' + $result.error)
    }
}