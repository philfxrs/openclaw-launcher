[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ShortcutName = 'OpenClaw'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$manifestPath = Join-Path $RepositoryRoot 'installer\resources\manifests\dependencies.json'
$officialScriptPath = Join-Path $RepositoryRoot 'installer\resources\upstream\openclaw-install.ps1'
$launcherPath = Join-Path $RepositoryRoot 'artifacts\launcher\OpenClawLauncher.exe'
$reportRoot = Join-Path $RepositoryRoot 'artifacts\test'
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$reportPath = Join-Path $reportRoot ('current-machine-install-flow-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')

$required = @($manifestPath, $officialScriptPath, $launcherPath)
$missing = @($required | Where-Object { -not (Test-Path $_) })
if ($missing.Count -gt 0) {
    throw ('Missing required files: ' + ($missing -join ', '))
}

$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Details
    )

    $results.Add([pscustomobject]@{
        name = $Name
        status = $Status
        details = $Details
    })
}

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Host ('[FLOW] ' + $Name)
    try {
        $details = & $Action
        Add-Result -Name $Name -Status 'PASS' -Details ([string]$details)
    } catch {
        Add-Result -Name $Name -Status 'FAIL' -Details $_.Exception.Message
        throw
    }
}

try {
    Invoke-Step -Name 'Detect prerequisites' -Action {
        $result = & (Join-Path $RepositoryRoot 'installer\powershell\steps\detect-dependencies.ps1') -ManifestPath $manifestPath
        return ('node=' + $result.node.installed + ', git=' + $result.git.installed + ', webview2=' + $result.webview2.installed + ', openclaw=' + $result.openclaw.installed)
    }

    Invoke-Step -Name 'Install OpenClaw' -Action {
        $result = & (Join-Path $RepositoryRoot 'installer\powershell\steps\install-openclaw.ps1') -OfficialScriptPath $officialScriptPath -Channel latest -InstallMethod npm
        return ('command=' + $result.commandPath + ', version=' + $result.version)
    }

    Invoke-Step -Name 'Create shortcuts' -Action {
        $result = & (Join-Path $RepositoryRoot 'installer\powershell\steps\create-shortcut.ps1') -LauncherPath $launcherPath -ShortcutName $ShortcutName
        return ('desktop=' + $result.desktopShortcut + ', startMenu=' + $result.startMenuShortcut)
    }

    Invoke-Step -Name 'Validate installed state' -Action {
        $null = & (Join-Path $RepositoryRoot 'installer\validation\validate-install.ps1') -ManifestPath $manifestPath -LauncherPath $launcherPath -ShortcutName $ShortcutName -Scenario Installed
        return 'Installed validation passed.'
    }

    Invoke-Step -Name 'Validate launch state' -Action {
        $null = & (Join-Path $RepositoryRoot 'installer\validation\validate-install.ps1') -ManifestPath $manifestPath -LauncherPath $launcherPath -ShortcutName $ShortcutName -Scenario Launch
        return 'Launch validation passed.'
    }
} finally {
    $lines = @()
    $lines += ('OpenClaw current-machine install flow - ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    $lines += ''
    foreach ($row in $results) {
        $lines += ('[' + $row.status + '] ' + $row.name)
        $lines += ('  ' + $row.details)
    }

    if ($results.Count -eq 0) {
        $lines += '[FAIL] Flow did not execute any steps.'
    }

    Set-Content -Path $reportPath -Value $lines -Encoding UTF8
    Write-Host ('Current machine flow report: ' + $reportPath)
}
