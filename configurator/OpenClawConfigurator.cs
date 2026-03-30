using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// ============================================================================
// OpenClaw Configurator — a local visual configuration tool
// Compiled with: csc.exe /target:winexe /out:OpenClawConfigurator.exe ...
// ============================================================================

internal static class OpenClawConfigurator
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        try
        {
            using (ConfiguratorForm form = new ConfiguratorForm())
            {
                Application.Run(form);
            }

            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "OpenClaw 配置工具", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}

// ============================================================================
// Configuration schema — describes every config field
// ============================================================================

internal enum ConfigFieldType
{
    Text,
    Path,
    Number,
    Boolean,
    Choice,
    Password,
    ReadOnly
}

internal enum RiskLevel
{
    Low,
    Medium,
    High
}

internal sealed class ConfigFieldDescriptor
{
    public string Section;
    public string Key;
    public string DisplayName;
    public string Description;
    public string RecommendedValue;
    public RiskLevel Risk;
    public ConfigFieldType FieldType;
    public string[] Choices;
    public object DefaultValue;
    public Func<string, string> Validator;
}

internal static class ConfigSchema
{
    public static List<ConfigFieldDescriptor> GetAllFields()
    {
        List<ConfigFieldDescriptor> fields = new List<ConfigFieldDescriptor>();

        // ---- 基础配置 ----
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "基础配置",
            Key = "install.dir",
            DisplayName = "安装目录",
            Description = "OpenClaw 的安装根目录，包含可执行文件和资源。",
            RecommendedValue = "C:\\Program Files\\OpenClaw",
            Risk = RiskLevel.High,
            FieldType = ConfigFieldType.Path,
            DefaultValue = ""
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "基础配置",
            Key = "data.dir",
            DisplayName = "数据目录",
            Description = "存放 OpenClaw 运行时数据的目录，包括模型缓存、会话记录等。",
            RecommendedValue = "%USERPROFILE%\\.openclaw",
            Risk = RiskLevel.Medium,
            FieldType = ConfigFieldType.Path,
            DefaultValue = ""
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "基础配置",
            Key = "log.dir",
            DisplayName = "日志目录",
            Description = "运行日志输出目录。排查问题时需要用到其中的日志文件。",
            RecommendedValue = "%USERPROFILE%\\.openclaw\\logs",
            Risk = RiskLevel.Low,
            FieldType = ConfigFieldType.Path,
            DefaultValue = ""
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "基础配置",
            Key = "autostart",
            DisplayName = "开机自启",
            Description = "是否在 Windows 登录后自动启动 OpenClaw gateway 服务。",
            RecommendedValue = "否",
            Risk = RiskLevel.Low,
            FieldType = ConfigFieldType.Boolean,
            DefaultValue = false
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "基础配置",
            Key = "launch.after.install",
            DisplayName = "安装后自动启动",
            Description = "安装完成后是否自动打开 OpenClaw 主界面。",
            RecommendedValue = "是",
            Risk = RiskLevel.Low,
            FieldType = ConfigFieldType.Boolean,
            DefaultValue = true
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "基础配置",
            Key = "log.level",
            DisplayName = "日志级别",
            Description = "控制日志详细程度。debug 记录最多信息，error 只记录错误。生产环境建议 info。",
            RecommendedValue = "info",
            Risk = RiskLevel.Low,
            FieldType = ConfigFieldType.Choice,
            Choices = new[] { "debug", "info", "warn", "error" },
            DefaultValue = "info"
        });

        // ---- 网关 / 网络配置 ----
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "网关 / 网络配置",
            Key = "gateway.host",
            DisplayName = "Gateway Host",
            Description = "网关监听的主机地址。改为 0.0.0.0 可让局域网访问，但有安全风险。",
            RecommendedValue = "127.0.0.1",
            Risk = RiskLevel.High,
            FieldType = ConfigFieldType.Text,
            DefaultValue = "127.0.0.1",
            Validator = delegate(string v)
            {
                if (string.IsNullOrWhiteSpace(v)) return "不能为空";
                return null;
            }
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "网关 / 网络配置",
            Key = "gateway.port",
            DisplayName = "Gateway Port",
            Description = "网关监听的端口号。修改后需要重启 gateway，且 Launcher 会同步使用新端口。",
            RecommendedValue = "18789",
            Risk = RiskLevel.High,
            FieldType = ConfigFieldType.Number,
            DefaultValue = 18789,
            Validator = delegate(string v)
            {
                int port;
                if (!int.TryParse(v, out port)) return "必须为数字";
                if (port < 1 || port > 65535) return "端口范围 1-65535";
                return null;
            }
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "网关 / 网络配置",
            Key = "gateway.bind",
            DisplayName = "是否只监听本机",
            Description = "设为 loopback 时仅允许本机连接（最安全），设为 all 允许任意地址连接。",
            RecommendedValue = "loopback",
            Risk = RiskLevel.High,
            FieldType = ConfigFieldType.Choice,
            Choices = new[] { "loopback", "all" },
            DefaultValue = "loopback"
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "网关 / 网络配置",
            Key = "gateway.healthcheck.url",
            DisplayName = "健康检查地址",
            Description = "用于检测 gateway 是否正常运行的 HTTP 地址。",
            RecommendedValue = "http://127.0.0.1:18789/",
            Risk = RiskLevel.Low,
            FieldType = ConfigFieldType.Text,
            DefaultValue = "http://127.0.0.1:18789/"
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "网关 / 网络配置",
            Key = "gateway.dashboard.url",
            DisplayName = "Dashboard 地址",
            Description = "OpenClaw 控制台 UI 的访问地址。通常由 gateway 自动提供。",
            RecommendedValue = "http://127.0.0.1:18789/",
            Risk = RiskLevel.Low,
            FieldType = ConfigFieldType.Text,
            DefaultValue = "http://127.0.0.1:18789/"
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "网关 / 网络配置",
            Key = "gateway.timeout",
            DisplayName = "超时（秒）",
            Description = "Gateway 请求超时时间。设置过短会导致大模型响应被中断。",
            RecommendedValue = "120",
            Risk = RiskLevel.Medium,
            FieldType = ConfigFieldType.Number,
            DefaultValue = 120,
            Validator = delegate(string v)
            {
                int t;
                if (!int.TryParse(v, out t)) return "必须为数字";
                if (t < 5) return "不建议低于 5 秒";
                return null;
            }
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "网关 / 网络配置",
            Key = "gateway.retry",
            DisplayName = "重试次数",
            Description = "Gateway 请求失败后自动重试的次数。0 表示不重试。",
            RecommendedValue = "2",
            Risk = RiskLevel.Low,
            FieldType = ConfigFieldType.Number,
            DefaultValue = 2,
            Validator = delegate(string v)
            {
                int n;
                if (!int.TryParse(v, out n)) return "必须为数字";
                if (n < 0 || n > 10) return "范围 0-10";
                return null;
            }
        });

        // ---- 运行配置 ----
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "运行配置",
            Key = "gateway.mode",
            DisplayName = "启动模式",
            Description = "local 为本地独立运行；remote 连接远程 gateway。大多数用户选 local。",
            RecommendedValue = "local",
            Risk = RiskLevel.High,
            FieldType = ConfigFieldType.Choice,
            Choices = new[] { "local", "remote" },
            DefaultValue = "local"
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "运行配置",
            Key = "workdir",
            DisplayName = "默认工作目录",
            Description = "OpenClaw 启动时的默认工作目录。用于文件操作的相对路径解析。",
            RecommendedValue = "%USERPROFILE%",
            Risk = RiskLevel.Low,
            FieldType = ConfigFieldType.Path,
            DefaultValue = ""
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "运行配置",
            Key = "gateway.autostart",
            DisplayName = "是否自动拉起 gateway",
            Description = "启动 OpenClaw 时是否自动启动本地 gateway 服务。关闭后需手动启动。",
            RecommendedValue = "是",
            Risk = RiskLevel.Medium,
            FieldType = ConfigFieldType.Boolean,
            DefaultValue = true
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "运行配置",
            Key = "gateway.background",
            DisplayName = "是否后台运行",
            Description = "gateway 是否以后台进程方式运行（无控制台窗口）。",
            RecommendedValue = "是",
            Risk = RiskLevel.Low,
            FieldType = ConfigFieldType.Boolean,
            DefaultValue = true
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "运行配置",
            Key = "tray.enabled",
            DisplayName = "是否显示托盘图标",
            Description = "是否在系统托盘区域显示 OpenClaw 图标。可用于快速访问和退出。",
            RecommendedValue = "是",
            Risk = RiskLevel.Low,
            FieldType = ConfigFieldType.Boolean,
            DefaultValue = true
        });

        // ---- Provider / 接入配置 ----
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "Provider / 接入配置",
            Key = "provider.type",
            DisplayName = "Provider 类型",
            Description = "AI 模型提供商。选择后将自动填充默认模型和 API 地址。",
            RecommendedValue = "OpenAI",
            Risk = RiskLevel.High,
            FieldType = ConfigFieldType.Choice,
            Choices = new[] {
                "Anthropic", "Chutes", "Cloudflare AI Gateway", "Copilot",
                "Custom Provider", "DeepSeek", "fal", "Google", "Hugging Face",
                "Kilo Gateway", "Kimi Coding", "LiteLLM", "Microsoft Foundry",
                "MiniMax", "Mistral AI", "Moonshot",
                "Ollama", "OpenAI", "OpenCode", "OpenRouter",
                "Qianfan", "Qwen (Alibaba Cloud)", "SGLang", "Synthetic",
                "Together AI", "Venice AI", "Vercel AI Gateway", "vLLM",
                "Volcano Engine", "xAI (Grok)", "Xiaomi", "Z.AI"
            },
            DefaultValue = "OpenAI"
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "Provider / 接入配置",
            Key = "provider.api.base",
            DisplayName = "API Base URL",
            Description = "AI 模型 API 的基础地址。使用自建或代理服务时需要修改。",
            RecommendedValue = "https://api.openai.com/v1",
            Risk = RiskLevel.High,
            FieldType = ConfigFieldType.Text,
            DefaultValue = "",
            Validator = delegate(string v)
            {
                if (string.IsNullOrWhiteSpace(v)) return null; // optional
                Uri uri;
                if (!Uri.TryCreate(v, UriKind.Absolute, out uri)) return "必须为有效的 URL";
                return null;
            }
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "Provider / 接入配置",
            Key = "provider.api.key",
            DisplayName = "API Key",
            Description = "AI 模型服务的鉴权密钥。请妥善保管，不要泄露给他人。",
            RecommendedValue = "",
            Risk = RiskLevel.High,
            FieldType = ConfigFieldType.Password,
            DefaultValue = ""
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "Provider / 接入配置",
            Key = "provider.model",
            DisplayName = "模型名称",
            Description = "使用的 AI 模型标识。切换 Provider 后将自动填充推荐模型。",
            RecommendedValue = "gpt-5.4",
            Risk = RiskLevel.Medium,
            FieldType = ConfigFieldType.Text,
            DefaultValue = ""
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "Provider / 接入配置",
            Key = "provider.timeout",
            DisplayName = "请求超时（秒）",
            Description = "向 AI 模型发送请求的超时时间。大模型生成较慢时需适当增大。",
            RecommendedValue = "120",
            Risk = RiskLevel.Medium,
            FieldType = ConfigFieldType.Number,
            DefaultValue = 120,
            Validator = delegate(string v)
            {
                int t;
                if (!int.TryParse(v, out t)) return "必须为数字";
                if (t < 5) return "不建议低于 5 秒";
                return null;
            }
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "Provider / 接入配置",
            Key = "provider.retry",
            DisplayName = "重试策略",
            Description = "请求失败后的最大重试次数。0 表示不重试。",
            RecommendedValue = "2",
            Risk = RiskLevel.Low,
            FieldType = ConfigFieldType.Number,
            DefaultValue = 2,
            Validator = delegate(string v)
            {
                int n;
                if (!int.TryParse(v, out n)) return "必须为数字";
                if (n < 0 || n > 10) return "范围 0-10";
                return null;
            }
        });

        // ---- 高级配置 ----
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "高级配置",
            Key = "env.vars",
            DisplayName = "环境变量映射",
            Description = "自定义传递给 OpenClaw 进程的环境变量，格式: KEY=VALUE（每行一个）。",
            RecommendedValue = "",
            Risk = RiskLevel.High,
            FieldType = ConfigFieldType.Text,
            DefaultValue = ""
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "高级配置",
            Key = "custom.params",
            DisplayName = "自定义参数",
            Description = "传递给 OpenClaw CLI 的额外命令行参数。仅高级用户使用。",
            RecommendedValue = "",
            Risk = RiskLevel.High,
            FieldType = ConfigFieldType.Text,
            DefaultValue = ""
        });
        fields.Add(new ConfigFieldDescriptor
        {
            Section = "高级配置",
            Key = "debug.mode",
            DisplayName = "调试模式",
            Description = "启用后输出详细调试信息到日志和控制台。排查问题时开启。",
            RecommendedValue = "否",
            Risk = RiskLevel.Medium,
            FieldType = ConfigFieldType.Boolean,
            DefaultValue = false
        });

        return fields;
    }
}

// ============================================================================
// Configuration storage — read / write ~/.openclaw/openclaw.json
// ============================================================================

internal sealed class ConfigStore
{
    private static readonly Dictionary<string, string> ProviderTypeToId = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        { "Anthropic", "anthropic" },
        { "DeepSeek", "deepseek" },
        { "Google", "google" },
        { "Mistral AI", "mistral" },
        { "Moonshot", "moonshot" },
        { "OpenAI", "openai" },
        { "OpenRouter", "openrouter" },
        { "Qwen (Alibaba Cloud)", "qwen" },
        { "xAI (Grok)", "xai" },
        { "Z.AI", "zai" }
    };

    private readonly JavaScriptSerializer _serializer;
    private Dictionary<string, object> _data;
    private Dictionary<string, object> _defaults;

    public ConfigStore()
    {
        _serializer = new JavaScriptSerializer();
        _serializer.MaxJsonLength = int.MaxValue;
        _data = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        _defaults = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
    }

    public string ConfigPath
    {
        get
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".openclaw",
                "openclaw.json"
            );
        }
    }

    public string BackupDir
    {
        get
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".openclaw",
                "config-backups"
            );
        }
    }

    public void Load()
    {
        string path = ConfigPath;
        if (File.Exists(path))
        {
            string json = File.ReadAllText(path, Encoding.UTF8);
            object parsed = _serializer.DeserializeObject(json);
            _data = FlattenDictionary(parsed as Dictionary<string, object>);
        }
        else
        {
            _data = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        }
    }

    public void SetDefaults(List<ConfigFieldDescriptor> fields)
    {
        _defaults.Clear();
        foreach (ConfigFieldDescriptor field in fields)
        {
            if (field.DefaultValue != null)
            {
                _defaults[field.Key] = field.DefaultValue;
            }
        }
    }

    public string GetValue(string key)
    {
        object value;
        if (_data.TryGetValue(key, out value) && value != null)
        {
            return value.ToString();
        }

        if (_defaults.TryGetValue(key, out value) && value != null)
        {
            return value.ToString();
        }

        return string.Empty;
    }

    public bool GetBool(string key)
    {
        string v = GetValue(key).ToLowerInvariant();
        return v == "true" || v == "1" || v == "yes";
    }

    public void SetValue(string key, object value)
    {
        _data[key] = value;
    }

    public void Save()
    {
        Dictionary<string, object> flatToSave = new Dictionary<string, object>(_data, StringComparer.OrdinalIgnoreCase);

        // Keep compatibility with recent OpenClaw schema versions.
        MigrateLegacyProviderToModels(flatToSave);
        RemoveSchemaInvalidKeys(flatToSave);

        Dictionary<string, object> nested = UnflattenDictionary(flatToSave);
        string json = FormatJson(_serializer.Serialize(nested));

        string dir = Path.GetDirectoryName(ConfigPath);
        if (!Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }

        File.WriteAllText(ConfigPath, json, new UTF8Encoding(false));

        // Keep in-memory state aligned with what's persisted to disk.
        _data = flatToSave;
    }

    private static void MigrateLegacyProviderToModels(Dictionary<string, object> flat)
    {
        string providerType = GetFlatString(flat, "provider.type");
        string providerModel = GetFlatString(flat, "provider.model");
        string providerBaseUrl = GetFlatString(flat, "provider.api.base");
        string providerApiKey = GetFlatString(flat, "provider.api.key");

        if (string.IsNullOrWhiteSpace(providerType))
        {
            return;
        }

        string providerId;
        if (!ProviderTypeToId.TryGetValue(providerType.Trim(), out providerId))
        {
            providerId = providerType.Trim().ToLowerInvariant().Replace(" ", "-");
        }

        flat["models.mode"] = "merge";

        if (!string.IsNullOrWhiteSpace(providerBaseUrl))
        {
            flat["models.providers." + providerId + ".baseUrl"] = providerBaseUrl.Trim();
        }

        if (!string.IsNullOrWhiteSpace(providerApiKey))
        {
            flat["models.providers." + providerId + ".apiKey"] = providerApiKey.Trim();
        }

        // DeepSeek / OpenAI-compatible providers work best with openai-responses API shape.
        flat["models.providers." + providerId + ".auth"] = "api-key";
        flat["models.providers." + providerId + ".api"] = "openai-responses";

        if (!string.IsNullOrWhiteSpace(providerModel))
        {
            flat["agents.defaults.model"] = providerId + "/" + providerModel.Trim();
        }
    }

    private static void RemoveSchemaInvalidKeys(Dictionary<string, object> flat)
    {
        string[] rootKeys = new[]
        {
            "log", "launch", "autostart", "data", "install", "tray", "workdir", "provider", "debug", "custom"
        };

        for (int i = 0; i < rootKeys.Length; i++)
        {
            string prefix = rootKeys[i] + ".";
            RemoveByExactOrPrefix(flat, rootKeys[i], prefix);
        }

        string[] gatewayKeys = new[]
        {
            "gateway.retry", "gateway.timeout", "gateway.dashboard", "gateway.healthcheck", "gateway.host", "gateway.background", "gateway.autostart"
        };

        for (int i = 0; i < gatewayKeys.Length; i++)
        {
            RemoveByExactOrPrefix(flat, gatewayKeys[i], gatewayKeys[i] + ".");
        }

        // env.vars must be an object in current schema; the form stores string text.
        object envVars;
        if (flat.TryGetValue("env.vars", out envVars) && envVars is string)
        {
            flat.Remove("env.vars");
        }

        object portObj;
        if (flat.TryGetValue("gateway.port", out portObj) && portObj != null)
        {
            int port;
            if (int.TryParse(portObj.ToString(), out port))
            {
                flat["gateway.port"] = port;
            }
        }
    }

    private static void RemoveByExactOrPrefix(Dictionary<string, object> flat, string exact, string prefix)
    {
        List<string> keys = flat.Keys
            .Where(k => string.Equals(k, exact, StringComparison.OrdinalIgnoreCase) || k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            .ToList();

        foreach (string key in keys)
        {
            flat.Remove(key);
        }
    }

    private static string GetFlatString(Dictionary<string, object> flat, string key)
    {
        object value;
        if (!flat.TryGetValue(key, out value) || value == null)
        {
            return string.Empty;
        }

        return value.ToString();
    }

    public string GetRawJson()
    {
        if (File.Exists(ConfigPath))
        {
            return File.ReadAllText(ConfigPath, Encoding.UTF8);
        }

        return "{}";
    }

    public bool SetRawJson(string json)
    {
        try
        {
            object parsed = _serializer.DeserializeObject(json);
            if (parsed is Dictionary<string, object>)
            {
                _data = FlattenDictionary(parsed as Dictionary<string, object>);

                string dir = Path.GetDirectoryName(ConfigPath);
                if (!Directory.Exists(dir))
                {
                    Directory.CreateDirectory(dir);
                }

                File.WriteAllText(ConfigPath, json, new UTF8Encoding(false));
                return true;
            }
        }
        catch
        {
        }

        return false;
    }

    public string CreateSnapshot()
    {
        if (!Directory.Exists(BackupDir))
        {
            Directory.CreateDirectory(BackupDir);
        }

        string timestamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
        string snapshotPath = Path.Combine(BackupDir, "snapshot-" + timestamp + ".json");

        if (File.Exists(ConfigPath))
        {
            File.Copy(ConfigPath, snapshotPath, true);
        }
        else
        {
            File.WriteAllText(snapshotPath, "{}", new UTF8Encoding(false));
        }

        return snapshotPath;
    }

    public string[] GetSnapshots()
    {
        if (!Directory.Exists(BackupDir))
        {
            return new string[0];
        }

        return Directory.GetFiles(BackupDir, "snapshot-*.json")
            .OrderByDescending(f => f)
            .ToArray();
    }

    public bool RestoreSnapshot(string snapshotPath)
    {
        if (!File.Exists(snapshotPath))
        {
            return false;
        }

        string dir = Path.GetDirectoryName(ConfigPath);
        if (!Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }

        File.Copy(snapshotPath, ConfigPath, true);
        Load();
        return true;
    }

    public void RestoreDefaults()
    {
        _data = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        foreach (KeyValuePair<string, object> kvp in _defaults)
        {
            _data[kvp.Key] = kvp.Value;
        }
    }

    public void ExportToFile(string path)
    {
        if (File.Exists(ConfigPath))
        {
            File.Copy(ConfigPath, path, true);
        }
        else
        {
            File.WriteAllText(path, "{}", new UTF8Encoding(false));
        }
    }

    public bool ImportFromFile(string path)
    {
        if (!File.Exists(path))
        {
            return false;
        }

        try
        {
            string json = File.ReadAllText(path, Encoding.UTF8);
            object parsed = _serializer.DeserializeObject(json);
            if (parsed is Dictionary<string, object>)
            {
                CreateSnapshot(); // auto-backup before import
                File.Copy(path, ConfigPath, true);
                Load();
                return true;
            }
        }
        catch
        {
        }

        return false;
    }

    private static Dictionary<string, object> FlattenDictionary(Dictionary<string, object> dict, string prefix = "")
    {
        Dictionary<string, object> result = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        if (dict == null) return result;

        foreach (KeyValuePair<string, object> kvp in dict)
        {
            string key = string.IsNullOrEmpty(prefix) ? kvp.Key : prefix + "." + kvp.Key;
            Dictionary<string, object> nested = kvp.Value as Dictionary<string, object>;
            if (nested != null)
            {
                foreach (KeyValuePair<string, object> inner in FlattenDictionary(nested, key))
                {
                    result[inner.Key] = inner.Value;
                }
            }
            else
            {
                result[key] = kvp.Value;
            }
        }

        return result;
    }

    private static Dictionary<string, object> UnflattenDictionary(Dictionary<string, object> flat)
    {
        Dictionary<string, object> result = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);

        foreach (KeyValuePair<string, object> kvp in flat)
        {
            string[] parts = kvp.Key.Split('.');
            Dictionary<string, object> current = result;

            for (int i = 0; i < parts.Length - 1; i++)
            {
                object existing;
                if (!current.TryGetValue(parts[i], out existing) || !(existing is Dictionary<string, object>))
                {
                    Dictionary<string, object> child = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                    current[parts[i]] = child;
                    current = child;
                }
                else
                {
                    current = (Dictionary<string, object>)existing;
                }
            }

            current[parts[parts.Length - 1]] = kvp.Value;
        }

        return result;
    }

    private static string FormatJson(string json)
    {
        StringBuilder sb = new StringBuilder();
        int indent = 0;
        bool inString = false;
        bool escaped = false;

        foreach (char c in json)
        {
            if (escaped)
            {
                sb.Append(c);
                escaped = false;
                continue;
            }

            if (c == '\\' && inString)
            {
                sb.Append(c);
                escaped = true;
                continue;
            }

            if (c == '"')
            {
                inString = !inString;
                sb.Append(c);
                continue;
            }

            if (inString)
            {
                sb.Append(c);
                continue;
            }

            switch (c)
            {
                case '{':
                case '[':
                    sb.Append(c);
                    sb.AppendLine();
                    indent++;
                    sb.Append(new string(' ', indent * 2));
                    break;
                case '}':
                case ']':
                    sb.AppendLine();
                    indent--;
                    sb.Append(new string(' ', indent * 2));
                    sb.Append(c);
                    break;
                case ',':
                    sb.Append(c);
                    sb.AppendLine();
                    sb.Append(new string(' ', indent * 2));
                    break;
                case ':':
                    sb.Append(c);
                    sb.Append(' ');
                    break;
                default:
                    if (!char.IsWhiteSpace(c))
                    {
                        sb.Append(c);
                    }
                    break;
            }
        }

        return sb.ToString();
    }
}

// ============================================================================
// ConfigFieldControl — renders one config item as a panel
// ============================================================================

internal sealed class ConfigFieldControl : Panel
{
    private readonly ConfigFieldDescriptor _descriptor;
    private readonly Control _inputControl;
    private readonly Label _validationLabel;

    public ConfigFieldControl(ConfigFieldDescriptor descriptor, string currentValue)
    {
        _descriptor = descriptor;

        AutoSize = false;
        Height = 100;
        Dock = DockStyle.Top;
        Padding = new Padding(8, 6, 8, 6);
        Margin = new Padding(0, 0, 0, 1);

        // Row 1: name + risk badge
        Panel headerRow = new Panel { Dock = DockStyle.Top, Height = 22, Padding = Padding.Empty };

        Label nameLabel = new Label
        {
            Text = descriptor.DisplayName,
            Font = new Font("Segoe UI Semibold", 10f, FontStyle.Bold),
            AutoSize = true,
            Location = new Point(0, 0)
        };
        headerRow.Controls.Add(nameLabel);

        Label riskLabel = new Label
        {
            Text = GetRiskText(descriptor.Risk),
            ForeColor = GetRiskColor(descriptor.Risk),
            Font = new Font("Segoe UI", 8f),
            AutoSize = true,
            Location = new Point(nameLabel.PreferredWidth + 12, 3)
        };
        headerRow.Controls.Add(riskLabel);

        // Row 2: description + recommended
        string descText = descriptor.Description;
        if (!string.IsNullOrEmpty(descriptor.RecommendedValue))
        {
            descText += "  [推荐: " + descriptor.RecommendedValue + "]";
        }

        Label descLabel = new Label
        {
            Text = descText,
            ForeColor = Color.FromArgb(100, 100, 100),
            Font = new Font("Segoe UI", 8.5f),
            AutoSize = false,
            Dock = DockStyle.Top,
            Height = 32
        };

        // Row 3: input control
        _inputControl = CreateInputControl(descriptor, currentValue);
        _inputControl.Dock = DockStyle.Top;

        // Row 4: validation
        _validationLabel = new Label
        {
            Text = "",
            ForeColor = Color.Red,
            Font = new Font("Segoe UI", 8f),
            AutoSize = false,
            Dock = DockStyle.Top,
            Height = 16
        };

        Controls.Add(_validationLabel);
        Controls.Add(_inputControl);
        Controls.Add(descLabel);
        Controls.Add(headerRow);

        RunValidation();
    }

    public string Key { get { return _descriptor.Key; } }

    public Control GetInputControl() { return _inputControl; }

    public object GetCurrentValue()
    {
        if (_descriptor.FieldType == ConfigFieldType.Boolean)
        {
            CheckBox cb = _inputControl as CheckBox;
            return cb != null && cb.Checked;
        }

        if (_descriptor.FieldType == ConfigFieldType.Choice)
        {
            ComboBox combo = _inputControl as ComboBox;
            return combo != null ? combo.Text : string.Empty;
        }

        TextBox tb = _inputControl as TextBox;
        return tb != null ? tb.Text : string.Empty;
    }

    public void SetCurrentValue(string value)
    {
        if (_descriptor.FieldType == ConfigFieldType.Boolean)
        {
            CheckBox cb = _inputControl as CheckBox;
            if (cb != null)
            {
                string v = (value ?? "").ToLowerInvariant();
                cb.Checked = v == "true" || v == "1" || v == "yes";
            }
        }
        else if (_descriptor.FieldType == ConfigFieldType.Choice)
        {
            ComboBox combo = _inputControl as ComboBox;
            if (combo != null)
            {
                combo.Text = value ?? "";
            }
        }
        else
        {
            TextBox tb = _inputControl as TextBox;
            if (tb != null)
            {
                tb.Text = value ?? "";
            }
        }

        RunValidation();
    }

    private Control CreateInputControl(ConfigFieldDescriptor desc, string currentValue)
    {
        switch (desc.FieldType)
        {
            case ConfigFieldType.Boolean:
                CheckBox cb = new CheckBox
                {
                    Text = "启用",
                    Height = 24,
                    Font = new Font("Segoe UI", 9.5f),
                    Checked = currentValue.ToLowerInvariant() == "true" || currentValue == "1" || currentValue.ToLowerInvariant() == "yes"
                };
                cb.CheckedChanged += delegate { RunValidation(); OnValueChanged(); };
                return cb;

            case ConfigFieldType.Choice:
                ComboBox combo = new ComboBox
                {
                    DropDownStyle = ComboBoxStyle.DropDownList,
                    Height = 26,
                    Font = new Font("Segoe UI", 9.5f)
                };
                if (desc.Choices != null)
                {
                    combo.Items.AddRange(desc.Choices);
                }
                combo.Text = currentValue;
                combo.SelectedIndexChanged += delegate { RunValidation(); OnValueChanged(); };
                return combo;

            case ConfigFieldType.Password:
                TextBox pwdBox = new TextBox
                {
                    Text = currentValue,
                    UseSystemPasswordChar = true,
                    Height = 26,
                    Font = new Font("Segoe UI", 9.5f)
                };
                pwdBox.TextChanged += delegate { RunValidation(); OnValueChanged(); };
                return pwdBox;

            case ConfigFieldType.Path:
                TextBox pathBox = new TextBox
                {
                    Text = currentValue,
                    Height = 26,
                    Font = new Font("Segoe UI", 9.5f)
                };
                pathBox.TextChanged += delegate { RunValidation(); OnValueChanged(); };
                // Could add browse button; keeping simple for MVP
                return pathBox;

            default:
                TextBox textBox = new TextBox
                {
                    Text = currentValue,
                    Height = 26,
                    Font = new Font("Segoe UI", 9.5f)
                };
                textBox.TextChanged += delegate { RunValidation(); OnValueChanged(); };
                return textBox;
        }
    }

    private void RunValidation()
    {
        if (_descriptor.Validator == null)
        {
            _validationLabel.Text = "";
            return;
        }

        object rawVal = GetCurrentValue();
        string value = rawVal != null ? rawVal.ToString() : "";
        string error = _descriptor.Validator(value);
        _validationLabel.Text = error ?? "";
        _validationLabel.ForeColor = error != null ? Color.Red : Color.Green;

        if (error == null && !string.IsNullOrEmpty(value))
        {
            _validationLabel.Text = "✓ 有效";
            _validationLabel.ForeColor = Color.FromArgb(0, 128, 0);
        }
    }

    private void OnValueChanged()
    {
        if (ValueChanged != null) ValueChanged(this, EventArgs.Empty);
    }

    public event EventHandler ValueChanged;

    private static string GetRiskText(RiskLevel risk)
    {
        switch (risk)
        {
            case RiskLevel.Low: return "● 低风险";
            case RiskLevel.Medium: return "● 中风险";
            case RiskLevel.High: return "● 高风险";
            default: return "";
        }
    }

    private static Color GetRiskColor(RiskLevel risk)
    {
        switch (risk)
        {
            case RiskLevel.Low: return Color.FromArgb(0, 128, 0);
            case RiskLevel.Medium: return Color.FromArgb(200, 150, 0);
            case RiskLevel.High: return Color.FromArgb(200, 0, 0);
            default: return Color.Gray;
        }
    }
}

// ============================================================================
// Main form
// ============================================================================

internal sealed class ConfiguratorForm : Form
{
    // Provider ID → [displayName, defaultModel, defaultBaseUrl]
    private static readonly Dictionary<string, string[]> ProviderDefaults = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
    {
        { "Anthropic", new[] { "Anthropic", "", "" } },
        { "Chutes", new[] { "Chutes", "zai-org/GLM-4.7-TEE", "" } },
        { "Cloudflare AI Gateway", new[] { "Cloudflare AI Gateway", "claude-sonnet-4-5", "" } },
        { "Copilot", new[] { "Copilot", "", "" } },
        { "DeepSeek", new[] { "DeepSeek", "deepseek-chat", "https://api.deepseek.com" } },
        { "fal", new[] { "fal", "fal-ai/flux/dev", "" } },
        { "Google", new[] { "Google", "", "" } },
        { "Hugging Face", new[] { "Hugging Face", "deepseek-ai/DeepSeek-R1", "" } },
        { "Kilo Gateway", new[] { "Kilo Gateway", "kilo/auto", "" } },
        { "Kimi Coding", new[] { "Moonshot AI (Kimi K2.5)", "kimi-code", "" } },
        { "LiteLLM", new[] { "LiteLLM", "claude-opus-4-6", "" } },
        { "Microsoft Foundry", new[] { "Microsoft Foundry", "gpt-5", "" } },
        { "MiniMax", new[] { "MiniMax", "MiniMax-M2.7", "" } },
        { "Mistral AI", new[] { "Mistral AI", "mistral-large-latest", "" } },
        { "Qwen (Alibaba Cloud)", new[] { "Qwen (Alibaba Cloud Model Studio)", "qwen3.5-plus", "" } },
        { "Moonshot", new[] { "Moonshot AI", "kimi-k2.5", "" } },
        { "Ollama", new[] { "Ollama", "", "http://127.0.0.1:11434" } },
        { "OpenAI", new[] { "OpenAI", "gpt-5.4", "https://api.openai.com/v1" } },
        { "OpenCode", new[] { "OpenCode", "claude-opus-4-6", "" } },
        { "OpenRouter", new[] { "OpenRouter", "auto", "" } },
        { "Qianfan", new[] { "Qianfan", "deepseek-v3.2", "" } },
        { "SGLang", new[] { "SGLang", "", "" } },
        { "Synthetic", new[] { "Synthetic", "hf:MiniMaxAI/MiniMax-M2.5", "https://api.synthetic.new/anthropic" } },
        { "Together AI", new[] { "Together AI", "moonshotai/Kimi-K2.5", "" } },
        { "Venice AI", new[] { "Venice AI", "kimi-k2-5", "" } },
        { "Vercel AI Gateway", new[] { "Vercel AI Gateway", "anthropic/claude-opus-4.6", "" } },
        { "vLLM", new[] { "vLLM", "", "" } },
        { "Volcano Engine", new[] { "Volcano Engine", "", "" } },
        { "xAI (Grok)", new[] { "xAI (Grok)", "grok-4", "" } },
        { "Xiaomi", new[] { "Xiaomi", "mimo-v2-flash", "" } },
        { "Z.AI", new[] { "Z.AI", "glm-5", "" } },
        { "Custom Provider", new[] { "Custom Provider", "", "" } },
    };

    private readonly ConfigStore _store;
    private readonly List<ConfigFieldDescriptor> _allFields;
    private readonly Dictionary<string, ConfigFieldControl> _fieldControls;
    private readonly TabControl _tabs;
    private readonly StatusStrip _statusBar;
    private readonly ToolStripStatusLabel _statusLabel;
    private TextBox _rawJsonEditor;
    private bool _dirty;
    private bool _suppressSync;

    public ConfiguratorForm()
    {
        _store = new ConfigStore();
        _allFields = ConfigSchema.GetAllFields();
        _store.SetDefaults(_allFields);
        _fieldControls = new Dictionary<string, ConfigFieldControl>(StringComparer.OrdinalIgnoreCase);

        Text = "配置 OpenClaw";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(800, 600);
        ClientSize = new Size(960, 720);
        BackColor = Color.FromArgb(250, 248, 242);
        Font = new Font("Segoe UI", 9.5f);

        // Menu bar
        MenuStrip menu = new MenuStrip();
        ToolStripMenuItem fileMenu = new ToolStripMenuItem("文件(&F)");
        fileMenu.DropDownItems.Add(new ToolStripMenuItem("保存配置(&S)", null, delegate { SaveConfig(); }) { ShortcutKeys = Keys.Control | Keys.S });
        fileMenu.DropDownItems.Add(new ToolStripSeparator());
        fileMenu.DropDownItems.Add(new ToolStripMenuItem("导出配置...", null, delegate { ExportConfig(); }));
        fileMenu.DropDownItems.Add(new ToolStripMenuItem("导入配置...", null, delegate { ImportConfig(); }));
        fileMenu.DropDownItems.Add(new ToolStripSeparator());
        fileMenu.DropDownItems.Add(new ToolStripMenuItem("退出(&X)", null, delegate { Close(); }) { ShortcutKeys = Keys.Alt | Keys.F4 });
        menu.Items.Add(fileMenu);

        ToolStripMenuItem toolsMenu = new ToolStripMenuItem("工具(&T)");
        toolsMenu.DropDownItems.Add(new ToolStripMenuItem("测试 Gateway 连通性", null, delegate { TestGatewayConnectivity(); }));
        toolsMenu.DropDownItems.Add(new ToolStripMenuItem("检查端口占用", null, delegate { CheckPortUsage(); }));
        toolsMenu.DropDownItems.Add(new ToolStripMenuItem("测试 Provider 连接", null, delegate { TestProviderConnection(); }));
        toolsMenu.DropDownItems.Add(new ToolStripSeparator());
        toolsMenu.DropDownItems.Add(new ToolStripMenuItem("重启 Gateway", null, delegate { RestartGateway(); }));
        menu.Items.Add(toolsMenu);

        ToolStripMenuItem backupMenu = new ToolStripMenuItem("备份与恢复(&B)");
        backupMenu.DropDownItems.Add(new ToolStripMenuItem("创建快照", null, delegate { CreateSnapshot(); }));
        backupMenu.DropDownItems.Add(new ToolStripMenuItem("回滚到上一次快照", null, delegate { RollbackToLastSnapshot(); }));
        backupMenu.DropDownItems.Add(new ToolStripMenuItem("恢复默认配置", null, delegate { RestoreDefaults(); }));
        backupMenu.DropDownItems.Add(new ToolStripSeparator());
        backupMenu.DropDownItems.Add(new ToolStripMenuItem("打开备份目录", null, delegate { OpenBackupDir(); }));
        menu.Items.Add(backupMenu);

        ToolStripMenuItem helpMenu = new ToolStripMenuItem("帮助(&H)");
        helpMenu.DropDownItems.Add(new ToolStripMenuItem("打开配置文件目录", null, delegate { OpenConfigDir(); }));
        helpMenu.DropDownItems.Add(new ToolStripMenuItem("关于", null, delegate { ShowAbout(); }));
        menu.Items.Add(helpMenu);

        MainMenuStrip = menu;

        // Status bar
        _statusBar = new StatusStrip();
        _statusLabel = new ToolStripStatusLabel("就绪");
        _statusBar.Items.Add(_statusLabel);

        // Tabs
        _tabs = new TabControl();
        _tabs.Dock = DockStyle.Fill;
        _tabs.Font = new Font("Segoe UI", 9.5f);

        Controls.Add(_tabs);
        Controls.Add(_statusBar);
        Controls.Add(menu);

        // Load config and build UI
        LoadAndBuildUI();

        FormClosing += HandleFormClosing;
        Shown += delegate { BeginBackgroundProviderDiscovery(); };
    }

    private void LoadAndBuildUI()
    {
        _store.Load();
        _fieldControls.Clear();
        _tabs.TabPages.Clear();

        // Group fields by section
        Dictionary<string, List<ConfigFieldDescriptor>> sections = new Dictionary<string, List<ConfigFieldDescriptor>>();
        foreach (ConfigFieldDescriptor field in _allFields)
        {
            List<ConfigFieldDescriptor> list;
            if (!sections.TryGetValue(field.Section, out list))
            {
                list = new List<ConfigFieldDescriptor>();
                sections[field.Section] = list;
            }

            list.Add(field);
        }

        // Maintain section order
        string[] sectionOrder = new[]
        {
            "基础配置", "网关 / 网络配置", "运行配置", "Provider / 接入配置", "高级配置"
        };

        foreach (string section in sectionOrder)
        {
            List<ConfigFieldDescriptor> fields;
            if (!sections.TryGetValue(section, out fields)) continue;

            TabPage tab = new TabPage(section);
            tab.AutoScroll = true;
            tab.Padding = new Padding(12);
            tab.BackColor = Color.White;

            // Add action buttons for specific sections
            if (section == "网关 / 网络配置")
            {
                Panel buttonPanel = new Panel { Dock = DockStyle.Top, Height = 40, Padding = new Padding(0, 4, 0, 8) };
                Button testBtn = new Button { Text = "测试连通性", Width = 120, Height = 30, Location = new Point(0, 4) };
                testBtn.Click += delegate { TestGatewayConnectivity(); };
                Button portBtn = new Button { Text = "检查端口占用", Width = 120, Height = 30, Location = new Point(130, 4) };
                portBtn.Click += delegate { CheckPortUsage(); };
                buttonPanel.Controls.Add(portBtn);
                buttonPanel.Controls.Add(testBtn);
                tab.Controls.Add(buttonPanel);
            }
            else if (section == "Provider / 接入配置")
            {
                Panel buttonPanel = new Panel { Dock = DockStyle.Top, Height = 40, Padding = new Padding(0, 4, 0, 8) };
                Button testBtn = new Button { Text = "测试连接", Width = 120, Height = 30, Location = new Point(0, 4) };
                testBtn.Click += delegate { TestProviderConnection(); };
                buttonPanel.Controls.Add(testBtn);
                tab.Controls.Add(buttonPanel);
            }

            // Add fields in reverse order (DockStyle.Top stacks bottom-up)
            for (int i = fields.Count - 1; i >= 0; i--)
            {
                ConfigFieldDescriptor field = fields[i];
                string value = _store.GetValue(field.Key);
                ConfigFieldControl control = new ConfigFieldControl(field, value);
                string fieldKey = field.Key;
                control.ValueChanged += delegate
                {
                    if (string.Equals(fieldKey, "provider.type", StringComparison.OrdinalIgnoreCase))
                    {
                        HandleProviderTypeChanged();
                    }
                    MarkDirty();
                };
                tab.Controls.Add(control);
                _fieldControls[field.Key] = control;
            }

            _tabs.TabPages.Add(tab);
        }

        // Raw JSON / Advanced tab
        TabPage advancedTab = new TabPage("原始 JSON");
        advancedTab.Padding = new Padding(12);
        advancedTab.BackColor = Color.White;

        Label rawLabel = new Label
        {
            Text = "直接编辑原始 JSON 配置（与表单模式双向同步）",
            Dock = DockStyle.Top,
            Height = 28,
            Font = new Font("Segoe UI", 9f),
            ForeColor = Color.FromArgb(100, 100, 100)
        };

        Panel rawButtonPanel = new Panel { Dock = DockStyle.Top, Height = 40 };
        Button applyRawBtn = new Button { Text = "应用 JSON 到表单", Width = 140, Height = 30, Location = new Point(0, 4) };
        applyRawBtn.Click += delegate { ApplyRawJsonToForm(); };
        Button refreshRawBtn = new Button { Text = "从表单刷新 JSON", Width = 140, Height = 30, Location = new Point(150, 4) };
        refreshRawBtn.Click += delegate { RefreshRawJsonFromForm(); };
        rawButtonPanel.Controls.Add(refreshRawBtn);
        rawButtonPanel.Controls.Add(applyRawBtn);

        _rawJsonEditor = new TextBox
        {
            Multiline = true,
            Dock = DockStyle.Fill,
            ScrollBars = ScrollBars.Both,
            WordWrap = false,
            Font = new Font("Consolas", 10f),
            AcceptsReturn = true,
            AcceptsTab = true
        };
        _rawJsonEditor.Text = _store.GetRawJson();

        advancedTab.Controls.Add(_rawJsonEditor);
        advancedTab.Controls.Add(rawButtonPanel);
        advancedTab.Controls.Add(rawLabel);
        _tabs.TabPages.Add(advancedTab);

        // Backup & Restore tab
        TabPage backupTab = new TabPage("备份与恢复");
        backupTab.Padding = new Padding(12);
        backupTab.BackColor = Color.White;

        Panel backupButtonPanel = new Panel { Dock = DockStyle.Top, Height = 50 };
        Button exportBtn = new Button { Text = "导出配置", Width = 100, Height = 32, Location = new Point(0, 8) };
        exportBtn.Click += delegate { ExportConfig(); };
        Button importBtn = new Button { Text = "导入配置", Width = 100, Height = 32, Location = new Point(110, 8) };
        importBtn.Click += delegate { ImportConfig(); };
        Button snapshotBtn = new Button { Text = "创建快照", Width = 100, Height = 32, Location = new Point(220, 8) };
        snapshotBtn.Click += delegate { CreateSnapshot(); };
        Button rollbackBtn = new Button { Text = "回滚到上一次", Width = 110, Height = 32, Location = new Point(330, 8) };
        rollbackBtn.Click += delegate { RollbackToLastSnapshot(); };
        Button defaultBtn = new Button { Text = "恢复默认", Width = 100, Height = 32, Location = new Point(450, 8) };
        defaultBtn.Click += delegate { RestoreDefaults(); };
        backupButtonPanel.Controls.Add(defaultBtn);
        backupButtonPanel.Controls.Add(rollbackBtn);
        backupButtonPanel.Controls.Add(snapshotBtn);
        backupButtonPanel.Controls.Add(importBtn);
        backupButtonPanel.Controls.Add(exportBtn);

        ListBox snapshotList = new ListBox
        {
            Dock = DockStyle.Fill,
            Font = new Font("Consolas", 9.5f)
        };

        Label snapshotLabel = new Label
        {
            Text = "已有快照（双击恢复）：",
            Dock = DockStyle.Top,
            Height = 24,
            Font = new Font("Segoe UI", 9.5f)
        };

        string[] snapshots = _store.GetSnapshots();
        foreach (string s in snapshots)
        {
            snapshotList.Items.Add(Path.GetFileName(s));
        }

        snapshotList.DoubleClick += delegate
        {
            if (snapshotList.SelectedItem == null) return;
            string selected = snapshotList.SelectedItem.ToString();
            string fullPath = Path.Combine(_store.BackupDir, selected);
            DialogResult dr = MessageBox.Show(
                "确认恢复到快照 " + selected + "？\n当前配置将自动创建一个快照作为备份。",
                "恢复快照",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Question
            );
            if (dr == DialogResult.Yes)
            {
                _store.CreateSnapshot();
                if (_store.RestoreSnapshot(fullPath))
                {
                    RefreshFormFromStore();
                    SetStatus("已恢复到快照: " + selected);
                }
            }
        };

        backupTab.Controls.Add(snapshotList);
        backupTab.Controls.Add(snapshotLabel);
        backupTab.Controls.Add(backupButtonPanel);
        _tabs.TabPages.Add(backupTab);

        // Bottom save bar
        Panel saveBar = new Panel { Dock = DockStyle.Bottom, Height = 48, Padding = new Padding(12, 8, 12, 8) };
        saveBar.BackColor = Color.FromArgb(245, 243, 237);

        Button saveButton = new Button
        {
            Text = "保存并应用",
            Width = 120,
            Height = 32,
            Location = new Point(12, 8),
            BackColor = Color.FromArgb(0, 120, 212),
            ForeColor = Color.White,
            FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI Semibold", 9.5f, FontStyle.Bold)
        };
        saveButton.FlatAppearance.BorderSize = 0;
        saveButton.Click += delegate { SaveConfig(); };

        Button restartBtn = new Button
        {
            Text = "保存并重启 Gateway",
            Width = 160,
            Height = 32,
            Location = new Point(142, 8),
            Font = new Font("Segoe UI", 9.5f)
        };
        restartBtn.Click += delegate { SaveAndRestartGateway(); };

        Label configPathLabel = new Label
        {
            Text = "配置文件: " + _store.ConfigPath,
            AutoSize = true,
            Location = new Point(316, 14),
            ForeColor = Color.FromArgb(120, 120, 120),
            Font = new Font("Segoe UI", 8.5f)
        };

        saveBar.Controls.Add(configPathLabel);
        saveBar.Controls.Add(restartBtn);
        saveBar.Controls.Add(saveButton);

        Controls.Add(saveBar);

        _dirty = false;
        SetStatus("配置已加载: " + _store.ConfigPath);
    }

    private void MarkDirty()
    {
        _dirty = true;
        if (!Text.EndsWith(" *"))
        {
            Text = "配置 OpenClaw *";
        }
    }

    private void ClearDirty()
    {
        _dirty = false;
        Text = "配置 OpenClaw";
    }

    private void SetStatus(string message)
    {
        _statusLabel.Text = message;
    }

    private void RefreshFormFromStore()
    {
        _suppressSync = true;
        foreach (ConfigFieldDescriptor field in _allFields)
        {
            ConfigFieldControl control;
            if (_fieldControls.TryGetValue(field.Key, out control))
            {
                control.SetCurrentValue(_store.GetValue(field.Key));
            }
        }

        if (_rawJsonEditor != null)
        {
            _rawJsonEditor.Text = _store.GetRawJson();
        }

        _suppressSync = false;
        ClearDirty();
    }

    private void CollectFormToStore()
    {
        foreach (KeyValuePair<string, ConfigFieldControl> kvp in _fieldControls)
        {
            _store.SetValue(kvp.Key, kvp.Value.GetCurrentValue());
        }
    }

    // ---- Save ----

    private void SaveConfig()
    {
        try
        {
            CollectFormToStore();
            _store.Save();

            if (_rawJsonEditor != null)
            {
                _rawJsonEditor.Text = _store.GetRawJson();
            }

            ClearDirty();
            SetStatus("配置已保存: " + DateTime.Now.ToString("HH:mm:ss"));
        }
        catch (Exception ex)
        {
            MessageBox.Show("保存失败: " + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void SaveAndRestartGateway()
    {
        SaveConfig();
        RestartGateway();
    }

    // ---- Export / Import ----

    private void ExportConfig()
    {
        using (SaveFileDialog dlg = new SaveFileDialog())
        {
            dlg.Filter = "JSON 文件|*.json|所有文件|*.*";
            dlg.FileName = "openclaw-config-export.json";
            if (dlg.ShowDialog() == DialogResult.OK)
            {
                try
                {
                    CollectFormToStore();
                    _store.Save();
                    _store.ExportToFile(dlg.FileName);
                    SetStatus("已导出到: " + dlg.FileName);
                }
                catch (Exception ex)
                {
                    MessageBox.Show("导出失败: " + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
        }
    }

    private void ImportConfig()
    {
        using (OpenFileDialog dlg = new OpenFileDialog())
        {
            dlg.Filter = "JSON 文件|*.json|所有文件|*.*";
            if (dlg.ShowDialog() == DialogResult.OK)
            {
                DialogResult dr = MessageBox.Show(
                    "导入将覆盖当前配置。继续前会自动创建一个备份快照。\n确认导入?",
                    "导入配置",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning
                );
                if (dr == DialogResult.Yes)
                {
                    if (_store.ImportFromFile(dlg.FileName))
                    {
                        RefreshFormFromStore();
                        SetStatus("已导入: " + dlg.FileName);
                    }
                    else
                    {
                        MessageBox.Show("导入失败：文件格式无效。", "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    }
                }
            }
        }
    }

    // ---- Snapshots ----

    private void CreateSnapshot()
    {
        try
        {
            CollectFormToStore();
            _store.Save();
            string path = _store.CreateSnapshot();
            SetStatus("已创建快照: " + Path.GetFileName(path));
        }
        catch (Exception ex)
        {
            MessageBox.Show("创建快照失败: " + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void RollbackToLastSnapshot()
    {
        string[] snapshots = _store.GetSnapshots();
        if (snapshots.Length == 0)
        {
            MessageBox.Show("没有可用的快照。", "提示", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        DialogResult dr = MessageBox.Show(
            "确认回滚到 " + Path.GetFileName(snapshots[0]) + "？\n当前配置将自动创建一个新快照。",
            "回滚",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Question
        );

        if (dr == DialogResult.Yes)
        {
            _store.CreateSnapshot();
            if (_store.RestoreSnapshot(snapshots[0]))
            {
                RefreshFormFromStore();
                SetStatus("已回滚到: " + Path.GetFileName(snapshots[0]));
            }
        }
    }

    private void RestoreDefaults()
    {
        DialogResult dr = MessageBox.Show(
            "确认恢复默认配置？\n当前配置将自动创建一个备份快照。",
            "恢复默认",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning
        );

        if (dr == DialogResult.Yes)
        {
            _store.CreateSnapshot();
            _store.RestoreDefaults();
            _store.Save();
            RefreshFormFromStore();
            SetStatus("已恢复默认配置");
        }
    }

    // ---- Raw JSON ----

    private void ApplyRawJsonToForm()
    {
        if (_rawJsonEditor == null) return;

        string json = _rawJsonEditor.Text;
        if (_store.SetRawJson(json))
        {
            _store.Load();
            _suppressSync = true;
            foreach (ConfigFieldDescriptor field in _allFields)
            {
                ConfigFieldControl control;
                if (_fieldControls.TryGetValue(field.Key, out control))
                {
                    control.SetCurrentValue(_store.GetValue(field.Key));
                }
            }
            _suppressSync = false;
            SetStatus("已从 JSON 同步到表单");
        }
        else
        {
            MessageBox.Show("JSON 格式无效，无法同步。", "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    private void RefreshRawJsonFromForm()
    {
        CollectFormToStore();
        _store.Save();
        if (_rawJsonEditor != null)
        {
            _rawJsonEditor.Text = _store.GetRawJson();
        }

        SetStatus("已从表单同步到 JSON");
    }

    // ---- Diagnostics ----

    private void TestGatewayConnectivity()
    {
        string host = "127.0.0.1";
        string portStr = "18789";

        ConfigFieldControl hostCtrl, portCtrl;
        if (_fieldControls.TryGetValue("gateway.host", out hostCtrl))
        {
            object hostVal = hostCtrl.GetCurrentValue();
            host = hostVal != null ? hostVal.ToString() : host;
        }
        if (_fieldControls.TryGetValue("gateway.port", out portCtrl))
        {
            object portVal = portCtrl.GetCurrentValue();
            portStr = portVal != null ? portVal.ToString() : portStr;
        }

        string url = "http://" + host + ":" + portStr + "/";

        SetStatus("正在测试 Gateway 连通性...");
        Cursor = Cursors.WaitCursor;

        Task.Run(delegate
        {
            string result;
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(url);
                request.Timeout = 5000;
                request.Method = "GET";
                using (WebResponse response = request.GetResponse())
                {
                    result = "Gateway 连接成功 (" + url + ")";
                }
            }
            catch (WebException ex)
            {
                if (ex.Response != null)
                {
                    result = "Gateway 已响应（HTTP 错误，但服务在运行）";
                }
                else
                {
                    result = "Gateway 无法连接: " + ex.Message;
                }
            }
            catch (Exception ex)
            {
                result = "测试失败: " + ex.Message;
            }

            BeginInvoke(new Action(delegate
            {
                Cursor = Cursors.Default;
                SetStatus(result);
                MessageBox.Show(result, "Gateway 连通性测试", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }));
        });
    }

    private void CheckPortUsage()
    {
        string portStr = "18789";
        ConfigFieldControl portCtrl;
        if (_fieldControls.TryGetValue("gateway.port", out portCtrl))
        {
            object portVal = portCtrl.GetCurrentValue();
            portStr = portVal != null ? portVal.ToString() : portStr;
        }

        int port;
        if (!int.TryParse(portStr, out port))
        {
            MessageBox.Show("端口值无效。", "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        bool inUse = false;
        string processInfo = "";

        try
        {
            IPGlobalProperties ipProps = IPGlobalProperties.GetIPGlobalProperties();
            IPEndPoint[] listeners = ipProps.GetActiveTcpListeners();
            foreach (IPEndPoint ep in listeners)
            {
                if (ep.Port == port)
                {
                    inUse = true;
                    break;
                }
            }
        }
        catch
        {
        }

        if (inUse)
        {
            // Try to find the process using netstat
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("netstat", "-ano")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true
                };
                using (Process p = Process.Start(psi))
                {
                    string output = p.StandardOutput.ReadToEnd();
                    p.WaitForExit();
                    foreach (string line in output.Split('\n'))
                    {
                        if (line.Contains(":" + port) && line.Contains("LISTENING"))
                        {
                            processInfo = line.Trim();
                            break;
                        }
                    }
                }
            }
            catch
            {
            }

            string msg = "端口 " + port + " 已被占用。";
            if (!string.IsNullOrEmpty(processInfo))
            {
                msg += "\n\n" + processInfo;
            }

            MessageBox.Show(msg, "端口检查", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        else
        {
            MessageBox.Show("端口 " + port + " 当前空闲，可以使用。", "端口检查", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        SetStatus("端口 " + port + (inUse ? " 已占用" : " 空闲"));
    }

    private void TestProviderConnection()
    {
        string apiBase = "";
        string apiKey = "";

        ConfigFieldControl baseCtrl, keyCtrl;
        if (_fieldControls.TryGetValue("provider.api.base", out baseCtrl))
        {
            object baseVal = baseCtrl.GetCurrentValue();
            apiBase = baseVal != null ? baseVal.ToString() : "";
        }
        if (_fieldControls.TryGetValue("provider.api.key", out keyCtrl))
        {
            object keyVal = keyCtrl.GetCurrentValue();
            apiKey = keyVal != null ? keyVal.ToString() : "";
        }

        if (string.IsNullOrWhiteSpace(apiBase))
        {
            MessageBox.Show("请先填写 API Base URL。", "提示", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        string testUrl = apiBase.TrimEnd('/') + "/models";
        SetStatus("正在测试 Provider 连接...");
        Cursor = Cursors.WaitCursor;

        Task.Run(delegate
        {
            string result;
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(testUrl);
                request.Timeout = 10000;
                request.Method = "GET";
                if (!string.IsNullOrWhiteSpace(apiKey))
                {
                    request.Headers["Authorization"] = "Bearer " + apiKey;
                }

                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    result = "Provider 连接成功 (HTTP " + (int)response.StatusCode + ")";
                }
            }
            catch (WebException ex)
            {
                HttpWebResponse resp = ex.Response as HttpWebResponse;
                if (resp != null)
                {
                    int code = (int)resp.StatusCode;
                    if (code == 401 || code == 403)
                    {
                        result = "Provider 已响应，但鉴权失败 (HTTP " + code + ")。请检查 API Key。";
                    }
                    else
                    {
                        result = "Provider 已响应 (HTTP " + code + ")，但返回了错误。";
                    }
                }
                else
                {
                    result = "Provider 无法连接: " + ex.Message;
                }
            }
            catch (Exception ex)
            {
                result = "测试失败: " + ex.Message;
            }

            BeginInvoke(new Action(delegate
            {
                Cursor = Cursors.Default;
                SetStatus(result);
                MessageBox.Show(result, "Provider 连接测试", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }));
        });
    }

    private void RestartGateway()
    {
        SetStatus("正在重启 Gateway...");
        Cursor = Cursors.WaitCursor;

        Task.Run(delegate
        {
            string result;
            try
            {
                string openClawCmd = ResolveOpenClawCommand();
                if (string.IsNullOrEmpty(openClawCmd))
                {
                    result = "找不到 OpenClaw CLI，无法重启 Gateway。";
                }
                else
                {
                    RunCliCommand(openClawCmd, "gateway stop");
                    Thread.Sleep(1500);
                    RunCliCommand(openClawCmd, "gateway start");
                    result = "Gateway 已重启";
                }
            }
            catch (Exception ex)
            {
                result = "重启失败: " + ex.Message;
            }

            BeginInvoke(new Action(delegate
            {
                Cursor = Cursors.Default;
                SetStatus(result);
                MessageBox.Show(result, "重启 Gateway", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }));
        });
    }

    // ---- Helpers ----

    private static string ResolveOpenClawCommand()
    {
        foreach (string candidate in new[] { "openclaw.cmd", "openclaw.exe", "openclaw" })
        {
            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (string segment in path.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    string full = Path.Combine(segment.Trim(), candidate);
                    if (File.Exists(full)) return full;
                }
                catch { }
            }
        }

        string appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        string npmCandidate = Path.Combine(appData, "npm", "openclaw.cmd");
        return File.Exists(npmCandidate) ? npmCandidate : null;
    }

    private static void RunCliCommand(string fileName, string arguments)
    {
        ProcessStartInfo psi = new ProcessStartInfo(fileName, arguments)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        using (Process p = Process.Start(psi))
        {
            p.StandardOutput.ReadToEnd();
            p.StandardError.ReadToEnd();
            p.WaitForExit();
        }
    }

    private void OpenConfigDir()
    {
        string dir = Path.GetDirectoryName(_store.ConfigPath);
        if (Directory.Exists(dir))
        {
            Process.Start("explorer.exe", dir);
        }
    }

    private void OpenBackupDir()
    {
        string dir = _store.BackupDir;
        if (!Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }

        Process.Start("explorer.exe", dir);
    }

    private void ShowAbout()
    {
        MessageBox.Show(
            "OpenClaw 可视化配置工具 v0.1.0\n\n" +
            "用于方便地管理 OpenClaw 的各项配置。\n" +
            "配置文件位置: " + _store.ConfigPath + "\n" +
            "备份目录: " + _store.BackupDir,
            "关于",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information
        );
    }

    private void HandleFormClosing(object sender, FormClosingEventArgs e)
    {
        if (_dirty)
        {
            DialogResult dr = MessageBox.Show(
                "有未保存的更改。是否保存后退出？",
                "配置 OpenClaw",
                MessageBoxButtons.YesNoCancel,
                MessageBoxIcon.Question
            );

            if (dr == DialogResult.Cancel)
            {
                e.Cancel = true;
                return;
            }

            if (dr == DialogResult.Yes)
            {
                SaveConfig();
            }
        }
    }

    // ---- Provider auto-fill ----

    private void HandleProviderTypeChanged()
    {
        if (_suppressSync) return;

        ConfigFieldControl typeCtrl;
        if (!_fieldControls.TryGetValue("provider.type", out typeCtrl)) return;

        object val = typeCtrl.GetCurrentValue();
        string providerType = val != null ? val.ToString() : "";

        string[] defaults;
        if (!ProviderDefaults.TryGetValue(providerType, out defaults)) return;

        string defaultModel = defaults[1];
        string defaultBase = defaults[2];

        ConfigFieldControl modelCtrl;
        if (_fieldControls.TryGetValue("provider.model", out modelCtrl))
        {
            object currentModel = modelCtrl.GetCurrentValue();
            if (currentModel == null || string.IsNullOrWhiteSpace(currentModel.ToString()))
            {
                modelCtrl.SetCurrentValue(defaultModel);
            }
        }

        ConfigFieldControl baseCtrl;
        if (_fieldControls.TryGetValue("provider.api.base", out baseCtrl))
        {
            object currentBase = baseCtrl.GetCurrentValue();
            if (currentBase == null || string.IsNullOrWhiteSpace(currentBase.ToString()))
            {
                if (!string.IsNullOrEmpty(defaultBase))
                {
                    baseCtrl.SetCurrentValue(defaultBase);
                }
            }
        }

        SetStatus("已切换到 " + providerType + (string.IsNullOrEmpty(defaultModel) ? "" : "，推荐模型: " + defaultModel));
    }

    // ---- Background provider discovery from dist ----

    private void BeginBackgroundProviderDiscovery()
    {
        Task.Run(delegate
        {
            try
            {
                string openClawCmd = ResolveOpenClawCommand();
                if (string.IsNullOrWhiteSpace(openClawCmd)) return;

                string cmdDir = Path.GetDirectoryName(openClawCmd);
                if (string.IsNullOrWhiteSpace(cmdDir)) return;

                string extensionsDir = Path.Combine(cmdDir, "node_modules", "openclaw", "dist", "extensions");
                if (!Directory.Exists(extensionsDir)) return;

                List<string> discovered = new List<string>();
                foreach (string dir in Directory.GetDirectories(extensionsDir))
                {
                    string pluginFile = Path.Combine(dir, "openclaw.plugin.json");
                    if (!File.Exists(pluginFile)) continue;

                    try
                    {
                        string json = File.ReadAllText(pluginFile, Encoding.UTF8);
                        JavaScriptSerializer ser = new JavaScriptSerializer();
                        Dictionary<string, object> plugin = ser.Deserialize<Dictionary<string, object>>(json);

                        object authObj;
                        if (!plugin.TryGetValue("providerAuthChoices", out authObj)) continue;

                        object[] authArray = authObj as object[];
                        if (authArray == null) continue;

                        foreach (object item in authArray)
                        {
                            Dictionary<string, object> choice = item as Dictionary<string, object>;
                            if (choice == null) continue;

                            object groupLabel;
                            if (choice.TryGetValue("groupLabel", out groupLabel) && groupLabel != null)
                            {
                                string label = groupLabel.ToString().Trim();
                                if (!string.IsNullOrEmpty(label) && !discovered.Contains(label))
                                {
                                    discovered.Add(label);
                                }
                            }
                        }
                    }
                    catch
                    {
                    }
                }

                if (discovered.Count == 0) return;

                // Merge with existing — add any new providers not already in ProviderDefaults
                List<string> merged = new List<string>(ProviderDefaults.Keys);
                foreach (string name in discovered)
                {
                    if (!ProviderDefaults.ContainsKey(name) && !merged.Contains(name))
                    {
                        merged.Add(name);
                        ProviderDefaults[name] = new[] { name, "", "" };
                    }
                }

                BeginInvoke(new Action(delegate
                {
                    // Update the provider.type combo box with discovered providers
                    ConfigFieldControl typeCtrl;
                    if (_fieldControls.TryGetValue("provider.type", out typeCtrl))
                    {
                        ComboBox combo = typeCtrl.GetInputControl() as ComboBox;
                        if (combo != null)
                        {
                            string current = combo.Text;
                            combo.Items.Clear();
                            combo.Items.AddRange(merged.ToArray());
                            combo.Text = current;
                        }
                    }

                    SetStatus("已从本地 OpenClaw 发现 " + discovered.Count + " 个 Provider");
                }));
            }
            catch
            {
            }
        });
    }
}
