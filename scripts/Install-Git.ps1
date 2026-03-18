[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath
)

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

function Get-GitInstallRoot {
    foreach ($candidate in @(
        'C:\Program Files\Git',
        'C:\Program Files (x86)\Git'
    )) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-GitUninstallerPath {
    $uninstallEntries = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSObject.Properties['DisplayName'] -and
            $_.DisplayName -eq 'Git' -and
            $_.PSObject.Properties['UninstallString'] -and
            $_.UninstallString
        }

    foreach ($entry in $uninstallEntries) {
        if ($entry.UninstallString -match '"([^"]+unins\d+\.exe)"') {
            $candidate = $matches[1]
            if (Test-Path $candidate) {
                return $candidate
            }
        }
    }

    $installRoot = Get-GitInstallRoot
    if ($installRoot) {
        $fallback = Join-Path $installRoot 'unins000.exe'
        if (Test-Path $fallback) {
            return $fallback
        }
    }

    return $null
}

function Get-GitPathEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    return @(
        (Join-Path $InstallRoot 'cmd'),
        (Join-Path $InstallRoot 'mingw64\bin'),
        (Join-Path $InstallRoot 'usr\bin')
    ) | Where-Object { Test-Path $_ }
}

function Wait-ForGitInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerBaseName,
        [int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $gitPath = Get-GitCommandPath
        $installerProcesses = @(
            Get-CimInstance Win32_Process -Filter ("Name LIKE '{0}%'" -f $InstallerBaseName.Replace("'", "''")) -ErrorAction SilentlyContinue
        )

        if ($gitPath -and $installerProcesses.Count -eq 0) {
            return $gitPath
        }

        Start-Sleep -Seconds 2
        Refresh-ProcessPath
    }

    throw "Git for Windows installation did not finish within $TimeoutSeconds seconds."
}

$manifest = Read-JsonFile -Path $ManifestPath
$gitInfo = $manifest.git

$existingGit = Get-GitCommandPath
if ($existingGit) {
    Write-Log -Message "Git already available on PATH: $existingGit" -Level 'SUCCESS'
    return [pscustomobject]@{
        installedByBootstrap = $false
        gitPath = $existingGit
        pathEntries = @()
        uninstallerPath = (Get-GitUninstallerPath)
    }
}

$downloadDirectory = Join-Path $env:TEMP 'OpenClawInstaller'
$installerPath = Join-Path $downloadDirectory ("Git-" + $gitInfo.version + "-64-bit.exe")
New-Item -ItemType Directory -Force -Path $downloadDirectory | Out-Null

if (-not (Test-Path $installerPath)) {
    Write-Log -Message "Downloading Git for Windows $($gitInfo.version) from $($gitInfo.installerUrl)"
    Invoke-Retry -Description 'Git installer download' -Action {
        Invoke-WebRequest -UseBasicParsing -Uri $gitInfo.installerUrl -OutFile $installerPath
    }
}

$downloadHash = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($downloadHash -ne $gitInfo.installerSha256.ToLowerInvariant()) {
    Remove-Item -Force $installerPath -ErrorAction SilentlyContinue
    throw "Git installer hash mismatch. Expected $($gitInfo.installerSha256), got $downloadHash."
}

$installerArguments = @(
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    '/SP-',
    '/CLOSEAPPLICATIONS',
    '/RESTARTAPPLICATIONS',
    '/o:PathOption=Cmd',
    '/o:SSHOption=OpenSSH',
    '/o:CURLOption=WinSSL'
)

Write-Log -Message "Installing Git for Windows $($gitInfo.version) silently"
$installerProcess = Start-Process -FilePath $installerPath -ArgumentList $installerArguments -WindowStyle Hidden -PassThru
$installerBaseName = [System.IO.Path]::GetFileNameWithoutExtension($installerPath)
$gitPath = Wait-ForGitInstaller -InstallerBaseName $installerBaseName

Refresh-ProcessPath
$gitPath = Get-GitCommandPath
if (-not $gitPath) {
    throw 'Git for Windows completed, but git.exe is still unavailable.'
}

$installRoot = Get-GitInstallRoot
if (-not $installRoot) {
    throw 'Git for Windows completed, but the install directory could not be resolved.'
}

$pathEntries = Get-GitPathEntries -InstallRoot $installRoot
$uninstallerPath = Get-GitUninstallerPath
Write-Log -Message "Git for Windows is ready: $gitPath" -Level 'SUCCESS'

return [pscustomobject]@{
    installedByBootstrap = $true
    gitPath = $gitPath
    pathEntries = $pathEntries
    installRoot = $installRoot
    uninstallerPath = $uninstallerPath
}
