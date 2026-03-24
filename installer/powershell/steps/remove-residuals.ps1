# remove-residuals.ps1 — Uninstall Cleanup
# Removes shortcuts, scheduled tasks, OpenClaw data, and optionally
# Node.js / Git that were installed by the bootstrap.

[CmdletBinding()]
param(
    [string]$StatePath,
    [string]$ShortcutName = 'OpenClaw',
    [switch]$RemoveManagedNode,
    [switch]$RemoveManagedGit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'init.ps1')

$state = $null
if ($StatePath -and (Test-Path $StatePath)) {
    $state = Read-JsonFile -Path $StatePath
}

# ── Shortcuts ────────────────────────────────────────────────────────────

foreach ($spec in @(
    @{ path = (Get-DesktopShortcutPath   -ShortcutName $ShortcutName); label = 'desktop shortcut' },
    @{ path = (Get-StartMenuShortcutPath -ShortcutName $ShortcutName); label = 'Start menu shortcut' }
)) {
    if (Test-Path $spec.path) {
        Remove-Item -Force $spec.path
        Write-Log -Message ("Removed {0}." -f $spec.label)
    }
}

# ── Scheduled Task ───────────────────────────────────────────────────────

$gatewayTaskName = 'OpenClaw Gateway'
try {
    $queryProc = Start-Process -FilePath 'schtasks.exe' -ArgumentList '/Query', '/TN', $gatewayTaskName -WindowStyle Hidden -Wait -PassThru
    if ($queryProc.ExitCode -eq 0) {
        Start-Process -FilePath 'schtasks.exe' -ArgumentList '/Delete', '/TN', $gatewayTaskName, '/F' -WindowStyle Hidden -Wait | Out-Null
        Write-Log -Message "Removed scheduled task: $gatewayTaskName"
    }
} catch {
    Write-Log -Message "Scheduled task cleanup skipped: $gatewayTaskName" -Level 'WARN'
}

# ── OpenClaw Data ────────────────────────────────────────────────────────

$openclawHome  = Join-Path $env:USERPROFILE '.openclaw'
$gatewayScript = Join-Path $openclawHome 'gateway.cmd'

$openclawPath = Get-OpenClawCommandPath
if ($openclawPath) {
    try {
        Invoke-OpenClaw -Arguments @('uninstall', '--all', '--yes', '--non-interactive') -AllowNonZeroExit | Out-Null
    } catch {
        Write-Log -Message "OpenClaw uninstall failed: $($_.Exception.Message)" -Level 'WARN'
    }

    try {
        $npm = Get-NpmCommandPath
        Invoke-ExternalCommand -FilePath $npm -Arguments @('uninstall', '-g', 'openclaw') -AllowNonZeroExit | Out-Null
    } catch {
        Write-Log -Message "npm global uninstall failed: $($_.Exception.Message)" -Level 'WARN'
    }
}

if (Test-Path $gatewayScript) {
    try { Remove-Item -Force $gatewayScript; Write-Log -Message "Removed $gatewayScript" }
    catch { Write-Log -Message "Could not remove gateway script" -Level 'WARN' }
}

if (Test-Path $openclawHome) {
    try { Remove-Item -Recurse -Force $openclawHome; Write-Log -Message "Removed $openclawHome" }
    catch { Write-Log -Message "Could not remove OpenClaw home" -Level 'WARN' }
}

# ── Launcher Processes & Data ────────────────────────────────────────────

$launcherDataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenClaw'

if (Test-Path $launcherDataRoot) {
    Get-Process -Name 'OpenClawLauncher' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log -Message "Stopping launcher process $($_.Id)"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }

    try {
        $webviewProcs = Get-CimInstance Win32_Process -Filter "Name = 'msedgewebview2.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*OpenClaw\WebView2Profile*' }

        foreach ($p in $webviewProcs) {
            Write-Log -Message "Stopping launcher webview process $($p.ProcessId)"
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }

        if ($webviewProcs) { Start-Sleep -Seconds 2 }
    } catch {
        Write-Log -Message 'Could not enumerate launcher browser processes.' -Level 'WARN'
    }

    try { Remove-Item -Recurse -Force $launcherDataRoot; Write-Log -Message "Removed $launcherDataRoot" }
    catch { Write-Log -Message "Could not fully remove launcher data" -Level 'WARN' }
}

# ── Managed Node.js ──────────────────────────────────────────────────────

if ($RemoveManagedNode -and $state -and $state.nodeInstalledByBootstrap -and $state.nodeProductCode) {
    Write-Log -Message "Uninstalling managed Node.js ($($state.nodeProductCode))"
    try {
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $state.nodeProductCode, '/qn', '/norestart') -Wait -PassThru
        Write-Log -Message "Node.js MSI removal exited with code $($proc.ExitCode)"
    } catch {
        Write-Log -Message "Node.js removal failed: $($_.Exception.Message)" -Level 'WARN'
    }
}

# ── Managed Git ──────────────────────────────────────────────────────────

if ($RemoveManagedGit -and $state -and $state.gitInstalledByBootstrap -and $state.gitUninstallerPath -and (Test-Path $state.gitUninstallerPath)) {
    Write-Log -Message "Uninstalling managed Git ($($state.gitUninstallerPath))"
    try {
        Start-Process -FilePath $state.gitUninstallerPath -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait | Out-Null
        Write-Log -Message 'Git removal completed.'
    } catch {
        Write-Log -Message "Git removal failed: $($_.Exception.Message)" -Level 'WARN'
    }
}

Write-Log -Message 'Uninstall cleanup finished.' -Level 'SUCCESS'
