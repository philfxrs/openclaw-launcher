[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,
    [Parameter(Mandatory = $true)]
    [string]$P12Path,
    [Parameter(Mandatory = $true)]
    [string]$P12Password,
    [Parameter(Mandatory = $true)]
    [string]$AppleId,
    [Parameter(Mandatory = $true)]
    [string]$AppleTeamId,
    [Parameter(Mandatory = $true)]
    [string]$AppleAppSpecificPassword,
    [Parameter(Mandatory = $true)]
    [string]$MacOSAppSignIdentity,
    [Parameter(Mandatory = $true)]
    [string]$MacOSPkgSignIdentity,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GhPath {
    $command = Get-Command gh -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        return $command.Source
    }

    $candidates = @(
        'C:\Program Files\GitHub CLI\gh.exe',
        'C:\Program Files (x86)\GitHub CLI\gh.exe'
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw 'GitHub CLI (gh) was not found.'
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$StdIn
    )

    $gh = Get-GhPath
    if ($PSBoundParameters.ContainsKey('StdIn')) {
        $StdIn | & $gh @Arguments
    } else {
        & $gh @Arguments
    }

    if ($LASTEXITCODE -ne 0) {
        throw "gh command failed: $($Arguments -join ' ')"
    }
}

if (-not (Test-Path $P12Path)) {
    throw "P12 file was not found: $P12Path"
}

$resolvedP12Path = (Resolve-Path $P12Path).Path
$p12Base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($resolvedP12Path))

$operations = @(
    @{ Type = 'variable'; Name = 'OPENCLAW_MACOS_APP_SIGN_IDENTITY'; Value = $MacOSAppSignIdentity },
    @{ Type = 'variable'; Name = 'OPENCLAW_MACOS_PKG_SIGN_IDENTITY'; Value = $MacOSPkgSignIdentity },
    @{ Type = 'secret'; Name = 'MACOS_CERT_P12_BASE64'; Value = $p12Base64 },
    @{ Type = 'secret'; Name = 'MACOS_CERT_PASSWORD'; Value = $P12Password },
    @{ Type = 'secret'; Name = 'APPLE_ID'; Value = $AppleId },
    @{ Type = 'secret'; Name = 'APPLE_TEAM_ID'; Value = $AppleTeamId },
    @{ Type = 'secret'; Name = 'APPLE_APP_SPECIFIC_PASSWORD'; Value = $AppleAppSpecificPassword }
)

if ($DryRun) {
    $operations | ForEach-Object {
        Write-Host ("[DRY-RUN] {0} {1}" -f $_.Type.ToUpperInvariant(), $_.Name)
    }
    exit 0
}

Invoke-Gh -Arguments @('auth', 'status')

foreach ($operation in $operations) {
    if ($operation.Type -eq 'variable') {
        Write-Host "Setting variable $($operation.Name)"
        Invoke-Gh -Arguments @('variable', 'set', $operation.Name, '--repo', $Repository) -StdIn $operation.Value
    } else {
        Write-Host "Setting secret $($operation.Name)"
        Invoke-Gh -Arguments @('secret', 'set', $operation.Name, '--repo', $Repository) -StdIn $operation.Value
    }
}

Write-Host 'GitHub macOS signing configuration completed.'