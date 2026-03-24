# OpenClaw Windows Bootstrap Installer

This project uses Inno Setup as the single EXE entrypoint and PowerShell as the elevated bootstrap orchestration layer.

Lifecycle:

1. Inno Setup unpacks payloads and launches the bootstrapper with admin rights.
2. The bootstrapper initializes UTF-8 logging, persistent state, and step tracking.
3. Missing dependencies are detected, downloaded, installed, and re-validated.
4. The pinned official OpenClaw installer is executed.
5. First-run onboarding, shortcut creation, and launch validation complete the install.
6. On failure, state and logs are preserved so the next run can safely resume or repair.

Source folders:

- installer: Inno Setup entrypoint and UI glue.
- bootstrap: elevated end-to-end installer and uninstaller transactions.
- scripts: reusable dependency, onboarding, and diagnostics helpers.
- validation: explicit install verification scripts.
- shortcuts: shortcut creation wrappers used by the bootstrap flow.
- resources: pinned upstream installer, manifests, SDK/runtime assets, packaged tools.
- tools: developer-side helper notes for packaged dependency installers.
- logs: source-level documentation for runtime log locations and retention.
- docs: architecture, release, and troubleshooting documentation.