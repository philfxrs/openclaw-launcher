import crypto from 'node:crypto';
import express from 'express';
import multer from 'multer';

const app = express();
const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 256 * 1024 },
});

const APP_VERSION = process.env.APP_VERSION || '0.1.0';
const PORT = Number.parseInt(process.env.PORT || '3000', 10);
const GITHUB_TOKEN = process.env.GITHUB_TOKEN || '';
const GITHUB_OWNER = process.env.GITHUB_OWNER || '';
const GITHUB_REPO = process.env.GITHUB_REPO || '';

app.disable('x-powered-by');
app.use(express.json({ limit: '256kb' }));

function hasGithubConfig() {
  return Boolean(GITHUB_TOKEN && GITHUB_OWNER && GITHUB_REPO);
}

function createReportId(now = new Date()) {
  const datePart = now.toISOString().slice(0, 10).replace(/-/g, '');
  const shortId = crypto.randomBytes(4).toString('hex').toUpperCase();
  return `OCWIN-${datePart}-${shortId}`;
}

function getString(value) {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null;
}

function getBoolean(value) {
  return typeof value === 'boolean' ? value : null;
}

function getNumber(value) {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function normalizeStep(value) {
  if (!value || typeof value !== 'object') {
    return null;
  }

  return {
    id: getString(value.id),
    number: getNumber(value.number),
    name: getString(value.name),
    code: getString(value.code),
  };
}

function normalizeDependency(value, includeVersion = true) {
  if (!value || typeof value !== 'object') {
    return { detected: null, version: null };
  }

  return {
    detected: getBoolean(value.detected),
    version: includeVersion ? getString(value.version) : null,
  };
}

function normalizeInstallationState(value) {
  if (!value || typeof value !== 'object') {
    return {
      launcherExists: null,
      shortcutExists: null,
      gatewayReachable: null,
      installRootExists: null,
    };
  }

  return {
    launcherExists: getBoolean(value.launcherExists),
    shortcutExists: getBoolean(value.shortcutExists),
    gatewayReachable: getBoolean(value.gatewayReachable),
    installRootExists: getBoolean(value.installRootExists),
  };
}

function normalizeSummary(raw) {
  const summary = raw && typeof raw === 'object' ? raw : {};
  return {
    installerVersion: getString(summary.installerVersion),
    buildVersion: getString(summary.buildVersion),
    timestampUtc: getString(summary.timestampUtc),
    osVersion: getString(summary.osVersion),
    architecture: getString(summary.architecture),
    isAdmin: getBoolean(summary.isAdmin),
    locale: getString(summary.locale),
    currentStep: normalizeStep(summary.currentStep),
    failedStep: normalizeStep(summary.failedStep),
    errorCode: getString(summary.errorCode),
    errorMessage: getString(summary.errorMessage),
    lastCommand: getString(summary.lastCommand),
    exitCode: getNumber(summary.exitCode),
    dependencies: {
      node: normalizeDependency(summary.dependencies?.node),
      npm: normalizeDependency(summary.dependencies?.npm),
      git: normalizeDependency(summary.dependencies?.git),
      webview2: normalizeDependency(summary.dependencies?.webview2, false),
      openclaw: normalizeDependency(summary.dependencies?.openclaw, false),
    },
    installationState: normalizeInstallationState(summary.installationState),
    references: {
      localLogPath: getString(summary.references?.localLogPath),
      localStatePath: getString(summary.references?.localStatePath),
    },
  };
}

function validateRequest(source, summary) {
  if (source !== 'windows-installer') {
    return 'source must be windows-installer';
  }

  if (!summary || typeof summary !== 'object') {
    return 'summary payload is required';
  }

  if (!getString(summary.errorCode) && !getString(summary.errorMessage) && !summary.failedStep) {
    return 'summary must include at least one failure indicator';
  }

  return null;
}

function formatJson(value) {
  return JSON.stringify(value, null, 2);
}

function buildIssueTitle(reportId, summary) {
  const errorCode = summary.errorCode || summary.failedStep?.code || 'UNKNOWN';
  return `[Installer Failure] ${reportId} ${errorCode}`;
}

function buildIssueBody(reportId, summary) {
  const lines = [
    `reportId: ${reportId}`,
    `timestampUtc: ${summary.timestampUtc || 'unknown'}`,
    `installerVersion: ${summary.installerVersion || 'unknown'}`,
    `buildVersion: ${summary.buildVersion || 'unknown'}`,
    `osVersion: ${summary.osVersion || 'unknown'}`,
    `architecture: ${summary.architecture || 'unknown'}`,
    `isAdmin: ${summary.isAdmin === null ? 'unknown' : String(summary.isAdmin)}`,
    `locale: ${summary.locale || 'unknown'}`,
    '',
    'currentStep:',
    formatJson(summary.currentStep),
    '',
    'failedStep:',
    formatJson(summary.failedStep),
    '',
    `errorCode: ${summary.errorCode || 'unknown'}`,
    `errorMessage: ${summary.errorMessage || 'unknown'}`,
    `lastCommand: ${summary.lastCommand || 'unknown'}`,
    `exitCode: ${summary.exitCode === null ? 'unknown' : String(summary.exitCode)}`,
    '',
    'dependencies:',
    formatJson(summary.dependencies),
    '',
    'installationState:',
    formatJson(summary.installationState),
  ];

  return lines.join('\n');
}

async function createGithubIssue(reportId, summary) {
  if (!hasGithubConfig()) {
    throw new Error('server is missing GitHub configuration');
  }

  const response = await fetch(`https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/issues`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${GITHUB_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'Content-Type': 'application/json',
      'User-Agent': 'openclaw-installer-diagnostics-server',
    },
    body: JSON.stringify({
      title: buildIssueTitle(reportId, summary),
      body: buildIssueBody(reportId, summary),
    }),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`GitHub API returned ${response.status}: ${body}`);
  }

  return response.json();
}

function parseMultipartSummary(req) {
  if (!req.file) {
    return null;
  }

  return JSON.parse(req.file.buffer.toString('utf8'));
}

function getRequestSource(req) {
  return getString(req.body?.source) || getString(req.body?.reportSource);
}

app.get('/health', (_req, res) => {
  res.json({
    ok: true,
    version: APP_VERSION,
  });
});

app.post('/installer-diagnostics', upload.single('summary'), async (req, res) => {
  try {
    const source = getRequestSource(req);
    const rawSummary = req.is('application/json') ? req.body : parseMultipartSummary(req);
    const validationError = validateRequest(source, rawSummary);

    if (validationError) {
      return res.status(400).json({
        success: false,
        error: 'invalid_request',
        message: validationError,
      });
    }

    const summary = normalizeSummary(rawSummary);
    const reportId = createReportId();
    const issue = await createGithubIssue(reportId, summary);

    return res.status(201).json({
      success: true,
      reportId,
      issueNumber: issue.number,
    });
  } catch (error) {
    return res.status(502).json({
      success: false,
      error: 'github_issue_create_failed',
      message: error instanceof Error ? error.message : 'unknown error',
    });
  }
});

app.listen(PORT, () => {
  console.log(`OpenClaw installer diagnostics server listening on port ${PORT}`);
});
