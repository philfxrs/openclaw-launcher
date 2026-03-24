[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$manifestPath = Join-Path $RepositoryRoot 'installer\resources\manifests\dependencies.json'
$launcherPath = Join-Path $RepositoryRoot 'artifacts\launcher\OpenClawLauncher.exe'
$reportRoot = Join-Path $RepositoryRoot 'artifacts\test'
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$reportPath = Join-Path $reportRoot ('local-compatibility-matrix-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')

if (-not (Test-Path $manifestPath)) {
    throw 'Dependency manifest is missing. Run build\Test-LocalInstaller.ps1 first.'
}

function Invoke-DetectScenario {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioName,
        [hashtable]$Flags
    )

    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = Join-Path $RepositoryRoot 'installer\powershell\steps\detect-dependencies.ps1'

    $assignments = @()
    if ($Flags) {
        foreach ($pair in $Flags.GetEnumerator()) {
            $assignments += ('$env:{0}=''{1}''' -f $pair.Key, $pair.Value)
        }
    }

    $commandParts = @()
    if ($assignments.Count -gt 0) {
        $commandParts += ($assignments -join '; ')
    }
    $commandParts += ('$result = & ''' + $scriptPath + ''' -ManifestPath ''' + $manifestPath + '''')
    $commandParts += 'Write-Output ''##OPENCLAW_JSON##''' 
    $commandParts += '$result | ConvertTo-Json -Depth 8'
    $commandText = $commandParts -join '; '

    $process = Start-Process -FilePath $powershellPath -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $commandText) -RedirectStandardOutput (Join-Path $reportRoot ($ScenarioName + '.stdout.log')) -RedirectStandardError (Join-Path $reportRoot ($ScenarioName + '.stderr.log')) -Wait -PassThru -WindowStyle Hidden

    $stdout = Get-Content -Path (Join-Path $reportRoot ($ScenarioName + '.stdout.log')) -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content -Path (Join-Path $reportRoot ($ScenarioName + '.stderr.log')) -Raw -ErrorAction SilentlyContinue

    if ($process.ExitCode -ne 0) {
        throw ('Scenario ' + $ScenarioName + ' failed. stderr: ' + $stderr)
    }

    $parts = $stdout -split '##OPENCLAW_JSON##', 2
    if ($parts.Count -lt 2) {
        throw ('Scenario ' + $ScenarioName + ' did not produce JSON output.')
    }

    return ($parts[1].Trim() | ConvertFrom-Json)
}

function Assert-Scenario {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScenarioName,
        [Parameter(Mandatory = $true)]
        [object]$Result,
        [Parameter(Mandatory = $true)]
        [hashtable]$Expected
    )

    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Expected.Keys) {
        $actual = $Result.$key.installed
        if ($actual -ne $Expected[$key]) {
            $failures.Add(($key + ' expected=' + $Expected[$key] + ' actual=' + $actual))
        }
    }

    if ($failures.Count -gt 0) {
        return [pscustomobject]@{
            scenario = $ScenarioName
            status = 'FAIL'
            details = ($failures -join '; ')
        }
    }

    return [pscustomobject]@{
        scenario = $ScenarioName
        status = 'PASS'
        details = 'Detection matched expectations.'
    }
}

$results = New-Object System.Collections.Generic.List[object]

$scenarios = @(
    [pscustomobject]@{
        Name = 'BaselineCurrentMachine'
        Flags = @{}
        Expected = @{ node = $true; npm = $true; git = $true; webview2 = $true; openclaw = $false }
    },
    [pscustomobject]@{
        Name = 'SimulatedFreshMachine'
        Flags = @{ OPENCLAW_TEST_FORCE_MISSING_NODE = '1'; OPENCLAW_TEST_FORCE_MISSING_NPM = '1'; OPENCLAW_TEST_FORCE_MISSING_GIT = '1'; OPENCLAW_TEST_FORCE_MISSING_WEBVIEW2 = '1'; OPENCLAW_TEST_FORCE_MISSING_OPENCLAW = '1' }
        Expected = @{ node = $false; npm = $false; git = $false; webview2 = $false; openclaw = $false }
    },
    [pscustomobject]@{
        Name = 'SimulatedMissingNode'
        Flags = @{ OPENCLAW_TEST_FORCE_MISSING_NODE = '1'; OPENCLAW_TEST_FORCE_MISSING_NPM = '1' }
        Expected = @{ node = $false; npm = $false; git = $true; webview2 = $true; openclaw = $false }
    },
    [pscustomobject]@{
        Name = 'SimulatedMissingGit'
        Flags = @{ OPENCLAW_TEST_FORCE_MISSING_GIT = '1' }
        Expected = @{ node = $true; npm = $true; git = $false; webview2 = $true; openclaw = $false }
    },
    [pscustomobject]@{
        Name = 'SimulatedMissingWebView2'
        Flags = @{ OPENCLAW_TEST_FORCE_MISSING_WEBVIEW2 = '1' }
        Expected = @{ node = $true; npm = $true; git = $true; webview2 = $false; openclaw = $false }
    },
    [pscustomobject]@{
        Name = 'SimulatedPartialDependencies'
        Flags = @{ OPENCLAW_TEST_FORCE_MISSING_GIT = '1'; OPENCLAW_TEST_FORCE_MISSING_OPENCLAW = '1' }
        Expected = @{ node = $true; npm = $true; git = $false; webview2 = $true; openclaw = $false }
    }
)

foreach ($scenario in $scenarios) {
    Write-Host ('[MATRIX] ' + $scenario.Name)
    $result = Invoke-DetectScenario -ScenarioName $scenario.Name -Flags $scenario.Flags
    $results.Add((Assert-Scenario -ScenarioName $scenario.Name -Result $result -Expected $scenario.Expected))
}

Write-Host '[MATRIX] Validate baseline prerequisites'
$validateResult = 'SKIPPED'
$validateDetails = 'Launcher executable missing.'
if (Test-Path $launcherPath) {
    try {
        $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $validateScript = Join-Path $RepositoryRoot 'installer\validation\validate-install.ps1'
        $validateProcess = Start-Process -FilePath $powershellPath -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $validateScript, '-ManifestPath', $manifestPath, '-LauncherPath', $launcherPath, '-Scenario', 'Prerequisites') -Wait -PassThru -WindowStyle Hidden
        if ($validateProcess.ExitCode -eq 0) {
            $validateResult = 'PASS'
            $validateDetails = 'Baseline prerequisite validation passed.'
        } else {
            $validateResult = 'FAIL'
            $validateDetails = 'Baseline prerequisite validation failed with exit code ' + $validateProcess.ExitCode
        }
    } catch {
        $validateResult = 'FAIL'
        $validateDetails = $_.Exception.Message
    }
}

$results.Add([pscustomobject]@{
    scenario = 'BaselinePrerequisiteValidation'
    status = $validateResult
    details = $validateDetails
})

$lines = @()
$lines += ('OpenClaw local compatibility matrix - ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$lines += ''
foreach ($row in $results) {
    $lines += ('[' + $row.status + '] ' + $row.scenario)
    $lines += ('  ' + $row.details)
}

Set-Content -Path $reportPath -Value $lines -Encoding UTF8
Write-Host ('Compatibility matrix report: ' + $reportPath)

$failed = @($results | Where-Object { $_.status -eq 'FAIL' })
if ($failed.Count -gt 0) {
    throw ('Compatibility matrix failed: ' + (($failed | ForEach-Object { $_.scenario }) -join ', '))
}
