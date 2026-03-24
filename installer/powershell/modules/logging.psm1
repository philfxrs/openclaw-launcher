# logging.psm1 — OpenClaw Installer Logging Module
# Provides UTF-8 file I/O, structured JSONL logging, console output, and stage reporting.
# Compatible with PowerShell 5.1+.

Set-StrictMode -Version Latest

$script:Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($false)
$script:InstallerSession = $null

# ── Console Encoding ─────────────────────────────────────────────────────

function Initialize-ConsoleEncoding {
    try {
        [Console]::InputEncoding  = $script:Utf8NoBomEncoding
        [Console]::OutputEncoding = $script:Utf8NoBomEncoding
    } catch { }

    try {
        $global:OutputEncoding = $script:Utf8NoBomEncoding
    } catch { }
}

# ── UTF-8 File Helpers ───────────────────────────────────────────────────

function Get-Utf8NoBomEncoding {
    return $script:Utf8NoBomEncoding
}

function Set-Utf8FileContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowEmptyString()]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBomEncoding)
}

function Add-Utf8FileContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowEmptyString()]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    [System.IO.File]::AppendAllText($Path, $Content, $script:Utf8NoBomEncoding)
}

# ── Session Management ───────────────────────────────────────────────────

function Initialize-InstallerSession {
    [CmdletBinding()]
    param(
        [string]$ProductName = 'OpenClawInstaller',
        [string]$LogRoot = (Join-Path $env:ProgramData 'OpenClawInstaller\Logs')
    )

    Initialize-ConsoleEncoding
    New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $session = [ordered]@{
        productName       = $ProductName
        logRoot           = $LogRoot
        textLogPath       = Join-Path $LogRoot ("install-$timestamp.log")
        jsonLogPath       = Join-Path $LogRoot ("install-$timestamp.jsonl")
        transcriptPath    = Join-Path $LogRoot ("install-$timestamp.transcript.log")
        currentStepId     = 'init'
        currentStepNumber = 0
        currentStepName   = 'Initializing'
    }

    $script:InstallerSession = $session
    Write-Log -Message ("Installer session started. Text log: {0}; JSONL log: {1}" -f $session.textLogPath, $session.jsonLogPath)
    return [pscustomobject]$session
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

    if (-not $script:InstallerSession) { return }

    $script:InstallerSession.currentStepId     = $StepId
    $script:InstallerSession.currentStepName   = $StepName
    $script:InstallerSession.currentStepNumber = $StepNumber
}

function Get-InstallerSessionInfo {
    return $script:InstallerSession
}

# ── Structured JSONL Logging ─────────────────────────────────────────────

function Write-StructuredLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $true)]
        [string]$Level,
        [string]$Code,
        [hashtable]$Data
    )

    if (-not $script:InstallerSession) { return }

    $payload = [ordered]@{
        timestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        level        = $Level
        code         = $Code
        stepId       = $script:InstallerSession.currentStepId
        stepNumber   = $script:InstallerSession.currentStepNumber
        stepName     = $script:InstallerSession.currentStepName
        message      = $Message
        data         = $Data
    }

    $json = ($payload | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
    Add-Utf8FileContent -Path $script:InstallerSession.jsonLogPath -Content $json
}

# ── Write-Log ────────────────────────────────────────────────────────────

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

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = if ($Code) { "[$timestamp] [$Level] [$Code]" } else { "[$timestamp] [$Level]" }

    if ($script:InstallerSession -and $script:InstallerSession.currentStepNumber -gt 0) {
        $prefix += " [STEP $($script:InstallerSession.currentStepNumber):$($script:InstallerSession.currentStepId)]"
    } elseif ($script:InstallerSession -and $script:InstallerSession.currentStepId) {
        $prefix += " [$($script:InstallerSession.currentStepId)]"
    }

    $line = "$prefix $Message"

    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line -ForegroundColor Gray }
    }

    if ($script:InstallerSession) {
        Add-Utf8FileContent -Path $script:InstallerSession.textLogPath -Content ($line + [Environment]::NewLine)
        Write-StructuredLog -Message $Message -Level $Level -Code $Code -Data $Data
    }
}

# ── Stage Reporting (Inno Setup protocol) ────────────────────────────────

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

    Write-Host ("@@OPENCLAW_STAGE|{0}|{1}|{2}" -f $StageId, $Percent, $Message)
    Write-Log -Message $Message
}

# ── Sensitive Text Masking ───────────────────────────────────────────────

function Mask-SensitiveText {
    [CmdletBinding()]
    param(
        [string]$Text,
        [string[]]$SensitiveValues = @()
    )

    if ($null -eq $Text) { return $Text }

    $masked = [string]$Text
    foreach ($sv in @($SensitiveValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $masked = [Regex]::Replace($masked, [Regex]::Escape($sv), '__REDACTED__')
    }

    return $masked
}

# Auto-initialize console encoding on module load
Initialize-ConsoleEncoding

Export-ModuleMember -Function Initialize-ConsoleEncoding, Get-Utf8NoBomEncoding, `
    Set-Utf8FileContent, Add-Utf8FileContent, `
    Initialize-InstallerSession, Set-InstallerStep, Get-InstallerSessionInfo, `
    Write-StructuredLog, Write-Log, Write-Stage, `
    Mask-SensitiveText
