[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepositoryRoot,
  [switch]$RebuildInstaller,
  [switch]$AutomatedSmoke,
  [switch]$WaitForCompletion,
  [int]$TimeoutMinutes = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$installerPath = Join-Path $RepositoryRoot 'artifacts\installer\OpenClawSetup.exe'
if ($RebuildInstaller -or -not (Test-Path $installerPath)) {
    & (Join-Path $RepositoryRoot 'build\Test-LocalInstaller.ps1') -RepositoryRoot $RepositoryRoot
}

if (-not (Test-Path $installerPath)) {
    throw 'OpenClawSetup.exe was not found. Run build\Test-LocalInstaller.ps1 first.'
}

$sandboxExe = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
if (-not (Test-Path $sandboxExe)) {
    throw 'Windows Sandbox is not available on this machine.'
}

$shareRoot = Join-Path $RepositoryRoot 'artifacts\test\sandbox-share'
New-Item -ItemType Directory -Force -Path $shareRoot | Out-Null

$copiedInstallerPath = Join-Path $shareRoot 'OpenClawSetup.exe'
Copy-Item -Path $installerPath -Destination $copiedInstallerPath -Force

$sandboxBootstrapPath = Join-Path $shareRoot 'SandboxBootstrap.ps1'

if ($AutomatedSmoke) {
  $smokeScriptSource = Join-Path $RepositoryRoot 'validation\Test-InstalledConfiguratorSmoke.ps1'
  $smokeScriptDestination = Join-Path $shareRoot 'Test-InstalledConfiguratorSmoke.ps1'
  Copy-Item -Path $smokeScriptSource -Destination $smokeScriptDestination -Force

  $sandboxBootstrapContent = @'
$ErrorActionPreference = 'Stop'
$share = 'C:\Users\WDAGUtilityAccount\Desktop\OpenClawTest'
$installer = Join-Path $share 'OpenClawSetup.exe'
$smokeScript = Join-Path $share 'Test-InstalledConfiguratorSmoke.ps1'
$reportPath = Join-Path $share 'sandbox-clean-install-report.json'
$installerLogPath = Join-Path $share 'sandbox-installer.log'

try {
  $installArgs = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="' + $installerLogPath + '"'
  $installProcess = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
  if ($installProcess.ExitCode -ne 0) {
    [pscustomobject]@{
      overall = 'FAIL'
      phase = 'install'
      exitCode = $installProcess.ExitCode
      installerLogPath = $installerLogPath
    } | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding UTF8
    exit $installProcess.ExitCode
  }

  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $smokeScript -ConfiguratorPath 'C:\Program Files\OpenClaw\bin\OpenClawConfigurator.exe' -LauncherPath 'C:\Program Files\OpenClaw\bin\OpenClawLauncher.exe' -ReportPath $reportPath
}
catch {
  [pscustomobject]@{
    overall = 'FAIL'
    phase = 'bootstrap'
    error = $_.Exception.Message
    installerLogPath = $installerLogPath
  } | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding UTF8
  exit 1
}
'@
}
else {
  $planSource = Join-Path $RepositoryRoot 'installer\docs\local-test-plan.md'
  $recordSource = Join-Path $RepositoryRoot 'installer\docs\local-test-record-template.md'
  Copy-Item -Path $planSource -Destination (Join-Path $shareRoot 'local-test-plan.md') -Force
  Copy-Item -Path $recordSource -Destination (Join-Path $shareRoot 'local-test-record-template.md') -Force

  $sandboxBootstrapContent = @'
$share = 'C:\Users\WDAGUtilityAccount\Desktop\OpenClawTest'
$installer = Join-Path $share 'OpenClawSetup.exe'
$plan = Join-Path $share 'local-test-plan.md'
$record = Join-Path $share 'local-test-record-template.md'

Start-Process notepad.exe -ArgumentList $record
Start-Process notepad.exe -ArgumentList $plan
Start-Process explorer.exe -ArgumentList $share
Start-Process -FilePath $installer
'@
}

Set-Content -Path $sandboxBootstrapPath -Value $sandboxBootstrapContent -Encoding UTF8

$wsbPath = Join-Path $shareRoot 'OpenClawInstallerTest.wsb'
$mappedHostPath = $shareRoot.Replace('&', '&amp;')
$wsbContent = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$mappedHostPath</HostFolder>
      <SandboxFolder>C:\Users\WDAGUtilityAccount\Desktop\OpenClawTest</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -ExecutionPolicy Bypass -File C:\Users\WDAGUtilityAccount\Desktop\OpenClawTest\SandboxBootstrap.ps1</Command>
  </LogonCommand>
</Configuration>
"@
Set-Content -Path $wsbPath -Value $wsbContent -Encoding UTF8

Write-Host ('Prepared Windows Sandbox config: ' + $wsbPath)
if ($PSCmdlet.ShouldProcess($wsbPath, 'Launch Windows Sandbox for installer testing')) {
  Start-Process -FilePath $sandboxExe -ArgumentList ('"' + $wsbPath + '"')

  if ($AutomatedSmoke -and $WaitForCompletion) {
    $reportPath = Join-Path $shareRoot 'sandbox-clean-install-report.json'
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
      if (Test-Path $reportPath) {
        Write-Host ('Sandbox smoke report: ' + $reportPath)
        Get-Content -Path $reportPath -Raw | Write-Output
        return
      }

      Start-Sleep -Seconds 10
    }

    throw ('Timed out waiting for sandbox smoke report: ' + $reportPath)
  }
}
