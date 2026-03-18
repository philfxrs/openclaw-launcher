Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor Gray }
    }
}

function Mask-SensitiveText {
    param(
        [string]$Text,
        [string[]]$SensitiveValues = @()
    )

    if ($null -eq $Text) {
        return $Text
    }

    $masked = [string]$Text
    foreach ($sensitiveValue in @($SensitiveValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $escapedValue = [Regex]::Escape($sensitiveValue)
        $masked = [Regex]::Replace($masked, $escapedValue, '__OPENCLAW_REDACTED__')
    }

    return $masked
}

function Write-Stage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StageId,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateRange(0, 100)]
        [int]$Percent = 0
    )

    Write-Host ("@@OPENCLAW_STAGE|{0}|{1}|{2}" -f $StageId, $Percent, $Message)
    Write-Log -Message $Message
}

function Assert-Administrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator privileges are required to continue.'
    }
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $segments = @()
    foreach ($segment in @($machinePath, $userPath) -split ';') {
        if (-not [string]::IsNullOrWhiteSpace($segment) -and -not ($segments -contains $segment)) {
            $segments += $segment
        }
    }
    $env:Path = [string]::Join(';', $segments)
}

function Read-JsonFile {
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
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $InputObject | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

function New-InstallState {
    return [ordered]@{
        startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        nodeInstalledByBootstrap = $false
        nodeProductCode = $null
        gitInstalledByBootstrap = $false
        gitUninstallerPath = $null
        officialInstallComplete = $false
        onboardingComplete = $false
        launcherValidated = $false
        shortcuts = @()
        lastError = $null
    }
}

function Save-InstallState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Save-JsonFile -InputObject $State -Path $Path
}

function Get-NodeVersionInfo {
    try {
        $raw = (& node -v 2>$null)
        if (-not $raw) {
            return $null
        }

        $major = [int]($raw -replace '^v(\d+)\..*$', '$1')
        return [pscustomobject]@{
            raw = $raw.Trim()
            major = $major
        }
    } catch {
        return $null
    }
}

function Get-CommandPath {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Candidates
    )

    foreach ($candidate in $Candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($command -and $command.Source) {
            return $command.Source
        }
    }

    return $null
}

function Get-OpenClawCommandPath {
    $candidates = @(
        'openclaw.cmd',
        'openclaw.exe',
        'openclaw'
    )

    $resolved = Get-CommandPath -Candidates $candidates
    if ($resolved) {
        return $resolved
    }

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $fallback = Join-Path $env:APPDATA 'npm\openclaw.cmd'
        if (Test-Path $fallback) {
            return $fallback
        }
    }

    return $null
}

function Get-NpmCommandPath {
    $resolved = Get-CommandPath -Candidates @('npm.cmd', 'npm.exe', 'npm')
    if (-not $resolved) {
        throw 'npm was not found on PATH.'
    }

    return $resolved
}

function Get-GitCommandPath {
    $resolved = Get-CommandPath -Candidates @('git.exe', 'git')
    if ($resolved) {
        return $resolved
    }

    foreach ($candidate in @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe'
    )) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-EdgePath {
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
        } catch {
        }
    }

    foreach ($candidate in @(
        "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-DesktopShortcutPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutName
    )

    return (Join-Path ([Environment]::GetFolderPath('Desktop')) "$ShortcutName.lnk")
}

function Get-StartMenuShortcutPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutName
    )

    $programs = [Environment]::GetFolderPath('Programs')
    return (Join-Path $programs "$ShortcutName.lnk")
}

function New-RandomBase64Token {
    param(
        [int]$ByteCount = 32
    )

    $bytes = New-Object byte[] $ByteCount
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Invoke-Retry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return (& $Action)
        } catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }

            Write-Log -Message "$Description failed on attempt $attempt/$MaxAttempts. Retrying in $DelaySeconds second(s)." -Level 'WARN'
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Test-HttpEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [int]$TimeoutSeconds = 5
    )

    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $response = $request.GetResponse()
        if ($response) {
            $response.Close()
        }
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
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [int]$TimeoutSeconds = 60,
        [int]$PollSeconds = 2
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (& $Condition) {
            return
        }

        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    throw "Timed out waiting for $Description."
}

function Invoke-ExternalCommand {
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
        if ($null -eq $argument) {
            '""'
            continue
        }

        $text = [string]$argument
        if ($text -notmatch '[\s"]') {
            $text
            continue
        }

        $escaped = $text -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        '"' + $escaped + '"'
    }
    $psi.Arguments = ($quotedArguments -join ' ')
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    if ($EnvironmentVariables) {
        foreach ($pair in $EnvironmentVariables.GetEnumerator()) {
            $psi.Environment[$pair.Key] = [string]$pair.Value
        }
    }

    $displayCommand = Mask-SensitiveText -Text ("Running: {0} {1}" -f $FilePath, ($Arguments -join ' ')) -SensitiveValues $SensitiveValues
    Write-Log -Message $displayCommand
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $stdOut = $process.StandardOutput.ReadToEnd()
    $stdErr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($stdOut) {
        $displayStdOut = if ($RedactStdOut) { '__OPENCLAW_REDACTED__' } else { Mask-SensitiveText -Text $stdOut.TrimEnd() -SensitiveValues $SensitiveValues }
        foreach ($line in ($displayStdOut -split "`r?`n")) {
            if ($line) {
                Write-Log -Message $line
            }
        }
    }

    if ($stdErr) {
        $displayStdErr = Mask-SensitiveText -Text $stdErr.TrimEnd() -SensitiveValues $SensitiveValues
        foreach ($line in ($displayStdErr -split "`r?`n")) {
            if ($line) {
                Write-Log -Message $line -Level 'WARN'
            }
        }
    }

    if (-not $AllowNonZeroExit -and $process.ExitCode -ne 0) {
        $maskedFailure = Mask-SensitiveText -Text ("Command failed with exit code {0}: {1} {2}" -f $process.ExitCode, $FilePath, ($Arguments -join ' ')) -SensitiveValues $SensitiveValues
        throw $maskedFailure
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdOut
        StdErr = $stdErr
    }
}

function Invoke-OpenClaw {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string[]]$SensitiveValues = @(),
        [switch]$RedactStdOut,
        [switch]$AllowNonZeroExit
    )

    $commandPath = Get-OpenClawCommandPath
    if (-not $commandPath) {
        throw 'OpenClaw CLI was not found on PATH.'
    }

    return Invoke-ExternalCommand -FilePath $commandPath -Arguments $Arguments -SensitiveValues $SensitiveValues -RedactStdOut:$RedactStdOut -AllowNonZeroExit:$AllowNonZeroExit
}
