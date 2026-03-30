interface Env {
  GITHUB_TOKEN: string;
  GITHUB_OWNER: string;
  GITHUB_REPO: string;
  SHARED_SECRET?: string;
  ALLOWED_SOURCE?: string;
  APP_VERSION?: string;
}

type JsonRecord = Record<string, unknown>;

interface NormalizedStep {
  id: string | null;
  number: number | null;
  name: string | null;
  code: string | null;
}

interface NormalizedDependency {
  detected: boolean | null;
  version: string | null;
}

interface NormalizedSummary {
  installerVersion: string | null;
  buildVersion: string | null;
  timestampUtc: string | null;
  osVersion: string | null;
  architecture: string | null;
  isAdmin: boolean | null;
  locale: string | null;
  currentStep: NormalizedStep | null;
  failedStep: NormalizedStep | null;
  errorCode: string | null;
  errorMessage: string | null;
  lastCommand: string | null;
  exitCode: number | null;
  dependencies: {
    node: NormalizedDependency;
    npm: NormalizedDependency;
    git: NormalizedDependency;
    webview2: NormalizedDependency;
    openclaw: NormalizedDependency;
  };
  installationState: {
    launcherExists: boolean | null;
    shortcutExists: boolean | null;
    gatewayReachable: boolean | null;
    installRootExists: boolean | null;
  };
  references: {
    localLogPath: string | null;
    localStatePath: string | null;
  };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      const url = new URL(request.url);

      if (request.method === 'GET' && url.pathname === '/health') {
        return jsonResponse(200, {
          ok: true,
          version: env.APP_VERSION || '0.1.0',
        });
      }

      if (request.method === 'POST' && url.pathname === '/installer-diagnostics') {
        return handleInstallerDiagnostics(request, env);
      }

      return jsonResponse(404, {
        success: false,
        error: 'not_found',
        message: 'route not found',
      });
    } catch (error) {
      return jsonResponse(500, {
        success: false,
        error: 'internal_error',
        message: error instanceof Error ? error.message : 'unknown error',
      });
    }
  },
};

async function handleInstallerDiagnostics(request: Request, env: Env): Promise<Response> {
  const authError = verifySharedSecret(request, env);
  if (authError) {
    return jsonResponse(401, {
      success: false,
      error: 'unauthorized',
      message: authError,
    });
  }

  const parsed = await parseRequestPayload(request);
  if ('error' in parsed) {
    return jsonResponse(parsed.status, {
      success: false,
      error: parsed.error,
      message: parsed.message,
    });
  }

  const allowedSource = getNonEmptyString(env.ALLOWED_SOURCE) || 'windows-installer';
  const validationError = validateRequest(parsed.source, parsed.summary, allowedSource);
  if (validationError) {
    return jsonResponse(400, {
      success: false,
      error: 'invalid_request',
      message: validationError,
    });
  }

  if (!hasGithubConfig(env)) {
    return jsonResponse(500, {
      success: false,
      error: 'server_misconfigured',
      message: 'worker is missing GitHub configuration',
    });
  }

  const summary = normalizeSummary(parsed.summary);
  const reportId = await createReportId();

  try {
    const issue = await createGithubIssue(env, reportId, summary);
    return jsonResponse(201, {
      success: true,
      reportId,
      issueNumber: issue.number,
    });
  } catch (error) {
    return jsonResponse(502, {
      success: false,
      error: 'github_issue_create_failed',
      message: error instanceof Error ? error.message : 'unknown error',
    });
  }
}

function verifySharedSecret(request: Request, env: Env): string | null {
  const expected = getNonEmptyString(env.SHARED_SECRET);
  if (!expected) {
    return null;
  }

  const actual = getNonEmptyString(request.headers.get('X-OpenClaw-Secret'));
  if (!actual) {
    return 'missing X-OpenClaw-Secret header';
  }

  if (actual !== expected) {
    return 'invalid shared secret';
  }

  return null;
}

async function parseRequestPayload(request: Request): Promise<
  | { source: string | null; summary: JsonRecord | null }
  | { status: number; error: string; message: string }
> {
  const contentType = request.headers.get('content-type') || '';

  try {
    if (contentType.includes('application/json')) {
      const payload = (await request.json()) as JsonRecord;
      return {
        source: getSourceFromPayload(payload),
        summary: payload,
      };
    }

    if (contentType.includes('multipart/form-data')) {
      const formData = await request.formData();
      const source = getNonEmptyString(formData.get('source')) || getNonEmptyString(formData.get('reportSource'));
      const summaryEntry = formData.get('summary');

      if (!(summaryEntry instanceof File)) {
        return {
          status: 400,
          error: 'invalid_request',
          message: 'multipart field summary is required',
        };
      }

      const text = await summaryEntry.text();
      return {
        source,
        summary: JSON.parse(text) as JsonRecord,
      };
    }
  } catch (error) {
    return {
      status: 400,
      error: 'invalid_request',
      message: error instanceof Error ? error.message : 'failed to parse request payload',
    };
  }

  return {
    status: 400,
    error: 'invalid_request',
    message: 'content-type must be application/json or multipart/form-data',
  };
}

function getSourceFromPayload(payload: JsonRecord): string | null {
  return getNonEmptyString(payload.source) || getNonEmptyString(payload.reportSource);
}

function hasGithubConfig(env: Env): boolean {
  return Boolean(env.GITHUB_TOKEN && env.GITHUB_OWNER && env.GITHUB_REPO);
}

function validateRequest(source: string | null, summary: JsonRecord | null, allowedSource: string): string | null {
  if (source !== allowedSource) {
    return `source must be ${allowedSource}`;
  }

  if (!summary || typeof summary !== 'object') {
    return 'summary payload is required';
  }

  if (!getNonEmptyString(summary.errorCode) && !getNonEmptyString(summary.errorMessage) && !summary.failedStep) {
    return 'summary must include at least one failure indicator';
  }

  return null;
}

async function createReportId(now = new Date()): Promise<string> {
  const datePart = now.toISOString().slice(0, 10).replace(/-/g, '');
  const randomBytes = new Uint8Array(4);
  crypto.getRandomValues(randomBytes);
  const shortId = Array.from(randomBytes, (value) => value.toString(16).padStart(2, '0')).join('').toUpperCase();
  return `OCWIN-${datePart}-${shortId}`;
}

function normalizeSummary(raw: JsonRecord | null): NormalizedSummary {
  const summary = raw || {};
  return {
    installerVersion: getNonEmptyString(summary.installerVersion),
    buildVersion: getNonEmptyString(summary.buildVersion),
    timestampUtc: getNonEmptyString(summary.timestampUtc),
    osVersion: getNonEmptyString(summary.osVersion),
    architecture: getNonEmptyString(summary.architecture),
    isAdmin: getBoolean(summary.isAdmin),
    locale: getNonEmptyString(summary.locale),
    currentStep: normalizeStep(summary.currentStep),
    failedStep: normalizeStep(summary.failedStep),
    errorCode: getNonEmptyString(summary.errorCode),
    errorMessage: getNonEmptyString(summary.errorMessage),
    lastCommand: getNonEmptyString(summary.lastCommand),
    exitCode: getNumber(summary.exitCode),
    dependencies: {
      node: normalizeDependency(getObject(summary.dependencies)?.node, true),
      npm: normalizeDependency(getObject(summary.dependencies)?.npm, true),
      git: normalizeDependency(getObject(summary.dependencies)?.git, true),
      webview2: normalizeDependency(getObject(summary.dependencies)?.webview2, false),
      openclaw: normalizeDependency(getObject(summary.dependencies)?.openclaw, false),
    },
    installationState: normalizeInstallationState(summary.installationState),
    references: {
      localLogPath: getNonEmptyString(getObject(summary.references)?.localLogPath),
      localStatePath: getNonEmptyString(getObject(summary.references)?.localStatePath),
    },
  };
}

function normalizeStep(value: unknown): NormalizedStep | null {
  const obj = getObject(value);
  if (!obj) {
    return null;
  }

  return {
    id: getNonEmptyString(obj.id),
    number: getNumber(obj.number),
    name: getNonEmptyString(obj.name),
    code: getNonEmptyString(obj.code),
  };
}

function normalizeDependency(value: unknown, includeVersion: boolean): NormalizedDependency {
  const obj = getObject(value);
  if (!obj) {
    return { detected: null, version: null };
  }

  return {
    detected: getBoolean(obj.detected),
    version: includeVersion ? getNonEmptyString(obj.version) : null,
  };
}

function normalizeInstallationState(value: unknown): NormalizedSummary['installationState'] {
  const obj = getObject(value);
  if (!obj) {
    return {
      launcherExists: null,
      shortcutExists: null,
      gatewayReachable: null,
      installRootExists: null,
    };
  }

  return {
    launcherExists: getBoolean(obj.launcherExists),
    shortcutExists: getBoolean(obj.shortcutExists),
    gatewayReachable: getBoolean(obj.gatewayReachable),
    installRootExists: getBoolean(obj.installRootExists),
  };
}

function buildIssueTitle(reportId: string, summary: NormalizedSummary): string {
  const errorCode = summary.errorCode || summary.failedStep?.code || 'UNKNOWN';
  return `[Installer Failure] ${reportId} ${errorCode}`;
}

function buildIssueBody(reportId: string, summary: NormalizedSummary): string {
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
    formatPrettyJson(summary.currentStep),
    '',
    'failedStep:',
    formatPrettyJson(summary.failedStep),
    '',
    `errorCode: ${summary.errorCode || 'unknown'}`,
    `errorMessage: ${summary.errorMessage || 'unknown'}`,
    `lastCommand: ${summary.lastCommand || 'unknown'}`,
    `exitCode: ${summary.exitCode === null ? 'unknown' : String(summary.exitCode)}`,
    '',
    'dependencies:',
    formatPrettyJson(summary.dependencies),
    '',
    'installationState:',
    formatPrettyJson(summary.installationState),
    '',
    'references:',
    formatPrettyJson(summary.references),
  ];

  return lines.join('\n');
}

async function createGithubIssue(env: Env, reportId: string, summary: NormalizedSummary): Promise<{ number: number }> {
  const response = await fetch(`https://api.github.com/repos/${env.GITHUB_OWNER}/${env.GITHUB_REPO}/issues`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'Content-Type': 'application/json',
      'User-Agent': 'openclaw-installer-diagnostics-worker',
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

  return (await response.json()) as { number: number };
}

function formatPrettyJson(value: unknown): string {
  return JSON.stringify(value, null, 2);
}

function getObject(value: unknown): JsonRecord | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as JsonRecord) : null;
}

function getNonEmptyString(value: unknown): string | null {
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : null;
}

function getBoolean(value: unknown): boolean | null {
  return typeof value === 'boolean' ? value : null;
}

function getNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function jsonResponse(status: number, body: JsonRecord): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });
}