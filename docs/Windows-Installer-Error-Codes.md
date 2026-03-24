# Windows Installer Error Codes

Primary log roots:

- %ProgramData%\OpenClawInstaller\Logs
- %TEMP%\OpenClawInstaller
- Inno Setup native log: supplied via /LOG or SetupLogging

Primary codes:

- E1001: installer initialization or unhandled bootstrap failure.
- E1002: administrator privilege acquisition or validation failed.
- E1003: log subsystem initialization failed.
- E1004: system information capture failed.
- E2001: dependency detection failed.
- E2002: Node.js validation or installation failed.
- E2003: npm validation failed.
- E2004: Git validation or installation failed.
- E2005: WebView2 Runtime missing or installation failed.
- E2006: dependency post-install verification failed.
- E3001: official OpenClaw install step failed.
- E3002: OpenClaw launch request failed.
- E3003: OpenClaw installed-state verification failed.
- E4001: desktop or Start menu shortcut creation failed.
- E4002: shortcut target validation failed.
- E5001: launch verification failed.
- E9001: install preserved state for retry instead of performing destructive rollback.

Every log entry records:

- timestamp
- level
- step id and step number
- optional error code
- message
- structured data, when available