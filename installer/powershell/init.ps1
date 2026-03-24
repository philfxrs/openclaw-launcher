# init.ps1 — Module Loader for OpenClaw Installer
# Dot-source this file from bootstrap.ps1, step scripts, or validation scripts.
# $PSScriptRoot here resolves to installer/powershell/ (at build time)
# or {app}\powershell\ (at runtime inside the installed directory).

$script:InstallerPSRoot         = $PSScriptRoot
$script:InstallerModulesRoot    = Join-Path $PSScriptRoot 'modules'
$script:InstallerStepsRoot      = Join-Path $PSScriptRoot 'steps'
$script:InstallerRoot           = Split-Path -Parent $PSScriptRoot
$script:InstallerValidationRoot = Join-Path $script:InstallerRoot 'validation'
$script:InstallerResourcesRoot  = Join-Path $script:InstallerRoot 'resources'

Import-Module (Join-Path $script:InstallerModulesRoot 'errors.psm1')  -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:InstallerModulesRoot 'logging.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:InstallerModulesRoot 'common.psm1')  -Force -DisableNameChecking -Global
