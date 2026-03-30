# common.psm1 — OpenClaw Installer Shared Utilities Module
# Provides system detection, install-state management, process execution,
# retry helpers, shortcut helpers, and OpenClaw CLI wrappers.
# Compatible with PowerShell 5.1+.

Set-StrictMode -Version Latest

$modulesRoot = $PSScriptRoot
Import-Module (Join-Path $modulesRoot 'errors.psm1')  -Force -DisableNameChecking
Import-Module (Join-Path $modulesRoot 'logging.psm1') -Force -DisableNameChecking

$script:Utf8Enc = Get-Utf8NoBomEncoding
$script:LastExternalCommandInfo = $null

function Test-ForcedMissingDependency {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $normalized = $Name.ToUpperInvariant()
    $globalFlag = [Environment]::GetEnvironmentVariable('OPENCLAW_TEST_FORCE_MISSING_ALL')
    $specificFlag = [Environment]::GetEnvironmentVariable('OPENCLAW_TEST_FORCE_MISSING_' + $normalized)

    foreach ($value in @($globalFlag, $specificFlag)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }

        switch ($value.ToLowerInvariant()) {
            '1' { return $true }
            'true' { return $true }
            'yes' { return $true }
            'on' { return $true }
        }
    }

    return $false
}

function New-InstallerException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [System.Exception]$InnerException
    )

    return errors\New-InstallerException @PSBoundParameters
}

function Get-InstallerErrorCode {
    [CmdletBinding()]
    param(
        [System.Exception]$Exception,
        [string]$DefaultCode = 'E9001'
    )

    return errors\Get-InstallerErrorCode @PSBoundParameters
}

function Get-ErrorCodeDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code
    )

    return errors\Get-ErrorCodeDescription @PSBoundParameters
}

function Get-AllErrorCodes {
    return errors\Get-AllErrorCodes
}

function Initialize-InstallerSession {
    [CmdletBinding()]
    param(
        [string]$ProductName = 'OpenClawInstaller',
        [string]$LogRoot = (Join-Path $env:ProgramData 'OpenClawInstaller\Logs')
    )

    return logging\Initialize-InstallerSession @PSBoundParameters
}

function Set-InstallerStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StepId,
        [Parameter(Mandatory = $true)]
        [string]$StepName,
        [int]$StepNumber = 0
    )

    return logging\Set-InstallerStep @PSBoundParameters
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO',
        [string]$Code,
        [hashtable]$Data
    )

    return logging\Write-Log @PSBoundParameters
}

function Write-Stage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StageId,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateRange(0, 100)]
        [int]$Percent = 0
    )

    return logging\Write-Stage @PSBoundParameters
}

# ══════════════════════════════════════════════════════════════════════════
#  Administrator
# ══════════════════════════════════════════════════════════════════════════

function Assert-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw (New-InstallerException -Code 'E1002' -Message 'Administrator privileges are required to continue.')
    }
}

# ══════════════════════════════════════════════════════════════════════════
#  PATH Management
# ══════════════════════════════════════════════════════════════════════════

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $segments    = @()

    foreach ($segment in @($machinePath, $userPath) -split ';') {
        if (-not [string]::IsNullOrWhiteSpace($segment) -and -not ($segments -contains $segment)) {
            $segments += $segment
        }
    }

    $env:Path = [string]::Join(';', $segments)
}

# ══════════════════════════════════════════════════════════════════════════
#  JSON I/O (UTF-8)
# ══════════════════════════════════════════════════════════════════════════

function Read-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "JSON file not found: $Path"
    }

    return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }

    Set-Utf8FileContent -Path $Path -Content ($InputObject | ConvertTo-Json -Depth 8)
}

# ══════════════════════════════════════════════════════════════════════════
#  Install State Persistence
# ══════════════════════════════════════════════════════════════════════════

function New-InstallState {
    return [ordered]@{
        schemaVersion          = 2
        startedAtUtc           = (Get-Date).ToUniversalTime().ToString('o')
        lastUpdatedAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
        completedAtUtc         = $null
        installRoot            = $null
        mode                   = 'Auto'
        logPaths               = [ordered]@{ text = $null; json = $null; transcript = $null }
        steps                  = [ordered]@{}
        system                 = $null
        dependencies           = [ordered]@{
            node     = $null
            npm      = $null
            git      = $null
            webview2 = $null
            openclaw = $null
        }
        nodeInstalledByBootstrap = $false
        nodeProductCode          = $null
        gitInstalledByBootstrap  = $false
        gitUninstallerPath       = $null
        officialInstallComplete  = $false
        onboardingComplete       = $false
        launcherValidated        = $false
        shortcuts                = @()
        lastError                = $null
        lastErrorCode            = $null
    }
}

function Read-InstallState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) { return $null }

    return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-InstallState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $State.lastUpdatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-JsonFile -InputObject $State -Path $Path
}

function Update-InstallStateStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,
        [Parameter(Mandatory = $true)]
        [string]$StepId,
        [Parameter(Mandatory = $true)]
        [ValidateSet('pending', 'running', 'completed', 'failed', 'skipped')]
        [string]$Status,
        [string]$Code,
        [string]$Message
    )

    if (-not $State.steps) {
        $State.steps = [ordered]@{}
    }

    $existing = $State.steps.$StepId
    if (-not $existing) {
        $existing = [ordered]@{
            startedAtUtc   = $null
            completedAtUtc = $null
            status         = 'pending'
            code           = $null
            message        = $null
        }
    }

    if ($Status -eq 'running' -and -not $existing.startedAtUtc) {
        $existing.startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    if ($Status -in @('completed', 'failed', 'skipped')) {
        $existing.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        if (-not $existing.startedAtUtc) {
            $existing.startedAtUtc = $existing.completedAtUtc
        }
    }

    $existing.status  = $Status
    $existing.code    = $Code
    $existing.message = $Message
    $State.steps.$StepId = $existing
}

# ══════════════════════════════════════════════════════════════════════════
#  Command / Dependency Detection
# ══════════════════════════════════════════════════════════════════════════

function Get-NodeVersionInfo {
    if (Test-ForcedMissingDependency -Name 'NODE') {
        return $null
    }

    try {
        $raw = (& node -v 2>$null)
        if (-not $raw) { return $null }

        $major = [int]($raw -replace '^v(\d+)\..*$', '$1')
        return [pscustomobject]@{ raw = $raw.Trim(); major = $major }
    } catch {
        return $null
    }
}

function Get-CommandPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Candidates
    )

    if (($Candidates -contains 'npm.cmd' -or $Candidates -contains 'npm.exe' -or $Candidates -contains 'npm') -and (Test-ForcedMissingDependency -Name 'NPM')) {
        return $null
    }

    foreach ($candidate in $Candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    }

    return $null
}

function Test-CommandExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string[]]$VersionArguments = @('--version')
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    try {
        $output = & $Path @VersionArguments 2>$null | Out-String
        if ($LASTEXITCODE -ne 0) {
            return $false
        }

        return -not [string]::IsNullOrWhiteSpace($output.Trim())
    } catch {
        return $false
    }
}

function Get-OpenClawCommandPath {
    if (Test-ForcedMissingDependency -Name 'OPENCLAW') {
        return $null
    }

    $resolved = Get-CommandPath -Candidates @('openclaw.cmd', 'openclaw.exe', 'openclaw')
    if ($resolved) { return $resolved }

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $fallback = Join-Path $env:APPDATA 'npm\openclaw.cmd'
        if (Test-Path $fallback) { return $fallback }
    }

    return $null
}

function Get-NpmCommandPath {
    $resolved = Get-CommandPath -Candidates @('npm.cmd', 'npm.exe', 'npm')
    if (-not $resolved) {
        throw (New-InstallerException -Code 'E2003' -Message 'npm was not found on PATH.')
    }

    return $resolved
}

function Get-GitCommandPath {
    if (Test-ForcedMissingDependency -Name 'GIT') {
        return $null
    }

    $resolved = Get-CommandPath -Candidates @('git.exe', 'git')
    if ($resolved -and (Test-CommandExecutable -Path $resolved)) { return $resolved }

    foreach ($candidate in @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe'
    )) {
        if ((Test-Path $candidate) -and (Test-CommandExecutable -Path $candidate)) { return $candidate }
    }

    return $null
}

function Get-EdgePath {
    if (Test-ForcedMissingDependency -Name 'EDGE') {
        return $null
    }

    $registryCandidates = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    )

    foreach ($registryPath in $registryCandidates) {
        try {
            $entry = Get-ItemProperty -Path $registryPath -ErrorAction Stop
            if ($entry.'(default)' -and (Test-Path $entry.'(default)')) {
                return $entry.'(default)'
            }
        } catch { }
    }

    foreach ($candidate in @(
        "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }

    return $null
}

function Get-WebView2RuntimeVersion {
    if (Test-ForcedMissingDependency -Name 'WEBVIEW2') {
        return $null
    }

    $registryCandidates = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )

    foreach ($registryPath in $registryCandidates) {
        try {
            $entry = Get-ItemProperty -Path $registryPath -ErrorAction Stop
            $version = [string]$entry.pv
            if (-not [string]::IsNullOrWhiteSpace($version) -and $version -ne '0.0.0.0') {
                return $version
            }
        } catch { }
    }

    return $null
}

function Test-WebView2RuntimeInstalled {
    return [bool](Get-WebView2RuntimeVersion)
}

# ══════════════════════════════════════════════════════════════════════════
#  Shortcut Paths
# ══════════════════════════════════════════════════════════════════════════

function Get-DesktopShortcutPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutName
    )

    return (Join-Path ([Environment]::GetFolderPath('Desktop')) "$ShortcutName.lnk")
}

function Get-StartMenuShortcutPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutName
    )

    return (Join-Path ([Environment]::GetFolderPath('Programs')) "$ShortcutName.lnk")
}

# ══════════════════════════════════════════════════════════════════════════
#  Cryptographic Helpers
# ══════════════════════════════════════════════════════════════════════════

function New-RandomBase64Token {
    [CmdletBinding()]
    param(
        [int]$ByteCount = 32
    )

    $bytes = New-Object byte[] $ByteCount
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# ══════════════════════════════════════════════════════════════════════════
#  Retry / Wait Utilities
# ══════════════════════════════════════════════════════════════════════════

function Invoke-Retry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [int]$MaxAttempts  = 3,
        [int]$DelaySeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return (& $Action)
        } catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Log -Message "$Description failed (attempt $attempt/$MaxAttempts). Retrying in ${DelaySeconds}s." -Level 'WARN'
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Test-HttpEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [int]$TimeoutSeconds = 5
    )

    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method           = 'GET'
        $request.Timeout          = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $response = $request.GetResponse()
        if ($response) { $response.Close() }
        return $true
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $_.Exception.Response.Close()
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Wait-Until {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [int]$TimeoutSeconds = 60,
        [int]$PollSeconds    = 2
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for $Description."
}

function Test-TextLooksCorrupted {
    [CmdletBinding()]
    param(
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return ($Text.Contains([char]0xFFFD) -or $Text -match '�{2,}')
}

function Get-CommandVersionText {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [string[]]$Arguments = @('--version')
    )

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not (Test-Path $FilePath)) {
        return $null
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = [string]::Join(' ', $Arguments)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    try {
        $psi.StandardOutputEncoding = $script:Utf8Enc
        $psi.StandardErrorEncoding = $script:Utf8Enc
    } catch { }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        [void]$process.Start()
        $stdOut = $process.StandardOutput.ReadToEnd()
        $stdErr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
    } catch {
        return $null
    }

    if ($process.ExitCode -ne 0) {
        return $null
    }

    foreach ($candidate in @($stdOut, $stdErr)) {
        foreach ($line in ($candidate -split "`r?`n")) {
            $trimmed = $line.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                return $trimmed
            }
        }
    }

    return $null
}

function Protect-DiagnosticText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        return $null
    }

    $value = [string]$Text
    $userProfile = [Environment]::GetFolderPath('UserProfile')

    if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
        $value = $value.Replace($userProfile, '%USERPROFILE%')
    }

    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        $value = [regex]::Replace(
            $value,
            [regex]::Escape($env:COMPUTERNAME),
            '<HOST>',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    $value = [regex]::Replace(
        $value,
        '(?i)\b(token|key|secret|password|auth|credential)\b\s*[:=]\s*([^\s,;]+)',
        '$1=__REDACTED__'
    )

    return $value
}

function Get-DiagnosticFallbackValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,
        [string]$Reason
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $typeName = $null
    try {
        $typeName = $InputObject.GetType().FullName
    } catch {
        $typeName = $null
    }

    if ($InputObject -is [string]) {
        return (Protect-DiagnosticText -Text $InputObject)
    }

    if ($InputObject -is [ValueType]) {
        return $InputObject
    }

    $fallback = [ordered]@{
        type = $typeName
    }

    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $fallback.reason = (Protect-DiagnosticText -Text $Reason)
    }

    try {
        $text = [string]$InputObject
        if (-not [string]::IsNullOrWhiteSpace($text) -and $text -ne $typeName) {
            $fallback.value = (Protect-DiagnosticText -Text $text)
        }
    } catch {
    }

    return $fallback
}

function Get-DiagnosticObjectProperties {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return @()
    }

    try {
        if ($null -eq $InputObject.PSObject) {
            return @()
        }

        return @($InputObject.PSObject.Properties | Where-Object { $_ -and $_.IsGettable })
    } catch {
        return @()
    }
}

function Get-MinimalDiagnosticsSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerVersion,
        [Parameter(Mandatory = $true)]
        [string]$BuildVersion,
        [Parameter(Mandatory = $true)]
        [string]$ErrorCode,
        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage,
        [string]$LocalLogPath,
        [string]$LocalStatePath,
        [string]$FallbackReason
    )

    $summary = [ordered]@{
        schemaVersion = 1
        source = 'windows-installer'
        installerVersion = $InstallerVersion
        buildVersion = $BuildVersion
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        errorCode = $ErrorCode
        errorMessage = (Protect-DiagnosticText -Text $ErrorMessage)
        references = [ordered]@{
            localLogPath = $LocalLogPath
            localStatePath = $LocalStatePath
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($FallbackReason)) {
        $summary.summaryMode = 'minimal-fallback'
        $summary.fallbackReason = (Protect-DiagnosticText -Text $FallbackReason)
    }

    return $summary
}

function Protect-DiagnosticObject {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,
        [int]$Depth = 0
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($Depth -ge 8) {
        return (Get-DiagnosticFallbackValue -InputObject $InputObject -Reason 'max-depth-reached')
    }

    try {
        if ($InputObject -is [string]) {
            return (Protect-DiagnosticText -Text $InputObject)
        }

        if ($InputObject -is [ValueType]) {
            return $InputObject
        }

        if ($InputObject -is [System.Collections.IDictionary]) {
            $dictionary = [ordered]@{}
            foreach ($key in @($InputObject.Keys)) {
                $name = [string]$key
                if ($name -match '(?i)token|key|secret|password|auth|credential') {
                    $dictionary[$name] = '__REDACTED__'
                } else {
                    try {
                        $dictionary[$name] = Protect-DiagnosticObject -InputObject $InputObject[$key] -Depth ($Depth + 1)
                    } catch {
                        $dictionary[$name] = Get-DiagnosticFallbackValue -InputObject $InputObject[$key] -Reason $_.Exception.Message
                    }
                }
            }

            return $dictionary
        }

        if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
            $items = @()
            foreach ($item in $InputObject) {
                try {
                    $items += ,(Protect-DiagnosticObject -InputObject $item -Depth ($Depth + 1))
                } catch {
                    $items += ,(Get-DiagnosticFallbackValue -InputObject $item -Reason $_.Exception.Message)
                }
            }

            return $items
        }

        $properties = Get-DiagnosticObjectProperties -InputObject $InputObject
        if (@($properties).Count -gt 0) {
            $objectCopy = [ordered]@{}
            foreach ($property in $properties) {
                if ($property.Name -match '(?i)token|key|secret|password|auth|credential') {
                    $objectCopy[$property.Name] = '__REDACTED__'
                    continue
                }

                try {
                    $objectCopy[$property.Name] = Protect-DiagnosticObject -InputObject $property.Value -Depth ($Depth + 1)
                } catch {
                    $objectCopy[$property.Name] = Get-DiagnosticFallbackValue -InputObject $property.Value -Reason $_.Exception.Message
                }
            }

            return $objectCopy
        }

        return (Get-DiagnosticFallbackValue -InputObject $InputObject)
    } catch {
        return (Get-DiagnosticFallbackValue -InputObject $InputObject -Reason $_.Exception.Message)
    }
}

function Get-LastExternalCommandInfo {
    if (-not $script:LastExternalCommandInfo) {
        return $null
    }

    return [pscustomobject]@{
        filePath = $script:LastExternalCommandInfo.filePath
        arguments = @($script:LastExternalCommandInfo.arguments)
        exitCode = $script:LastExternalCommandInfo.exitCode
    }
}

function New-DiagnosticsSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,
        [Parameter(Mandatory = $true)]
        [string]$InstallerVersion,
        [Parameter(Mandatory = $true)]
        [string]$BuildVersion,
        [Parameter(Mandatory = $true)]
        [string]$ErrorCode,
        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage,
        [string]$LocalLogPath,
        [string]$LocalStatePath
    )

    try {
        $session = logging\Get-InstallerSessionInfo
        $lastCommandInfo = Get-LastExternalCommandInfo
        $nodeVersion = $null
        if ($State.dependencies -and $State.dependencies.node) {
            $nodeVersion = $State.dependencies.node.version
        }

        $npmVersion = $null
        if ($State.dependencies -and $State.dependencies.npm -and $State.dependencies.npm.path) {
            $npmVersion = Get-CommandVersionText -FilePath $State.dependencies.npm.path
        }

        $gitVersion = $null
        if ($State.dependencies -and $State.dependencies.git -and $State.dependencies.git.path) {
            $gitVersion = Get-CommandVersionText -FilePath $State.dependencies.git.path
        }

        $summary = [ordered]@{
            schemaVersion = 1
            source = 'windows-installer'
            installerVersion = $InstallerVersion
            buildVersion = $BuildVersion
            timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
            osVersion = [Environment]::OSVersion.VersionString
            architecture = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
            isAdmin = (
                New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            locale = [System.Globalization.CultureInfo]::CurrentCulture.Name
            currentStep = [ordered]@{
                id = if ($session) { $session.currentStepId } else { $null }
                number = if ($session) { $session.currentStepNumber } else { $null }
                name = if ($session) { $session.currentStepName } else { $null }
            }
            failedStep = [ordered]@{
                id = if ($session) { $session.currentStepId } else { $null }
                code = $ErrorCode
            }
            errorCode = $ErrorCode
            errorMessage = $ErrorMessage
            lastCommand = if ($lastCommandInfo) { ((@($lastCommandInfo.filePath) + @($lastCommandInfo.arguments)) -join ' ').Trim() } else { $null }
            exitCode = if ($lastCommandInfo) { $lastCommandInfo.exitCode } else { $null }
            dependencies = [ordered]@{
                node = [ordered]@{
                    detected = [bool]($State.dependencies -and $State.dependencies.node -and $State.dependencies.node.installed)
                    version = $nodeVersion
                }
                npm = [ordered]@{
                    detected = [bool]($State.dependencies -and $State.dependencies.npm -and $State.dependencies.npm.installed)
                    version = $npmVersion
                }
                git = [ordered]@{
                    detected = [bool]($State.dependencies -and $State.dependencies.git -and $State.dependencies.git.installed)
                    version = $gitVersion
                }
                webview2 = [ordered]@{
                    detected = [bool]($State.dependencies -and $State.dependencies.webview2 -and $State.dependencies.webview2.installed)
                }
                openclaw = [ordered]@{
                    detected = [bool]($State.dependencies -and $State.dependencies.openclaw -and $State.dependencies.openclaw.installed)
                }
            }
            installationState = [ordered]@{
                launcherExists = [bool]($State.installRoot -and (Test-Path (Join-Path $State.installRoot 'bin\OpenClawLauncher.exe')))
                shortcutExists = [bool]($State.shortcuts -and @($State.shortcuts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)
                gatewayReachable = [bool]$State.launcherValidated
                installRootExists = [bool]($State.installRoot -and (Test-Path $State.installRoot))
            }
            references = [ordered]@{
                localLogPath = $LocalLogPath
                localStatePath = $LocalStatePath
            }
        }

        return (Protect-DiagnosticObject -InputObject $summary)
    } catch {
        return (Get-MinimalDiagnosticsSummary -InstallerVersion $InstallerVersion -BuildVersion $BuildVersion -ErrorCode $ErrorCode -ErrorMessage $ErrorMessage -LocalLogPath $LocalLogPath -LocalStatePath $LocalStatePath -FallbackReason $_.Exception.Message)
    }
}

function Get-ExternalCommandFailureSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        [string]$StdErr,
        [string]$StdOut
    )

    $reason = $null
    foreach ($candidate in @($StdErr, $StdOut)) {
        foreach ($line in ($candidate -split "`r?`n")) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }

            if (-not (Test-TextLooksCorrupted -Text $trimmed)) {
                $reason = $trimmed
                break
            }
        }

        if ($reason) {
            break
        }
    }

    if (-not $reason) {
        $commandName = [System.IO.Path]::GetFileName($FilePath)
        $argumentText = [string]::Join(' ', $Arguments)

        if ($commandName -ieq 'git.exe' -or $commandName -ieq 'git') {
            $reason = 'Git command could not be executed successfully.'
        } elseif (($commandName -like 'openclaw*') -and ($argumentText -match 'gateway\s+install')) {
            $reason = 'OpenClaw gateway daemon setup did not complete successfully.'
        } else {
            $reason = 'External command returned an error. See installer log for details.'
        }
    }

    return ('Command failed (exit {0}): {1}' -f $ExitCode, $reason)
}

# ══════════════════════════════════════════════════════════════════════════
#  External Process Execution
# ══════════════════════════════════════════════════════════════════════════

function Invoke-ExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = (Get-Location).Path,
        [hashtable]$EnvironmentVariables,
        [string[]]$SensitiveValues = @(),
        [switch]$RedactStdOut,
        [switch]$AllowNonZeroExit
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath

    $quotedArguments = foreach ($argument in $Arguments) {
        if ($null -eq $argument) { '""'; continue }
        $text = [string]$argument
        if ($text -notmatch '[\s"]') { $text; continue }

        $escaped = $text -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        '"' + $escaped + '"'
    }

    $psi.Arguments             = ($quotedArguments -join ' ')
    $psi.WorkingDirectory      = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    try {
        $psi.StandardOutputEncoding = $script:Utf8Enc
        $psi.StandardErrorEncoding  = $script:Utf8Enc
    } catch { }

    if ($EnvironmentVariables) {
        foreach ($pair in $EnvironmentVariables.GetEnumerator()) {
            $psi.Environment[$pair.Key] = [string]$pair.Value
        }
    }

    $displayCmd = Mask-SensitiveText -Text ("Running: {0} {1}" -f $FilePath, ($Arguments -join ' ')) -SensitiveValues $SensitiveValues
    Write-Log -Message $displayCmd -Data @{ command = $FilePath; arguments = $Arguments; workingDirectory = $WorkingDirectory }
    $script:LastExternalCommandInfo = [ordered]@{
        filePath = $FilePath
        arguments = @($Arguments)
        exitCode = $null
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdOut = $process.StandardOutput.ReadToEnd()
    $stdErr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $script:LastExternalCommandInfo.exitCode = $process.ExitCode

    if ($stdOut) {
        $displayOut = if ($RedactStdOut) { '__REDACTED__' } else { Mask-SensitiveText -Text $stdOut.TrimEnd() -SensitiveValues $SensitiveValues }
        foreach ($line in ($displayOut -split "`r?`n")) {
            if ($line) { Write-Log -Message $line -Data @{ stream = 'stdout' } }
        }
    }

    if ($stdErr) {
        $displayErr = Mask-SensitiveText -Text $stdErr.TrimEnd() -SensitiveValues $SensitiveValues
        $loggedUnreadableStdErr = $false
        foreach ($line in ($displayErr -split "`r?`n")) {
            if (-not $line) {
                continue
            }

            if (Test-TextLooksCorrupted -Text $line) {
                if (-not $loggedUnreadableStdErr) {
                    Write-Log -Message 'A subprocess returned unreadable error text. The installer will use a stable failure summary and preserve the log path.' -Level 'WARN' -Data @{ stream = 'stderr'; readable = $false }
                    $loggedUnreadableStdErr = $true
                }
                continue
            }

            Write-Log -Message $line -Level 'WARN' -Data @{ stream = 'stderr'; readable = $true }
        }
    }

    Write-Log -Message ("Command exited with code {0}" -f $process.ExitCode) -Data @{ command = $FilePath; exitCode = $process.ExitCode }

    if (-not $AllowNonZeroExit -and $process.ExitCode -ne 0) {
        $maskedFailure = Mask-SensitiveText -Text (
            Get-ExternalCommandFailureSummary -FilePath $FilePath -Arguments $Arguments -ExitCode $process.ExitCode -StdErr $stdErr -StdOut $stdOut
        ) -SensitiveValues $SensitiveValues
        throw $maskedFailure
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdOut
        StdErr   = $stdErr
    }
}

function Invoke-OpenClaw {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string[]]$SensitiveValues = @(),
        [switch]$RedactStdOut,
        [switch]$AllowNonZeroExit
    )

    $commandPath = Get-OpenClawCommandPath
    if (-not $commandPath) {
        throw (New-InstallerException -Code 'E3002' -Message 'OpenClaw CLI was not found on PATH.')
    }

    return Invoke-ExternalCommand -FilePath $commandPath -Arguments $Arguments `
        -SensitiveValues $SensitiveValues -RedactStdOut:$RedactStdOut -AllowNonZeroExit:$AllowNonZeroExit
}

# ══════════════════════════════════════════════════════════════════════════
#  Exports
# ══════════════════════════════════════════════════════════════════════════

Export-ModuleMember -Function `
    Test-ForcedMissingDependency, `
    New-InstallerException, Get-InstallerErrorCode, Get-ErrorCodeDescription, Get-AllErrorCodes, `
    Initialize-InstallerSession, Set-InstallerStep, Write-Log, Write-Stage, `
    Assert-Administrator, `
    Refresh-ProcessPath, `
    Read-JsonFile, Save-JsonFile, `
    New-InstallState, Read-InstallState, Save-InstallState, Update-InstallStateStep, `
    Get-NodeVersionInfo, Get-CommandPath, Test-CommandExecutable, `
    Get-OpenClawCommandPath, Get-NpmCommandPath, Get-GitCommandPath, `
    Get-EdgePath, Get-WebView2RuntimeVersion, Test-WebView2RuntimeInstalled, `
    Get-DesktopShortcutPath, Get-StartMenuShortcutPath, `
    New-RandomBase64Token, `
    Protect-DiagnosticText, Protect-DiagnosticObject, Get-LastExternalCommandInfo, New-DiagnosticsSummary, `
    Invoke-Retry, Test-HttpEndpoint, Wait-Until, Test-TextLooksCorrupted, Get-ExternalCommandFailureSummary, `
    Invoke-ExternalCommand, Invoke-OpenClaw
