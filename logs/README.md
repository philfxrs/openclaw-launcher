# Runtime Logs

The installer writes runtime logs outside the repository so retries and repairs survive upgrades.

Locations:

- %ProgramData%\OpenClawInstaller\Logs\install-*.log
- %ProgramData%\OpenClawInstaller\Logs\install-*.jsonl
- %ProgramData%\OpenClawInstaller\install-state.json
- %TEMP%\OpenClawInstaller for downloaded installers and temporary payloads