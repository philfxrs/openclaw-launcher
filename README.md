# OpenClaw Windows Installer

This repository contains a real Windows installer pipeline for OpenClaw aimed at end users, not developers.

The deliverable is a single `OpenClawSetup.exe` bootstrapper built with Inno Setup. That installer:

- checks and silently installs missing runtime dependencies
- invokes the official OpenClaw Windows installer flow
- performs non-interactive first-run onboarding for a local gateway
- validates that OpenClaw can actually launch and show a desktop window
- creates desktop and Start menu shortcuts for repeat launches

## Architecture

- `installer/OpenClawBootstrap.iss`
  Inno Setup bootstrapper that extracts payloads, elevates once, and runs the real install transaction.
- `bootstrap/Install-OpenClaw.ps1`
  End-to-end install orchestrator with rollback.
- `bootstrap/Uninstall-OpenClaw.ps1`
  Cleanup entry run by the Inno uninstaller.
- `scripts/*.ps1`
  Shared install, dependency, onboarding, validation, shortcut, and rollback logic.
- `launcher/OpenClawLauncher.cs`
  Native Windows launcher entrypoint used by the desktop shortcut. It starts the OpenClaw gateway and opens the dashboard in an app-style Edge window.
- `build/*.ps1`
  Build pipeline to sync upstream assets, compile the launcher, and compile the installer.

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

4. If you need an unsigned local debug build, skip the signing step explicitly:

```powershell
powershell -ExecutionPolicy Bypass -File .\build\Build-Installer.ps1 -SkipSigning
```

5. Build the macOS installer package (`.pkg`) on a macOS machine:

```bash
chmod +x ./build/Build-macOS-Installer.sh
./build/Build-macOS-Installer.sh
```

The macOS installer is designed for fresh systems as well. During postinstall it will attempt to provision missing prerequisites (Homebrew, Node.js 22+, and Git) before running the OpenClaw install/onboarding flow.

For trusted distribution on newer macOS versions, the release workflow also supports signing and notarization when credentials are configured:

- Repository variables:
  - OPENCLAW_MACOS_APP_SIGN_IDENTITY
  - OPENCLAW_MACOS_PKG_SIGN_IDENTITY
- Repository secrets:
  - MACOS_CERT_P12_BASE64
  - MACOS_CERT_PASSWORD
  - APPLE_ID
  - APPLE_TEAM_ID
  - APPLE_APP_SPECIFIC_PASSWORD

If these values are not set, the workflow still builds a macOS package but skips signing/notarization.

## Automated release

Pushing a Git tag that starts with `v` will trigger GitHub Actions to:

- install Inno Setup on a Windows runner
- build `OpenClawSetup.exe` on Windows
- build `OpenClawSetup-macOS.pkg` on macOS
- create/update a GitHub Release with both installers attached
- publish SHA256 and file size for both files in release notes

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
2. `Install-OpenClaw.ps1` checks prerequisites.
3. If Node.js is missing or too old, the installer downloads and silently installs the pinned Node LTS MSI from the generated dependency manifest.
4. The bootstrap executes the vendored official `https://openclaw.ai/install.ps1` with `-InstallMethod npm -NoOnboard`.
5. The bootstrap runs official non-interactive onboarding to provision a local gateway token and install the OpenClaw daemon.
6. The bootstrap validates CLI health, gateway reachability, launcher startup, and shortcut creation.
7. The launcher opens `http://127.0.0.1:18789/?token=...` in an app-style Edge window.

## Notes

- The build intentionally vendors the upstream OpenClaw installer script at build time so the distributed EXE is pinned to a known upstream snapshot.
- The installer treats success as "OpenClaw is usable from a desktop shortcut", not merely "a script exited with 0".
- The installer adds an `Uninstall OpenClaw` Start menu entry and the normal Windows Apps & Features uninstall entry.
- The uninstaller removes OpenClaw, daemon state, shortcuts, and launcher profile data. It preserves Node.js by default because Node may become a shared machine runtime after installation.
