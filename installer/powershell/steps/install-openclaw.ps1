# install-openclaw.ps1 — Step 11: Execute Official OpenClaw Install + Gateway Onboarding
# Runs the pinned official OpenClaw installer (via PowerShell subprocess),
# verifies the CLI is available, then runs non-interactive gateway onboarding.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OfficialScriptPath,
    [string]$Channel = 'latest',
    [ValidateSet('npm', 'git')]
    [string]$InstallMethod = 'npm',
    [string[]]$AdditionalPathEntries = @(),
    [switch]$SkipOnboard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1')

# ══════════════════════════════════════════════════════════════════════════
#  Official OpenClaw Install
# ══════════════════════════════════════════════════════════════════════════

if (-not (Test-Path $OfficialScriptPath)) {
    throw (New-InstallerException -Code 'E3001' -Message "Official OpenClaw install script not found: $OfficialScriptPath")
}

$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = @(
    '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', $OfficialScriptPath,
    '-Tag', $Channel,
    '-InstallMethod', $InstallMethod,
    '-NoOnboard'
)

Write-Log -Message 'Invoking the pinned official OpenClaw installer'
Invoke-Retry -Description 'Official OpenClaw install' -MaxAttempts 3 -DelaySeconds 5 -Action {
    $envVars = @{}
    if ($AdditionalPathEntries -and $AdditionalPathEntries.Count -gt 0) {
        $joined = [string]::Join(';', ($AdditionalPathEntries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
        if (-not [string]::IsNullOrWhiteSpace($joined)) {
            $envVars['Path'] = $joined + ';' + $env:Path
        }
    }

    Invoke-ExternalCommand -FilePath $powershellPath -Arguments $arguments -EnvironmentVariables $envVars | Out-Null
}

Refresh-ProcessPath

$openclawPath = Get-OpenClawCommandPath
if (-not $openclawPath) {
    throw (New-InstallerException -Code 'E3001' -Message 'OpenClaw install script completed, but the openclaw command is not available on PATH.')
}

$version = (Invoke-OpenClaw -Arguments @('--version')).StdOut.Trim()
Write-Log -Message "Official OpenClaw install completed: $version" -Level 'SUCCESS'

# ══════════════════════════════════════════════════════════════════════════
#  Gateway Onboarding
# ══════════════════════════════════════════════════════════════════════════

if (-not $SkipOnboard) {
    $gatewayToken = New-RandomBase64Token

    $existingTokenResult = Invoke-OpenClaw -Arguments @('config', 'get', 'gateway.auth.token') -RedactStdOut -AllowNonZeroExit
    $existingToken = $existingTokenResult.StdOut.Trim()

    if ($existingToken) {
        Write-Log -Message 'Existing OpenClaw gateway token detected; reusing configuration.'
        Invoke-OpenClaw -Arguments @('doctor', '--non-interactive') -AllowNonZeroExit | Out-Null
        Invoke-OpenClaw -Arguments @('gateway', 'install', '--force') | Out-Null
        Invoke-OpenClaw -Arguments @('gateway', 'start') | Out-Null
        $gatewayToken = $existingToken
    } else {
        Write-Log -Message 'Running non-interactive onboarding for a local gateway'
        Invoke-OpenClaw -Arguments @(
            'onboard',
            '--non-interactive',
            '--mode', 'local',
            '--flow', 'quickstart',
            '--auth-choice', 'skip',
            '--gateway-auth', 'token',
            '--gateway-token', $gatewayToken,
            '--install-daemon',
            '--accept-risk'
        ) -SensitiveValues @($gatewayToken) | Out-Null
    }

    Wait-Until -Description 'OpenClaw gateway HTTP endpoint' -TimeoutSeconds 90 -PollSeconds 3 -Condition {
        return (Test-HttpEndpoint -Url 'http://127.0.0.1:18789/' -TimeoutSeconds 5)
    }

    Write-Log -Message 'OpenClaw local gateway is reachable.' -Level 'SUCCESS'
}

return [pscustomobject]@{
    commandPath   = $openclawPath
    version       = $version
    onboardingDone = (-not $SkipOnboard)
}
