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

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

if (-not (Test-Path $OfficialScriptPath)) {
    throw "Official OpenClaw install script not found: $OfficialScriptPath"
}

$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = @(
    '-NoLogo',
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $OfficialScriptPath,
    '-Tag',
    $Channel,
    '-InstallMethod',
    $InstallMethod
)

if ($SkipOnboard) {
    $arguments += '-NoOnboard'
}

Write-Log -Message 'Invoking the pinned official OpenClaw installer'
Invoke-Retry -Description 'Official OpenClaw install' -MaxAttempts 3 -DelaySeconds 5 -Action {
    $environmentVariables = @{}
    if ($AdditionalPathEntries -and $AdditionalPathEntries.Count -gt 0) {
        $joinedEntries = [string]::Join(';', ($AdditionalPathEntries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }))
        if (-not [string]::IsNullOrWhiteSpace($joinedEntries)) {
            $environmentVariables['Path'] = $joinedEntries + ';' + $env:Path
        }
    }

    Invoke-ExternalCommand -FilePath $powershellPath -Arguments $arguments -EnvironmentVariables $environmentVariables | Out-Null
}

Refresh-ProcessPath

$openclawPath = Get-OpenClawCommandPath
if (-not $openclawPath) {
    throw 'OpenClaw install script completed, but the openclaw command is not available on PATH.'
}

$version = (Invoke-OpenClaw -Arguments @('--version')).StdOut.Trim()
Write-Log -Message "Official OpenClaw install completed: $version" -Level 'SUCCESS'

return [pscustomobject]@{
    commandPath = $openclawPath
    version = $version
}
