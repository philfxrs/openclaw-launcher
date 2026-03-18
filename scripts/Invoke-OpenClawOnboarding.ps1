[CmdletBinding()]
param(
    [string]$GatewayToken
)

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

Refresh-ProcessPath

if (-not $GatewayToken) {
    $GatewayToken = New-RandomBase64Token
}

$existingTokenResult = Invoke-OpenClaw -Arguments @('config', 'get', 'gateway.auth.token') -RedactStdOut -AllowNonZeroExit
$existingToken = $existingTokenResult.StdOut.Trim()

if ($existingToken) {
    Write-Log -Message 'Existing OpenClaw gateway token detected; skipping first-run onboarding.'
    Invoke-OpenClaw -Arguments @('doctor', '--non-interactive') -AllowNonZeroExit | Out-Null
    Invoke-OpenClaw -Arguments @('gateway', 'install', '--force') | Out-Null
    Invoke-OpenClaw -Arguments @('gateway', 'start') | Out-Null
    $GatewayToken = $existingToken
} else {
    Write-Log -Message 'Running official non-interactive onboarding for a local gateway'
    Invoke-OpenClaw -Arguments @(
        'onboard',
        '--non-interactive',
        '--mode', 'local',
        '--flow', 'quickstart',
        '--auth-choice', 'skip',
        '--gateway-auth', 'token',
        '--gateway-token', $GatewayToken,
        '--install-daemon',
        '--accept-risk'
    ) -SensitiveValues @($GatewayToken) | Out-Null
}

Wait-Until -Description 'OpenClaw gateway HTTP endpoint' -TimeoutSeconds 90 -PollSeconds 3 -Condition {
    return (Test-HttpEndpoint -Url 'http://127.0.0.1:18789/' -TimeoutSeconds 5)
}

Write-Log -Message 'OpenClaw local gateway is reachable.' -Level 'SUCCESS'

return [pscustomobject]@{
    gatewayToken = $GatewayToken
}
