[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [switch]$SkipBuildInstaller,
    [switch]$SkipBuildLauncher,
    [switch]$SkipSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$reportRoot = Join-Path $RepositoryRoot 'artifacts\test'
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$reportPath = Join-Path $reportRoot ('local-installer-test-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')

$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Id,
        [string]$Name,
        [string]$Status,
        [string]$Details
    )

    $results.Add([pscustomobject]@{
        id = $Id
        name = $Name
        status = $Status
        details = $Details
    })
}

function Invoke-Check {
    param(
        [string]$Id,
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Host ('[CHECK] {0} - {1}' -f $Id, $Name)
    try {
        $details = & $Action
        Add-Result -Id $Id -Name $Name -Status 'PASS' -Details ([string]$details)
    } catch {
        Add-Result -Id $Id -Name $Name -Status 'FAIL' -Details $_.Exception.Message
        throw
    }
}

try {
    Invoke-Check -Id 'L001' -Name 'Installer tree exists' -Action {
        $required = @(
            'installer\inno\OpenClawSetup.iss',
            'installer\powershell\bootstrap.ps1',
            'installer\powershell\modules\errors.psm1',
            'installer\powershell\modules\logging.psm1',
            'installer\powershell\modules\common.psm1',
            'installer\validation\validate-install.ps1',
            'installer\validation\test-openclaw-ready.ps1',
            'installer\docs\local-test-plan.md',
            'installer\docs\release-checklist.md'
        )

        $missing = @($required | Where-Object { -not (Test-Path (Join-Path $RepositoryRoot $_)) })
        if ($missing.Count -gt 0) {
            throw ('Missing required files: ' + ($missing -join ', '))
        }

        return 'Required installer files are present.'
    }

    if (-not $SkipSync) {
        Invoke-Check -Id 'L002' -Name 'Sync upstream assets' -Action {
            & (Join-Path $RepositoryRoot 'build\Sync-UpstreamAssets.ps1') -RepositoryRoot $RepositoryRoot
            $manifestPath = Join-Path $RepositoryRoot 'installer\resources\manifests\dependencies.json'
            if (-not (Test-Path $manifestPath)) {
                throw 'Dependency manifest was not generated.'
            }

            return $manifestPath
        }
    }

    Invoke-Check -Id 'L003' -Name 'PowerShell syntax load' -Action {
        $scripts = @(
            'installer\powershell\init.ps1',
            'installer\powershell\uninstall.ps1',
            'installer\powershell\steps\detect-dependencies.ps1',
            'installer\powershell\steps\install-dependencies.ps1',
            'installer\powershell\steps\install-openclaw.ps1',
            'installer\powershell\steps\create-shortcut.ps1',
            'installer\powershell\steps\remove-residuals.ps1',
            'installer\validation\validate-install.ps1',
            'installer\validation\test-openclaw-ready.ps1'
        )

        foreach ($scriptPath in $scripts) {
            $full = Join-Path $RepositoryRoot $scriptPath
            $errors = $null
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$errors)
            if ($errors -and $errors.Count -gt 0) {
                throw ('Parser errors in ' + $scriptPath + ': ' + (($errors | ForEach-Object { $_.Message }) -join '; '))
            }
        }

        $bootstrapPath = Join-Path $RepositoryRoot 'installer\powershell\bootstrap.ps1'
        if (-not (Test-Path $bootstrapPath)) {
            throw 'bootstrap.ps1 is missing.'
        }

        return 'Installer scripts parsed successfully; bootstrap.ps1 presence verified.'
    }

    if (-not $SkipBuildLauncher) {
        Invoke-Check -Id 'L004' -Name 'Build launcher' -Action {
            & (Join-Path $RepositoryRoot 'build\Build-Launcher.ps1') -RepositoryRoot $RepositoryRoot -SkipSigning
            $launcherPath = Join-Path $RepositoryRoot 'artifacts\launcher\OpenClawLauncher.exe'
            if (-not (Test-Path $launcherPath)) {
                throw 'Launcher EXE not found after build.'
            }

            return $launcherPath
        }
    }

    if (-not $SkipBuildInstaller) {
        Invoke-Check -Id 'L005' -Name 'Build installer' -Action {
            & (Join-Path $RepositoryRoot 'build\Build-Installer.ps1') -RepositoryRoot $RepositoryRoot -SkipSigning -SkipSync
            $installerPath = Join-Path $RepositoryRoot 'artifacts\installer\OpenClawSetup.exe'
            if (-not (Test-Path $installerPath)) {
                throw 'Installer EXE not found after build.'
            }

            return $installerPath
        }
    }
} finally {
    $lines = @()
    $lines += ('OpenClaw local installer test report - ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    $lines += ''
    foreach ($row in $results) {
        $lines += ('[{0}] {1} {2}' -f $row.status, $row.id, $row.name)
        if ($row.details) {
            $lines += ('  ' + $row.details)
        }
    }

    Set-Content -Path $reportPath -Value $lines -Encoding UTF8
    Write-Host ('Test report written to ' + $reportPath)
}