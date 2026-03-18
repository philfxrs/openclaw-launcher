using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Web.Script.Serialization;

internal static class OpenClawLauncher
{
    private const string BaseDashboardUrl = "http://127.0.0.1:18789/";
    private const string GatewayWebSocketUrl = "ws://127.0.0.1:18789";
    private const string ControlSettingsStorageKey = "openclaw.control.settings.v1";
    private const string DeviceIdentityStorageKey = "openclaw-device-identity-v1";
    private const string DeviceTokenStorageKey = "openclaw.device.auth.v1";
    private const int DefaultTimeoutSeconds = 60;

    [STAThread]
    private static int Main(string[] args)
    {
        LauncherOptions options = LauncherOptions.Parse(args);
        FileLogger logger = null;

        try
        {
            logger = new FileLogger(options.LogPath);
            logger.Info("Launcher starting.");

            if (options.SelfTest)
            {
                logger.Info("Self-test succeeded.");
                return 0;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            using (OpenClawShellForm shell = new OpenClawShellForm(options, logger))
            {
                Application.Run(shell);
                logger.Info("Launcher finished with exit code " + shell.ExitCode + ".");
                return shell.ExitCode;
            }
        }
        catch (Exception ex)
        {
            if (logger != null)
            {
                logger.Error(ex.ToString());
            }

            if (!options.QuietErrors)
            {
                MessageBox.Show(
                    ex.Message,
                    "OpenClaw",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
            }

            return 1;
        }
        finally
        {
            if (logger != null)
            {
                logger.Dispose();
            }
        }
    }

    private static string ResolveOpenClawCommand()
    {
        foreach (string candidate in new[] { "openclaw.cmd", "openclaw.exe", "openclaw" })
        {
            string resolved = ResolveFromPath(candidate);
            if (!string.IsNullOrWhiteSpace(resolved))
            {
                return resolved;
            }
        }

        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string npmCandidate = Path.Combine(appData, "npm", "openclaw.cmd");
        return File.Exists(npmCandidate) ? npmCandidate : null;
    }

    private static string ResolveFromPath(string commandName)
    {
        string path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (string segment in path.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                string candidate = Path.Combine(segment.Trim(), commandName);
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch
            {
            }
        }

        return null;
    }

    private static LaunchContext CreateLaunchContext(FileLogger logger, int timeoutSeconds)
    {
        string openClawCommand = ResolveOpenClawCommand();
        if (string.IsNullOrWhiteSpace(openClawCommand))
        {
            throw new InvalidOperationException("OpenClaw CLI was not found. Reinstall OpenClaw from the Windows installer.");
        }

        string gatewayToken = ReadGatewayToken(openClawCommand, logger);
        EnsureGatewayStarted(openClawCommand, logger, timeoutSeconds);

        string url = ResolveDashboardUrl(openClawCommand, gatewayToken, logger);
        logger.Info("Resolved dashboard URL for the desktop shell.");

        return new LaunchContext(openClawCommand, gatewayToken, GatewayWebSocketUrl, url);
    }

    private static string ReadGatewayToken(string openClawCommand, FileLogger logger)
    {
        CommandResult result = RunProcess(openClawCommand, "config get gateway.auth.token", logger, true, true);
        string token = (result.StandardOutput ?? string.Empty).Trim();
        if (!string.IsNullOrWhiteSpace(token))
        {
            return token;
        }

        logger.Info("Gateway token missing. Asking OpenClaw to generate one.");
        RunProcess(openClawCommand, "doctor --generate-gateway-token", logger, true, false);
        result = RunProcess(openClawCommand, "config get gateway.auth.token", logger, true, true);
        token = (result.StandardOutput ?? string.Empty).Trim();
        if (string.IsNullOrWhiteSpace(token))
        {
            throw new InvalidOperationException("OpenClaw gateway token is not configured.");
        }

        return token;
    }

    private static void EnsureGatewayStarted(string openClawCommand, FileLogger logger, int timeoutSeconds)
    {
        RunProcess(openClawCommand, "gateway start", logger, true, false);

        DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(BaseDashboardUrl);
                request.Timeout = 5000;
                request.Method = "GET";

                using (WebResponse response = request.GetResponse())
                {
                    logger.Info("Gateway endpoint is reachable.");
                    return;
                }
            }
            catch (WebException ex)
            {
                if (ex.Response != null)
                {
                    logger.Info("Gateway responded with an HTTP error, which still proves the service is up.");
                    return;
                }
            }

            Thread.Sleep(1500);
        }

        throw new TimeoutException("Timed out waiting for the OpenClaw gateway to become reachable.");
    }

    private static string ResolveDashboardUrl(string openClawCommand, string gatewayToken, FileLogger logger)
    {
        CommandResult result = RunProcess(openClawCommand, "dashboard --no-open", logger, true, true);
        string standardOutput = result.StandardOutput ?? string.Empty;
        string[] lines = standardOutput.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        foreach (string line in lines)
        {
            const string prefix = "Dashboard URL:";
            if (line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                string url = line.Substring(prefix.Length).Trim();
                if (!string.IsNullOrWhiteSpace(url))
                {
                    return url;
                }
            }
        }

        return BuildDashboardUrl(gatewayToken);
    }

    private static string BuildDashboardUrl(string token)
    {
        return BaseDashboardUrl + "#token=" + Uri.EscapeDataString(token);
    }

    private static string GetWebViewUserDataRoot()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenClaw",
            "WebView2Profile"
        );
    }

    private static CommandResult RunProcess(
        string fileName,
        string arguments,
        FileLogger logger,
        bool allowNonZeroExit,
        bool redactStdOut)
    {
        logger.Info(string.Format("Running: {0} {1}", fileName, arguments));

        ProcessStartInfo startInfo = new ProcessStartInfo(fileName, arguments);
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.RedirectStandardOutput = true;
        startInfo.RedirectStandardError = true;

        using (Process process = new Process())
        {
            process.StartInfo = startInfo;
            process.Start();
            string standardOutput = process.StandardOutput.ReadToEnd();
            string standardError = process.StandardError.ReadToEnd();
            process.WaitForExit();

            if (!string.IsNullOrWhiteSpace(standardOutput))
            {
                logger.Info(redactStdOut ? "__OPENCLAW_REDACTED__" : standardOutput.Trim());
            }

            if (!string.IsNullOrWhiteSpace(standardError))
            {
                logger.Error(standardError.Trim());
            }

            if (!allowNonZeroExit && process.ExitCode != 0)
            {
                throw new InvalidOperationException(
                    string.Format("Command failed with exit code {0}: {1} {2}", process.ExitCode, fileName, arguments)
                );
            }

            return new CommandResult(process.ExitCode, standardOutput, standardError);
        }
    }

    private sealed class OpenClawShellForm : Form
    {
        private readonly LauncherOptions _options;
        private readonly FileLogger _logger;
        private readonly Panel _loadingPanel;
        private readonly Label _headlineLabel;
        private readonly Label _statusLabel;
        private readonly ProgressBar _progressBar;
        private readonly Button _retryButton;
        private readonly WebView2 _webView;
        private readonly JavaScriptSerializer _serializer;
        private TaskCompletionSource<bool> _navigationCompletion;
        private string _bootstrapScriptId;
        private string _lastObservedStateSummary;
        private bool _startupStarted;

        public OpenClawShellForm(LauncherOptions options, FileLogger logger)
        {
            _options = options;
            _logger = logger;
            _serializer = new JavaScriptSerializer();
            ExitCode = 1;

            Text = "OpenClaw";
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(1024, 720);
            ClientSize = new Size(1400, 900);
            BackColor = Color.FromArgb(250, 248, 242);

            _webView = new WebView2();
            _webView.Dock = DockStyle.Fill;
            _webView.Visible = false;
            _webView.CreationProperties = new CoreWebView2CreationProperties
            {
                UserDataFolder = GetWebViewUserDataRoot()
            };

            _loadingPanel = new Panel();
            _loadingPanel.Dock = DockStyle.Fill;
            _loadingPanel.Padding = new Padding(48);
            _loadingPanel.BackColor = Color.FromArgb(250, 248, 242);

            _headlineLabel = new Label();
            _headlineLabel.AutoSize = false;
            _headlineLabel.Dock = DockStyle.Top;
            _headlineLabel.Height = 52;
            _headlineLabel.Font = new Font("Segoe UI Semibold", 22f, FontStyle.Bold);
            _headlineLabel.Text = "OpenClaw";
            _headlineLabel.TextAlign = ContentAlignment.MiddleLeft;

            _statusLabel = new Label();
            _statusLabel.AutoSize = false;
            _statusLabel.Dock = DockStyle.Top;
            _statusLabel.Height = 72;
            _statusLabel.Font = new Font("Segoe UI", 11f, FontStyle.Regular);
            _statusLabel.Text = "Preparing the OpenClaw desktop shell.";
            _statusLabel.TextAlign = ContentAlignment.MiddleLeft;

            _progressBar = new ProgressBar();
            _progressBar.Dock = DockStyle.Top;
            _progressBar.Height = 8;
            _progressBar.Style = ProgressBarStyle.Marquee;
            _progressBar.MarqueeAnimationSpeed = 24;

            _retryButton = new Button();
            _retryButton.Dock = DockStyle.Top;
            _retryButton.Height = 40;
            _retryButton.Width = 140;
            _retryButton.Text = "Retry";
            _retryButton.Visible = false;
            _retryButton.Click += RetryButtonClick;

            Panel contentPanel = new Panel();
            contentPanel.Dock = DockStyle.Top;
            contentPanel.Height = 220;
            contentPanel.Controls.Add(_retryButton);
            contentPanel.Controls.Add(_progressBar);
            contentPanel.Controls.Add(_statusLabel);
            contentPanel.Controls.Add(_headlineLabel);

            _loadingPanel.Controls.Add(contentPanel);

            Controls.Add(_webView);
            Controls.Add(_loadingPanel);

            Shown += HandleShown;
        }

        public int ExitCode { get; private set; }

        private async void HandleShown(object sender, EventArgs e)
        {
            if (_startupStarted)
            {
                return;
            }

            _startupStarted = true;
            await StartShellAsync();
        }

        private async void RetryButtonClick(object sender, EventArgs e)
        {
            _retryButton.Visible = false;
            _progressBar.Visible = true;
            _progressBar.Style = ProgressBarStyle.Marquee;
            _statusLabel.Text = "Retrying OpenClaw startup.";
            await StartShellAsync();
        }

        private async Task StartShellAsync()
        {
            try
            {
                SetBusy("Preparing OpenClaw and starting the local Control UI.");
                LaunchContext context = await Task.Run(
                    delegate
                    {
                        return CreateLaunchContext(_logger, _options.TimeoutSeconds);
                    });

                await EnsureWebViewReadyAsync();
                await ApplyBootstrapScriptAsync(context);
                await NavigateAndAwaitReadyAsync(context);
                ExitCode = 0;
            }
            catch (Exception ex)
            {
                ExitCode = 1;
                _logger.Error(ex.ToString());
                ShowFailure(ex.Message);

                if (_options.QuietErrors)
                {
                    Close();
                }
            }
        }

        private async Task EnsureWebViewReadyAsync()
        {
            if (_webView.CoreWebView2 != null)
            {
                return;
            }

            Directory.CreateDirectory(GetWebViewUserDataRoot());
            await _webView.EnsureCoreWebView2Async(null);

            _webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            _webView.CoreWebView2.Settings.AreDevToolsEnabled = false;
            _webView.CoreWebView2.Settings.IsStatusBarEnabled = false;
            _webView.CoreWebView2.Settings.AreBrowserAcceleratorKeysEnabled = true;
            _webView.CoreWebView2.NewWindowRequested += HandleNewWindowRequested;
            _webView.CoreWebView2.DocumentTitleChanged += HandleDocumentTitleChanged;
            _webView.NavigationCompleted += HandleNavigationCompleted;
        }

        private void NavigateDashboard(string dashboardUrl)
        {
            SetBusy("OpenClaw is loading the Control UI.");
            _navigationCompletion = new TaskCompletionSource<bool>();
            _webView.Source = new Uri(dashboardUrl);
        }

        private void HandleNewWindowRequested(object sender, CoreWebView2NewWindowRequestedEventArgs e)
        {
            e.Handled = true;
            if (_webView.CoreWebView2 != null)
            {
                _webView.CoreWebView2.Navigate(e.Uri);
            }
        }

        private void HandleDocumentTitleChanged(object sender, object e)
        {
            if (_webView.CoreWebView2 == null)
            {
                return;
            }

            string documentTitle = _webView.CoreWebView2.DocumentTitle;
            if (string.IsNullOrWhiteSpace(documentTitle))
            {
                Text = "OpenClaw";
            }
            else
            {
                Text = "OpenClaw - " + documentTitle;
            }
        }

        private void HandleNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            if (e.IsSuccess)
            {
                _logger.Info("WebView2 navigation completed successfully.");
                if (_navigationCompletion != null)
                {
                    _navigationCompletion.TrySetResult(true);
                }
                return;
            }

            ExitCode = 1;
            if (_navigationCompletion != null)
            {
                _navigationCompletion.TrySetException(
                    new InvalidOperationException("The OpenClaw desktop window could not load the Control UI.")
                );
            }
            ShowFailure("The OpenClaw desktop window could not load the Control UI.");
            _logger.Error("WebView2 navigation failed with status " + e.WebErrorStatus + ".");
        }

        private void SetBusy(string message)
        {
            _loadingPanel.Visible = true;
            _webView.Visible = false;
            _retryButton.Visible = false;
            _progressBar.Visible = true;
            _statusLabel.Text = message;
        }

        private void ShowFailure(string message)
        {
            _loadingPanel.Visible = true;
            _webView.Visible = false;
            _progressBar.Visible = false;
            _retryButton.Visible = true;
            _statusLabel.Text = message;
        }

        private async Task ApplyBootstrapScriptAsync(LaunchContext context)
        {
            if (_webView.CoreWebView2 == null)
            {
                return;
            }

            if (!string.IsNullOrWhiteSpace(_bootstrapScriptId))
            {
                _webView.CoreWebView2.RemoveScriptToExecuteOnDocumentCreated(_bootstrapScriptId);
                _bootstrapScriptId = null;
            }

            string script = BuildStorageBootstrapScript(context, false);
            _bootstrapScriptId = await _webView.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(script);
        }

        private async Task NavigateAndAwaitReadyAsync(LaunchContext context)
        {
            _lastObservedStateSummary = null;

            NavigateDashboard(context.DashboardUrl);
            await WaitForNavigationAsync();
            await WaitForControlUiReadyAsync(context);

            _loadingPanel.Visible = false;
            _webView.Visible = true;
            Text = "OpenClaw";
            _logger.Info("Control UI is ready for use.");
        }

        private async Task WaitForNavigationAsync()
        {
            TaskCompletionSource<bool> completion = _navigationCompletion;
            if (completion == null)
            {
                return;
            }

            Task finished = await Task.WhenAny(completion.Task, Task.Delay(TimeSpan.FromSeconds(_options.TimeoutSeconds)));
            if (finished != completion.Task)
            {
                throw new TimeoutException("Timed out while loading the OpenClaw desktop window.");
            }

            await completion.Task;
        }

        private async Task WaitForControlUiReadyAsync(LaunchContext initialContext)
        {
            DateTime deadline = DateTime.UtcNow.AddSeconds(_options.TimeoutSeconds);
            LaunchContext context = initialContext;
            bool attemptedConnect = false;
            bool attemptedRepair = false;

            while (DateTime.UtcNow < deadline)
            {
                DashboardPageState state = await ReadDashboardPageStateAsync();
                if (state != null)
                {
                    LogPageState(state);

                    if (state.IsReady())
                    {
                        return;
                    }

                    if (state.HasRateLimitError())
                    {
                        SetBusy("OpenClaw is waiting for a short authentication cooldown.");
                        await Task.Delay(2500);
                        continue;
                    }

                    if (state.HasTokenMismatch() && !attemptedRepair)
                    {
                        attemptedRepair = true;
                        attemptedConnect = false;
                        context = await RepairDashboardAuthAsync(context);
                        continue;
                    }

                    if (state.ShouldClickConnect() && !attemptedConnect)
                    {
                        attemptedConnect = await TryClickConnectButtonAsync();
                        if (attemptedConnect)
                        {
                            SetBusy("OpenClaw is finishing Control UI sign-in.");
                        }
                    }
                }

                await Task.Delay(1000);
            }

            throw new TimeoutException("Timed out waiting for the OpenClaw Control UI to become usable.");
        }

        private async Task<LaunchContext> RepairDashboardAuthAsync(LaunchContext currentContext)
        {
            SetBusy("Refreshing OpenClaw authentication.");
            _logger.Info("Detected an authentication mismatch inside the Control UI. Refreshing dashboard bootstrap state.");

            LaunchContext refreshedContext = await Task.Run(
                delegate
                {
                    return CreateLaunchContext(_logger, _options.TimeoutSeconds);
                });

            await ApplyBootstrapScriptAsync(refreshedContext);
            await ExecuteScriptAsync(BuildStorageBootstrapScript(refreshedContext, true));

            NavigateDashboard(refreshedContext.DashboardUrl);
            await WaitForNavigationAsync();

            return refreshedContext;
        }

        private async Task<DashboardPageState> ReadDashboardPageStateAsync()
        {
            if (_webView.CoreWebView2 == null)
            {
                return null;
            }

            string result = await ExecuteScriptAsync(BuildDashboardPageStateScript());
            if (string.IsNullOrWhiteSpace(result) || string.Equals(result, "null", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            return _serializer.Deserialize<DashboardPageState>(result);
        }

        private async Task<bool> TryClickConnectButtonAsync()
        {
            if (_webView.CoreWebView2 == null)
            {
                return false;
            }

            string result = await ExecuteScriptAsync(BuildConnectButtonScript());
            if (string.IsNullOrWhiteSpace(result))
            {
                return false;
            }

            bool clicked = _serializer.Deserialize<bool>(result);
            if (clicked)
            {
                _logger.Info("Triggered the Control UI connect action automatically.");
            }

            return clicked;
        }

        private async Task<string> ExecuteScriptAsync(string script)
        {
            if (_webView.CoreWebView2 == null)
            {
                return null;
            }

            try
            {
                return await _webView.ExecuteScriptAsync(script);
            }
            catch (Exception ex)
            {
                _logger.Error("WebView2 script execution failed: " + ex.Message);
                return null;
            }
        }

        private void LogPageState(DashboardPageState state)
        {
            string summary = string.Format(
                "href={0}; connectVisible={1}; tokenInputFilled={2}; ready={3}; tokenMismatch={4}; rateLimited={5}; body={6}",
                state.href ?? string.Empty,
                state.connectVisible,
                state.tokenInputFilled,
                state.ready,
                state.tokenMismatch,
                state.rateLimited,
                state.GetBodySummary()
            );

            if (!string.Equals(summary, _lastObservedStateSummary, StringComparison.Ordinal))
            {
                _lastObservedStateSummary = summary;
                _logger.Info("Control UI state: " + summary);
            }
        }

        private static string BuildStorageBootstrapScript(LaunchContext context, bool clearDeviceState)
        {
            string gatewayUrl = ToJavaScriptStringLiteral(context.GatewayWebSocketUrl);
            string token = ToJavaScriptStringLiteral(context.GatewayToken);
            string deviceStateResetScript = clearDeviceState
                ? "try { localStorage.removeItem('" + DeviceTokenStorageKey + "'); } catch (_) {} try { localStorage.removeItem('" + DeviceIdentityStorageKey + "'); } catch (_) {}"
                : string.Empty;

            return
                "(function () {" +
                "  try {" +
                "    var gatewayUrl = " + gatewayUrl + ";" +
                "    var token = " + token + ";" +
                "    var tokenKey = 'openclaw.control.token.v1:' + gatewayUrl;" +
                "    try { sessionStorage.setItem(tokenKey, token); } catch (_) {}" +
                "    try { sessionStorage.removeItem('openclaw.control.token.v1:ws://localhost:18789'); } catch (_) {}" +
                "    try {" +
                "      var settingsRaw = localStorage.getItem('" + ControlSettingsStorageKey + "');" +
                "      var settings = settingsRaw ? JSON.parse(settingsRaw) : {};" +
                "      settings.gatewayUrl = gatewayUrl;" +
                "      if (!settings.sessionKey) { settings.sessionKey = 'agent:main:main'; }" +
                "      if (!settings.lastActiveSessionKey) { settings.lastActiveSessionKey = settings.sessionKey; }" +
                "      localStorage.setItem('" + ControlSettingsStorageKey + "', JSON.stringify(settings));" +
                "    } catch (_) {}" +
                deviceStateResetScript +
                "  } catch (_) {}" +
                "})();";
        }

        private static string BuildDashboardPageStateScript()
        {
            return
                "(function () {" +
                "  function textOf(node) {" +
                "    if (!node) { return ''; }" +
                "    return String(node.innerText || node.textContent || '').replace(/\\s+/g, ' ').trim();" +
                "  }" +
                "  function hasButtonLabel(labels) {" +
                "    var buttons = Array.prototype.slice.call(document.querySelectorAll('button'));" +
                "    return buttons.some(function (button) {" +
                "      var text = textOf(button).toLowerCase();" +
                "      return labels.indexOf(text) >= 0;" +
                "    });" +
                "  }" +
                "  function hasFilledInput() {" +
                "    var inputs = Array.prototype.slice.call(document.querySelectorAll('input'));" +
                "    return inputs.some(function (input) {" +
                "      var value = String(input.value || '').trim();" +
                "      return value.length >= 16;" +
                "    });" +
                "  }" +
                "  var body = textOf(document.body);" +
                "  var loweredBody = body.toLowerCase();" +
                "  var connectLabels = ['connect', '连接', '連接', 'verbinden', 'conectar'];" +
                "  var readyLabels = ['ready to chat', '准备聊天', '準備聊天'];" +
                "  var ready = readyLabels.some(function (label) { return loweredBody.indexOf(label) >= 0; }) || (location.pathname || '').indexOf('/chat') >= 0;" +
                "  return {" +
                "    href: location.href," +
                "    connectVisible: hasButtonLabel(connectLabels)," +
                "    tokenInputFilled: hasFilledInput()," +
                "    ready: ready," +
                "    tokenMismatch: loweredBody.indexOf('gateway token mismatch') >= 0 || loweredBody.indexOf('token mismatch') >= 0," +
                "    authFailed: loweredBody.indexOf('auth failed') >= 0 || loweredBody.indexOf('身份验证失败') >= 0 || loweredBody.indexOf('unauthorized') >= 0," +
                "    rateLimited: loweredBody.indexOf('too many failed authentication attempts') >= 0 || loweredBody.indexOf('retry later') >= 0," +
                "    bodySample: body.substring(0, 600)" +
                "  };" +
                "})();";
        }

        private static string BuildConnectButtonScript()
        {
            return
                "(function () {" +
                "  function textOf(node) {" +
                "    if (!node) { return ''; }" +
                "    return String(node.innerText || node.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase();" +
                "  }" +
                "  var labels = ['connect', '连接', '連接', 'verbinden', 'conectar'];" +
                "  var buttons = Array.prototype.slice.call(document.querySelectorAll('button'));" +
                "  for (var index = 0; index < buttons.length; index++) {" +
                "    var button = buttons[index];" +
                "    if (labels.indexOf(textOf(button)) >= 0) {" +
                "      button.click();" +
                "      return true;" +
                "    }" +
                "  }" +
                "  return false;" +
                "})();";
        }

        private static string ToJavaScriptStringLiteral(string value)
        {
            StringBuilder builder = new StringBuilder();
            builder.Append('\"');
            if (!string.IsNullOrEmpty(value))
            {
                foreach (char character in value)
                {
                    switch (character)
                    {
                        case '\\':
                            builder.Append("\\\\");
                            break;
                        case '\"':
                            builder.Append("\\\"");
                            break;
                        case '\r':
                            builder.Append("\\r");
                            break;
                        case '\n':
                            builder.Append("\\n");
                            break;
                        case '\t':
                            builder.Append("\\t");
                            break;
                        case '<':
                            builder.Append("\\u003C");
                            break;
                        case '>':
                            builder.Append("\\u003E");
                            break;
                        default:
                            if (character < 32)
                            {
                                builder.Append("\\u");
                                builder.Append(((int)character).ToString("x4"));
                            }
                            else
                            {
                                builder.Append(character);
                            }
                            break;
                    }
                }
            }

            builder.Append('\"');
            return builder.ToString();
        }
    }

    private sealed class LaunchContext
    {
        public LaunchContext(string openClawCommand, string gatewayToken, string gatewayWebSocketUrl, string dashboardUrl)
        {
            OpenClawCommand = openClawCommand;
            GatewayToken = gatewayToken;
            GatewayWebSocketUrl = gatewayWebSocketUrl;
            DashboardUrl = dashboardUrl;
        }

        public string OpenClawCommand { get; private set; }
        public string GatewayToken { get; private set; }
        public string GatewayWebSocketUrl { get; private set; }
        public string DashboardUrl { get; private set; }
    }

    private sealed class DashboardPageState
    {
        public string href { get; set; }
        public bool connectVisible { get; set; }
        public bool tokenInputFilled { get; set; }
        public bool ready { get; set; }
        public bool tokenMismatch { get; set; }
        public bool authFailed { get; set; }
        public bool rateLimited { get; set; }
        public string bodySample { get; set; }

        public bool IsReady()
        {
            return ready;
        }

        public bool HasTokenMismatch()
        {
            return tokenMismatch;
        }

        public bool HasRateLimitError()
        {
            return rateLimited;
        }

        public bool ShouldClickConnect()
        {
            return connectVisible && tokenInputFilled;
        }

        public string GetBodySummary()
        {
            if (string.IsNullOrWhiteSpace(bodySample))
            {
                return string.Empty;
            }

            return bodySample.Replace('\r', ' ').Replace('\n', ' ').Trim();
        }
    }

    private sealed class LauncherOptions
    {
        public string LogPath { get; private set; }
        public bool QuietErrors { get; private set; }
        public bool SelfTest { get; private set; }
        public int TimeoutSeconds { get; private set; }

        public static LauncherOptions Parse(string[] args)
        {
            LauncherOptions options = new LauncherOptions();
            options.TimeoutSeconds = DefaultTimeoutSeconds;

            for (int index = 0; index < args.Length; index++)
            {
                string value = args[index];
                if (string.Equals(value, "--log", StringComparison.OrdinalIgnoreCase) && index + 1 < args.Length)
                {
                    options.LogPath = args[++index];
                }
                else if (string.Equals(value, "--quiet-errors", StringComparison.OrdinalIgnoreCase))
                {
                    options.QuietErrors = true;
                }
                else if (string.Equals(value, "--self-test", StringComparison.OrdinalIgnoreCase))
                {
                    options.SelfTest = true;
                }
                else if (string.Equals(value, "--timeout", StringComparison.OrdinalIgnoreCase) && index + 1 < args.Length)
                {
                    int timeout;
                    if (int.TryParse(args[++index], out timeout))
                    {
                        options.TimeoutSeconds = timeout;
                    }
                }
            }

            if (string.IsNullOrWhiteSpace(options.LogPath))
            {
                string logRoot = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "OpenClaw",
                    "logs"
                );
                Directory.CreateDirectory(logRoot);
                options.LogPath = Path.Combine(logRoot, "launcher.log");
            }

            return options;
        }
    }

    private sealed class FileLogger : IDisposable
    {
        private readonly StreamWriter _writer;

        public FileLogger(string path)
        {
            string directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            _writer = new StreamWriter(path, true, Encoding.UTF8);
            _writer.AutoFlush = true;
        }

        public void Info(string message)
        {
            Write("INFO", message);
        }

        public void Error(string message)
        {
            Write("ERROR", message);
        }

        public void Dispose()
        {
            _writer.Dispose();
        }

        private void Write(string level, string message)
        {
            string line = string.Format(
                "[{0}] [{1}] {2}",
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"),
                level,
                message
            );
            _writer.WriteLine(line);
        }
    }

    private sealed class CommandResult
    {
        public CommandResult(int exitCode, string standardOutput, string standardError)
        {
            ExitCode = exitCode;
            StandardOutput = standardOutput;
            StandardError = standardError;
        }

        public int ExitCode { get; private set; }
        public string StandardOutput { get; private set; }
        public string StandardError { get; private set; }
    }
}
