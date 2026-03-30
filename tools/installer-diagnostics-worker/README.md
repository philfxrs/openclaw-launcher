# OpenClaw Installer Diagnostics Worker

This is the minimal Cloudflare Worker relay for first-stage Windows installer diagnostics.

It does only four things:

- receive the redacted `diagnostics-summary.json`
- perform minimal request validation
- create a private GitHub issue
- return a `reportId`

It does not implement:

- a backend platform
- a database
- attachments or zip uploads
- repository file archival
- stage-two diagnostics

## Endpoints

- `GET /health`
- `POST /installer-diagnostics`

## Secrets and variables

Secrets:

- `GITHUB_TOKEN`
- `GITHUB_OWNER`
- `GITHUB_REPO`
- `SHARED_SECRET`

Variables:

- `APP_VERSION`
- `ALLOWED_SOURCE`

## Install

```powershell
cd .\tools\installer-diagnostics-worker
npm install
```

## Configure secrets

```powershell
npx wrangler secret put GITHUB_TOKEN
npx wrangler secret put GITHUB_OWNER
npx wrangler secret put GITHUB_REPO
npx wrangler secret put SHARED_SECRET
```

## Local development

```powershell
npm run dev
```

## Deploy

```powershell
npm run deploy
```

## Smoke test with curl

```bash
curl -X POST https://your-worker.example.workers.dev/installer-diagnostics \
  -H "X-OpenClaw-Secret: YOUR_SHARED_SECRET" \
  -F "source=windows-installer" \
  -F "summary=@diagnostics-summary.json;type=application/json"
```

## Point the installer to the Worker

Build the installer with the Worker endpoint:

```powershell
powershell -ExecutionPolicy Bypass -File .\build\Build-Installer.ps1 `
  -DiagnosticsUploadUri 'https://your-worker.example.workers.dev/installer-diagnostics'
```