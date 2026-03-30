# OpenClaw Installer Diagnostics Server

This is the minimal first-stage backend for Windows installer failure diagnostics.

Scope is intentionally narrow:

- receive a redacted `diagnostics-summary.json`
- create a GitHub issue in a private repository
- return a `reportId` to the installer

Not included:

- database
- admin UI
- zip or attachment uploads
- telemetry platform
- stage-two archive handling

## Requirements

- Node.js 18+
- a GitHub token that can create issues in the target private repository

Recommended token permissions:

- fine-grained PAT with `Issues: Read and write`
- `Metadata: Read`

## Environment variables

- `PORT`
  Local listen port. Default is `3000`.
- `GITHUB_TOKEN`
  GitHub token used only on the server side.
- `GITHUB_OWNER`
  Repository owner or organization, for example `philfxrs`.
- `GITHUB_REPO`
  Repository name, for example `openclaw-launcher`.
- `APP_VERSION`
  Optional service version returned by `GET /health`.

## Install

```powershell
cd .\tools\installer-diagnostics-server
npm install
```

## Run locally

```powershell
$env:GITHUB_TOKEN='YOUR_TOKEN'
$env:GITHUB_OWNER='philfxrs'
$env:GITHUB_REPO='openclaw-launcher'
$env:PORT='3210'
node .\server.mjs
```

## Endpoints

### `GET /health`

Returns service health and version:

```json
{
  "ok": true,
  "version": "0.1.0"
}
```

### `POST /installer-diagnostics`

Accepted request shapes:

- `application/json`
- `multipart/form-data`

The installer currently uses `multipart/form-data` with:

- `summary`: uploaded JSON file
- `source`: `windows-installer`

Success response:

```json
{
  "success": true,
  "reportId": "OCWIN-20260325-0E78F5C4",
  "issueNumber": 1
}
```

Failure response example:

```json
{
  "success": false,
  "error": "github_issue_create_failed",
  "message": "server is missing GitHub configuration"
}
```

## Smoke test

Start the server, then run:

```powershell
node --input-type=module -e "import { File } from 'node:buffer'; const payload = new TextEncoder().encode(JSON.stringify({ source: 'windows-installer', installerVersion: '0.1.9', buildVersion: '0.1.9', timestampUtc: new Date().toISOString(), errorCode: 'E3001', errorMessage: 'smoke test', installationState: { launcherExists: true, shortcutExists: false, gatewayReachable: false, installRootExists: true } })); const form = new FormData(); form.append('summary', new File([payload], 'diagnostics-summary.json', { type: 'application/json' })); form.append('source', 'windows-installer'); const response = await fetch('http://127.0.0.1:3210/installer-diagnostics', { method: 'POST', body: form }); console.log(response.status); console.log(await response.text());"
```

## Connecting the installer build

The installer already reads the upload URL at build time from `OPENCLAW_DIAGNOSTICS_UPLOAD_URI`.

The supported build entrypoint is now:

```powershell
powershell -ExecutionPolicy Bypass -File .\build\Build-Installer.ps1 `
  -DiagnosticsUploadUri 'https://your-host.example.com/installer-diagnostics'
```

That value is compiled into [installer/inno/OpenClawSetup.iss](installer/inno/OpenClawSetup.iss#L1) and then passed through to [installer/powershell/bootstrap.ps1](installer/powershell/bootstrap.ps1#L1).

## Deployment notes

- put this service behind HTTPS
- do not expose the GitHub token to the client
- rotate any token that was ever pasted into chat, logs, or shell history
- if you run behind a reverse proxy, forward only `POST /installer-diagnostics` and `GET /health`