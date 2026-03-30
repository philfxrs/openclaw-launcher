# OpenClaw Windows Installer

This repository contains a real Windows installer pipeline for OpenClaw aimed at end users, not developers.

The deliverable is a single `OpenClawSetup.exe` bootstrapper built with Inno Setup. That installer:

- checks and silently installs missing runtime dependencies
- installs or validates the Evergreen WebView2 Runtime required by the desktop shell
- invokes the official OpenClaw Windows installer flow
- performs non-interactive first-run onboarding for a local gateway
- validates that OpenClaw can actually launch and show a desktop window
- creates desktop and Start menu shortcuts for repeat launches

## Architecture

- `installer/inno/OpenClawSetup.iss`
  Inno Setup Unicode bootstrapper. Handles UI, privilege elevation, file extraction, bootstrap invocation, and uninstall entry.
- `installer/powershell/bootstrap.ps1`
  Main 18-stage installation orchestrator.
- `installer/powershell/uninstall.ps1`
  Cleanup entry run by the Inno uninstaller.
- `installer/powershell/modules/*.psm1`
  Shared logging, error-code, state, dependency, and process helpers.
- `installer/powershell/steps/*.ps1`
  Concrete install steps: dependency detection, dependency install, OpenClaw install, shortcut creation, uninstall cleanup.
- `installer/validation/*.ps1`
  Explicit prerequisite, installed-state, and first-launch validation.
- `installer/docs/local-test-plan.md`
  Required local distribution-level validation plan before any GitHub release.
- `installer/docs/release-checklist.md`
  Release gate checklist that can only be used after local tests pass.
- `launcher/OpenClawLauncher.cs`
  Native Windows launcher entrypoint used by the desktop shortcut. It starts the OpenClaw gateway and opens the dashboard in an app-style Edge window.
- `build/*.ps1`
  Build pipeline to sync upstream assets, compile the launcher, execute local installer checks, and compile the installer.
- `tools/installer-diagnostics-server/*`
  Minimal Node.js service that receives the redacted installer diagnostics summary, creates a GitHub private-repo issue, and returns a `reportId`.
- `tools/installer-diagnostics-worker/*`
  Minimal Cloudflare Worker HTTPS relay that receives the redacted installer diagnostics summary, creates a GitHub private-repo issue, and returns a `reportId`.

## Build

1. Sync upstream assets and dependency manifest:

```powershell
powershell -ExecutionPolicy Bypass -File .\build\Sync-UpstreamAssets.ps1
```

2. Build the launcher:

```powershell
powershell -ExecutionPolicy Bypass -File .\build\Build-Launcher.ps1
```

3. Build the installer:

```powershell
powershell -ExecutionPolicy Bypass -File .\build\Build-Installer.ps1
```

If you want the installer to upload redacted failure summaries automatically, pass the diagnostics endpoint explicitly at build time:

```powershell
powershell -ExecutionPolicy Bypass -File .\build\Build-Installer.ps1 `
  -DiagnosticsUploadUri 'https://your-host.example.com/installer-diagnostics'
```

4. If you need an unsigned local debug build, skip the signing step explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\build\Build-Installer.ps1 -SkipSigning
```

5. Run the required pre-release local verification:

```powershell
powershell -ExecutionPolicy Bypass -File .\build\Test-LocalInstaller.ps1
```

5. Build the macOS installer package (`.pkg`) on a macOS machine:

```bash
chmod +x ./build/Build-macOS-Installer.sh
./build/Build-macOS-Installer.sh
```

The macOS installer is designed for fresh systems as well. During postinstall it will attempt to provision missing prerequisites (Homebrew, Node.js 22+, and Git) before running the OpenClaw install/onboarding flow.

For trusted distribution on newer macOS versions, the release workflow now requires signing and notarization for macOS artifacts. A tag release will fail if these values are missing:

- Repository variables:
  - OPENCLAW_MACOS_APP_SIGN_IDENTITY
  - OPENCLAW_MACOS_PKG_SIGN_IDENTITY
- Repository secrets:
  - MACOS_CERT_P12_BASE64
  - MACOS_CERT_PASSWORD
  - APPLE_ID
  - APPLE_TEAM_ID
  - APPLE_APP_SPECIFIC_PASSWORD

Local manual builds can still run unsigned for testing, but release tags must pass signing + notarization.

To configure these values in GitHub in one step after you have the real Apple assets, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Configure-GitHub-macOS-Signing.ps1 `
  -Repository philfxrs/openclaw-launcher `
  -P12Path .\AppleDeveloperCertificates.p12 `
  -P12Password 'YOUR_P12_PASSWORD' `
  -AppleId 'your-apple-id@example.com' `
  -AppleTeamId 'ABCDE12345' `
  -AppleAppSpecificPassword 'xxxx-xxxx-xxxx-xxxx' `
  -MacOSAppSignIdentity 'Developer ID Application: Your Name (ABCDE12345)' `
  -MacOSPkgSignIdentity 'Developer ID Installer: Your Name (ABCDE12345)'
```

## Local Test Gate

GitHub release preparation is explicitly gated behind local verification.

You must not publish `OpenClawSetup.exe` until all of the following are true:

- local sync/build checks pass
- at least one clean Windows VM or Sandbox install passes
- dependency auto-install passes
- automatic launch passes
- shortcut validation passes
- logs and error codes are usable
- Chinese UI and logs show without encoding corruption

See `installer/docs/local-test-plan.md` for the full matrix and `installer/docs/release-checklist.md` for the release gate.

## Automated release

Pushing a Git tag that starts with `v` will trigger GitHub Actions to:

- install Inno Setup on a Windows runner
- build `OpenClawSetup.exe` on Windows
- build `OpenClawSetup-macOS.pkg` on macOS
- create/update a GitHub Release with both installers attached
- publish SHA256 and file size for both files in release notes

This step is only allowed after the local test gate has passed.

Example:

```powershell
git tag v0.1.1
git push origin v0.1.1
```

## Signing

- The build now signs `OpenClawLauncher.exe` and `OpenClawSetup.exe` by default.
- Preferred release path: set `OPENCLAW_SIGN_PFX_PATH` and `OPENCLAW_SIGN_PFX_PASSWORD` to a real OV/EV code-signing certificate.
- Alternate path: set `OPENCLAW_SIGN_CERT_THUMBPRINT` to a code-signing certificate already installed in `Cert:\CurrentUser\My` or `Cert:\LocalMachine\My`.
- Optional: set `OPENCLAW_SIGN_TIMESTAMP_URL` to override the default timestamp service.
- If no usable certificate is present, the build fails fast so an unsigned installer is not shipped by mistake.

## Runtime flow

1. Inno Setup elevates and extracts the payload.
2. `bootstrap.ps1` checks administrator privileges and initializes UTF-8 logs.
3. Dependency detection runs as separate stages for Node.js, npm, Git, and WebView2.
4. Missing dependencies are downloaded and silently installed.
5. Dependency validation runs before OpenClaw installation begins.
6. The bootstrap executes the vendored official `https://openclaw.ai/install.ps1`, unless a healthy existing install can be reused.
7. The bootstrap performs onboarding, validates the installed state, creates shortcuts, and verifies first launch.
8. On failure, logs and install state are preserved for retry or repair.

## Diagnostics service

The first-stage installer diagnostics loop is split into two pieces:

- the installer generates a redacted `diagnostics-summary.json` and uploads it
- the minimal service receives that summary, creates a private GitHub issue, and returns a `reportId`

For Cloudflare Worker deployment, use [tools/installer-diagnostics-worker/README.md](tools/installer-diagnostics-worker/README.md).

The existing local Node prototype remains available in [tools/installer-diagnostics-server/README.md](tools/installer-diagnostics-server/README.md) for local experiments only, but the deployable HTTPS relay for this stage is the Cloudflare Worker.

## Validation Release

The current Windows installer validation status is still: partial pass. The online upload and GitHub issue loop are confirmed, but real Windows GUI failure evidence is still being collected from small-scope tester installs.

For this limited validation release, use:

- [docs/windows-installer-validation-release.md](docs/windows-installer-validation-release.md)
- [docs/windows-installer-failure-feedback-template.md](docs/windows-installer-failure-feedback-template.md)
- [docs/windows-installer-test-invite.md](docs/windows-installer-test-invite.md)
- [docs/windows-installer-github-prerelease.md](docs/windows-installer-github-prerelease.md)

## Notes

- The build intentionally vendors the upstream OpenClaw installer script at build time so the distributed EXE is pinned to a known upstream snapshot.
- The installer treats success as "OpenClaw is usable from a desktop shortcut", not merely "a script exited with 0".
- The installer adds an `Uninstall OpenClaw` Start menu entry and the normal Windows Apps & Features uninstall entry.
- The uninstaller removes OpenClaw, daemon state, shortcuts, and launcher profile data. It preserves Node.js by default because Node may become a shared machine runtime after installation.
- When installation fails, the bootstrap keeps logs and the persisted state file so the next run can repair or continue instead of wiping successful dependency installs.
