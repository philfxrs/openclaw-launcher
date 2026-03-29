[CmdletBinding()]
param(
    [string]$StatePath,
    [string]$ShortcutName = 'OpenClaw',
    [switch]$RemoveManagedNode,
    [switch]$RemoveManagedGit
)

. (Join-Path $PSScriptRoot 'Installer.Common.ps1')

$state = $null
if ($StatePath -and (Test-Path $StatePath)) {
    $state = Read-JsonFile -Path $StatePath
}

foreach ($shortcutSpec in @(
    @{ path = (Get-DesktopShortcutPath -ShortcutName $ShortcutName); label = 'desktop shortcut' },
    @{ path = (Get-StartMenuShortcutPath -ShortcutName $ShortcutName); label = 'Start menu shortcut' },
    @{ path = (Get-DesktopShortcutPath -ShortcutName "配置 $ShortcutName"); label = 'configurator desktop shortcut' },
    @{ path = (Get-StartMenuShortcutPath -ShortcutName "配置 $ShortcutName"); label = 'configurator Start menu shortcut' }
)) {
    $shortcutPath = $shortcutSpec.path
    if (Test-Path $shortcutPath) {
        Remove-Item -Force $shortcutPath
        Write-Log -Message ("Removed {0}." -f $shortcutSpec.label)
    }
}

$gatewayTaskName = 'OpenClaw Gateway'
try {
    $queryProcess = Start-Process -FilePath 'schtasks.exe' -ArgumentList '/Query', '/TN', $gatewayTaskName -WindowStyle Hidden -Wait -PassThru
    $taskExists = ($queryProcess.ExitCode -eq 0)

    if ($taskExists) {
        Start-Process -FilePath 'schtasks.exe' -ArgumentList '/Delete', '/TN', $gatewayTaskName, '/F' -WindowStyle Hidden -Wait | Out-Null
        Write-Log -Message "Removed scheduled task: $gatewayTaskName"
    }
} catch {
    Write-Log -Message "Scheduled task cleanup skipped: $gatewayTaskName" -Level 'WARN'
}

$openclawHome = Join-Path $env:USERPROFILE '.openclaw'
$gatewayScript = Join-Path $openclawHome 'gateway.cmd'

$openclawPath = Get-OpenClawCommandPath
if ($openclawPath) {
    try {
        Invoke-OpenClaw -Arguments @('uninstall', '--all', '--yes', '--non-interactive') -AllowNonZeroExit | Out-Null
    } catch {
        Write-Log -Message "OpenClaw uninstall cleanup failed: $($_.Exception.Message)" -Level 'WARN'
    }

    try {
        $npm = Get-NpmCommandPath
        Invoke-ExternalCommand -FilePath $npm -Arguments @('uninstall', '-g', 'openclaw') -AllowNonZeroExit | Out-Null
    } catch {
        Write-Log -Message "npm cleanup failed: $($_.Exception.Message)" -Level 'WARN'
    }
}

if (Test-Path $gatewayScript) {
    try {
        Remove-Item -Force $gatewayScript
        Write-Log -Message "Removed gateway script: $gatewayScript"
    } catch {
        Write-Log -Message "Gateway script cleanup skipped: $gatewayScript" -Level 'WARN'
    }
}

if (Test-Path $openclawHome) {
    # Preserve user config backups created by the configurator
    $configBackupsDir = Join-Path $openclawHome 'config-backups'
    $hasBackups = Test-Path $configBackupsDir

    try {
        Get-ChildItem -Path $openclawHome -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.FullName.StartsWith($configBackupsDir, [System.StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object {
                try { Remove-Item -Force -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch {}
            }

        if (-not $hasBackups) {
            Remove-Item -Recurse -Force $openclawHome -ErrorAction SilentlyContinue
        }

        Write-Log -Message "Removed OpenClaw home: $openclawHome (config-backups preserved: $hasBackups)"
    } catch {
        Write-Log -Message "OpenClaw home cleanup skipped: $openclawHome" -Level 'WARN'
    }
}

$launcherDataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenClaw'
if (Test-Path $launcherDataRoot) {
    Get-Process -Name 'OpenClawLauncher' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log -Message "Stopping OpenClaw launcher process $($_.Id)"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }

    Get-Process -Name 'OpenClawConfigurator' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Log -Message "Stopping OpenClaw configurator process $($_.Id)"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }

    try {
        $launcherProcesses = Get-CimInstance Win32_Process -Filter "Name = 'msedgewebview2.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*OpenClaw\WebView2Profile*' }

        foreach ($process in $launcherProcesses) {
            Write-Log -Message "Stopping OpenClaw launcher browser process $($process.ProcessId)"
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }

        if ($launcherProcesses) {
            Start-Sleep -Seconds 2
        }
    } catch {
        Write-Log -Message 'Could not enumerate launcher browser processes before cleanup.' -Level 'WARN'
    }

    try {
        Remove-Item -Recurse -Force $launcherDataRoot
        Write-Log -Message "Removed launcher data: $launcherDataRoot"
    } catch {
        Write-Log -Message "Launcher data cleanup skipped because files are still in use: $launcherDataRoot" -Level 'WARN'
    }
}

if ($RemoveManagedNode -and $state -and $state.nodeInstalledByBootstrap -and $state.nodeProductCode) {
    try {
        Invoke-ExternalCommand -FilePath 'msiexec.exe' -Arguments @(
            '/x',
            $state.nodeProductCode,
            '/qn',
            '/norestart'
        ) -AllowNonZeroExit | Out-Null
    } catch {
        Write-Log -Message "Managed Node.js rollback failed: $($_.Exception.Message)" -Level 'WARN'
    }
}

if ($RemoveManagedGit -and $state -and $state.gitInstalledByBootstrap) {
    $gitUninstallerPath = $state.gitUninstallerPath
    if ([string]::IsNullOrWhiteSpace($gitUninstallerPath) -or -not (Test-Path $gitUninstallerPath)) {
        $gitUninstallerPath = 'C:\Program Files\Git\unins000.exe'
    }

    if (Test-Path $gitUninstallerPath) {
        try {
            Invoke-ExternalCommand -FilePath $gitUninstallerPath -Arguments @(
                '/VERYSILENT',
                '/SUPPRESSMSGBOXES',
                '/NORESTART'
            ) -AllowNonZeroExit | Out-Null
            Write-Log -Message 'Removed managed Git for Windows installation.'
        } catch {
            Write-Log -Message "Managed Git rollback failed: $($_.Exception.Message)" -Level 'WARN'
        }
    }
}

$portableGitRoot = Join-Path $env:ProgramData 'OpenClawInstaller\Tools\MinGit'
if (Test-Path $portableGitRoot) {
    try {
        Remove-Item -Path $portableGitRoot -Recurse -Force
        Write-Log -Message "Removed private MinGit cache: $portableGitRoot"
    } catch {
        Write-Log -Message "Private MinGit cleanup skipped: $portableGitRoot" -Level 'WARN'
    }
}
