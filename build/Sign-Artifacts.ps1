[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string[]]$FilePaths,
    [string]$CertificateThumbprint = $env:OPENCLAW_SIGN_CERT_THUMBPRINT,
    [string]$PfxPath = $env:OPENCLAW_SIGN_PFX_PATH,
    [string]$PfxPassword = $env:OPENCLAW_SIGN_PFX_PASSWORD,
    [string]$TimestampUrl = $(if ($env:OPENCLAW_SIGN_TIMESTAMP_URL) { $env:OPENCLAW_SIGN_TIMESTAMP_URL } else { 'http://timestamp.digicert.com' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

function Get-DefaultArtifactPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    return @(
        (Join-Path $Root 'artifacts\launcher\OpenClawLauncher.exe'),
        (Join-Path $Root 'artifacts\installer\OpenClawSetup.exe')
    )
}

function Resolve-ArtifactPaths {
    param(
        [string[]]$Paths
    )

    $resolved = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        $fullPath = [System.IO.Path]::GetFullPath($path)
        if (-not (Test-Path $fullPath)) {
            throw "Signing target was not found: $fullPath"
        }

        if (-not $resolved.Contains($fullPath)) {
            $resolved.Add($fullPath)
        }
    }

    if ($resolved.Count -eq 0) {
        throw 'No signing targets were provided.'
    }

    return $resolved.ToArray()
}

function Get-SignToolPath {
    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) {
        return $command.Source
    }

    $searchRoots = @(
        'C:\Program Files (x86)\Windows Kits\10\bin',
        'C:\Program Files\Windows Kits\10\bin',
        'C:\Program Files (x86)\Windows Kits\11\bin',
        'C:\Program Files\Windows Kits\11\bin',
        'C:\Program Files (x86)\Microsoft SDKs\ClickOnce\SignTool',
        'C:\Program Files\Microsoft SDKs\ClickOnce\SignTool'
    )

    $candidates = foreach ($root in $searchRoots) {
        if (Test-Path $root) {
            Get-ChildItem -Path $root -Filter 'signtool.exe' -Recurse -ErrorAction SilentlyContinue
        }
    }

    return ($candidates | Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName)
}

function Test-IsCodeSigningCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    if (-not $Certificate.HasPrivateKey) {
        return $false
    }

    foreach ($eku in @($Certificate.EnhancedKeyUsageList)) {
        if ($eku.ObjectId -eq '1.3.6.1.5.5.7.3.3' -or $eku.FriendlyName -in @('Code Signing', '代码签名')) {
            return $true
        }
    }

    return $false
}

function Get-CodeSigningCertificateFromStore {
    param(
        [string]$Thumbprint
    )

    $normalizedThumbprint = if ($Thumbprint) { ($Thumbprint -replace '\s', '').ToUpperInvariant() } else { $null }
    $candidates = foreach ($storePath in @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')) {
        if (Test-Path $storePath) {
            Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue
        }
    }

    $eligible = @($candidates | Where-Object { Test-IsCodeSigningCertificate -Certificate $_ })
    if ($normalizedThumbprint) {
        $eligible = @($eligible | Where-Object { $_.Thumbprint.ToUpperInvariant() -eq $normalizedThumbprint })
        if ($eligible.Count -eq 0) {
            throw "No code-signing certificate matched thumbprint $normalizedThumbprint."
        }
    } elseif ($eligible.Count -gt 1) {
        $subjects = ($eligible | Select-Object -ExpandProperty Subject) -join '; '
        throw "Multiple code-signing certificates were found. Set OPENCLAW_SIGN_CERT_THUMBPRINT to select one. Candidates: $subjects"
    }

    if ($eligible.Count -eq 0) {
        throw 'No usable code-signing certificate was found in Cert:\CurrentUser\My or Cert:\LocalMachine\My.'
    }

    return $eligible[0]
}

function Get-CodeSigningCertificate {
    param(
        [string]$Thumbprint,
        [string]$PackagePath,
        [string]$PackagePassword
    )

    if ($PackagePath) {
        if (-not (Test-Path $PackagePath)) {
            throw "Signing PFX was not found: $PackagePath"
        }

        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable `
            -bor [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PackagePath, $PackagePassword, $flags)
        if (-not (Test-IsCodeSigningCertificate -Certificate $certificate)) {
            throw "The PFX does not contain a usable code-signing certificate: $PackagePath"
        }

        return $certificate
    }

    return Get-CodeSigningCertificateFromStore -Thumbprint $Thumbprint
}

function Invoke-SignTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SignToolPath,
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string]$Thumbprint,
        [string]$PackagePath,
        [string]$PackagePassword,
        [string]$TimestampServer
    )

    $arguments = @(
        'sign',
        '/fd', 'SHA256',
        '/td', 'SHA256',
        '/d', 'OpenClaw'
    )

    if ($TimestampServer) {
        $arguments += @('/tr', $TimestampServer)
    }

    if ($PackagePath) {
        $arguments += @('/f', $PackagePath)
        if ($PackagePassword) {
            $arguments += @('/p', $PackagePassword)
        }
    } elseif ($Thumbprint) {
        $arguments += @('/sha1', $Thumbprint)
    } else {
        $arguments += '/a'
    }

    $arguments += $FilePath

    Write-Host "Signing $FilePath with SignTool: $SignToolPath"
    $process = Start-Process -FilePath $SignToolPath -ArgumentList $arguments -NoNewWindow -PassThru -Wait
    if ($process.ExitCode -eq 0) {
        return
    }

    if ($TimestampServer) {
        Write-Warning "SignTool failed to timestamp $FilePath. Retrying without timestamp."
        $retryArguments = $arguments | Where-Object { $_ -notin @('/tr', $TimestampServer) }
        $retryProcess = Start-Process -FilePath $SignToolPath -ArgumentList $retryArguments -NoNewWindow -PassThru -Wait
        if ($retryProcess.ExitCode -eq 0) {
            return
        }
    }

    throw "SignTool failed for $FilePath with exit code $($process.ExitCode)."
}

function Invoke-AuthenticodeSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [string]$TimestampServer
    )

    Write-Host "Signing $FilePath with Set-AuthenticodeSignature"
    try {
        if ($TimestampServer) {
            $signature = Set-AuthenticodeSignature -FilePath $FilePath -Certificate $Certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer
        } else {
            $signature = Set-AuthenticodeSignature -FilePath $FilePath -Certificate $Certificate -HashAlgorithm SHA256
        }
    } catch {
        if (-not $TimestampServer) {
            throw
        }

        Write-Warning "Timestamping failed for $FilePath. Retrying without timestamp."
        $signature = Set-AuthenticodeSignature -FilePath $FilePath -Certificate $Certificate -HashAlgorithm SHA256
    }

    if (-not $signature.SignerCertificate) {
        throw "Signing did not produce a signer certificate for $FilePath."
    }

    if ($signature.Status -in @('HashMismatch', 'NotSupportedFileFormat', 'Incompatible')) {
        throw "Authenticode signing failed for $FilePath with status $($signature.Status)."
    }
}

function Test-SignedArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedThumbprint
    )

    $signature = Get-AuthenticodeSignature -FilePath $FilePath
    if (-not $signature.SignerCertificate) {
        throw "Verification failed because $FilePath is not signed."
    }

    $actualThumbprint = $signature.SignerCertificate.Thumbprint.ToUpperInvariant()
    if ($actualThumbprint -ne $ExpectedThumbprint.ToUpperInvariant()) {
        throw "Verification failed for $FilePath. Expected thumbprint $ExpectedThumbprint, got $actualThumbprint."
    }

    Write-Host ("Verified signature on {0}. Status: {1}" -f $FilePath, $signature.Status)
}

$targets = if ($FilePaths) { $FilePaths } else { Get-DefaultArtifactPaths -Root $RepositoryRoot }
$resolvedTargets = Resolve-ArtifactPaths -Paths $targets
$certificate = Get-CodeSigningCertificate -Thumbprint $CertificateThumbprint -PackagePath $PfxPath -PackagePassword $PfxPassword
$expectedThumbprint = $certificate.Thumbprint
$signTool = Get-SignToolPath

Write-Host ("Using signing certificate: {0} ({1})" -f $certificate.Subject, $expectedThumbprint)
if ($signTool) {
    Write-Host "Found SignTool: $signTool"
} else {
    Write-Warning 'signtool.exe was not found. Falling back to Set-AuthenticodeSignature.'
}

foreach ($target in $resolvedTargets) {
    if ($signTool) {
        Invoke-SignTool -SignToolPath $signTool -FilePath $target -Thumbprint $expectedThumbprint -PackagePath $PfxPath -PackagePassword $PfxPassword -TimestampServer $TimestampUrl
    } else {
        Invoke-AuthenticodeSignature -FilePath $target -Certificate $certificate -TimestampServer $TimestampUrl
    }

    Test-SignedArtifact -FilePath $target -ExpectedThumbprint $expectedThumbprint
}

Write-Host 'Signing completed successfully.'
