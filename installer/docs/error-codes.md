# OpenClaw Installer 错误码表

所有错误码通过 `errors.psm1` 集中定义，在 PowerShell 和 Inno Setup 之间通过
`@@OPENCLAW_ERROR|<code>|<message>` 协议传递。

## 错误码列表

| 错误码 | 分类       | 描述                           | 触发场景 |
|-------|-----------|-------------------------------|---------|
| E1001 | 安装器     | 安装器初始化失败                | bootstrap.ps1 启动异常 |
| E1002 | 安装器     | 管理员权限获取失败              | 非管理员运行 |
| E1003 | 安装器     | 日志初始化失败                  | 无法创建日志目录/文件 |
| E1004 | 安装器     | 系统信息收集失败                | 系统 API 调用异常 |
| E2001 | 依赖检测   | Node.js 检测失败                | 步骤 5 异常 |
| E2002 | 依赖安装   | Node.js 安装失败                | MSI 下载/校验/安装失败 |
| E2003 | 依赖检测   | npm 校验失败                    | npm 安装后仍不可用 |
| E2004 | 依赖检测   | Git 检测失败                    | 步骤 7 异常 |
| E2005 | 依赖安装   | Git 安装失败                    | 下载/校验/安装/超时 |
| E2006 | 依赖安装   | 其他依赖安装失败（含 WebView2）   | WebView2 安装失败等 |
| E3001 | OpenClaw  | OpenClaw 安装失败               | npm install 异常 |
| E3002 | OpenClaw  | OpenClaw 安装后验证失败          | CLI 不存在/Launcher 缺失 |
| E3003 | OpenClaw  | OpenClaw 启动失败               | 启动验证超时/窗口未出现 |
| E4001 | 快捷方式   | 桌面图标创建失败                | .lnk 文件写入失败 |
| E4002 | 快捷方式   | 快捷方式目标无效                | Launcher EXE 不存在 |
| E5001 | 状态管理   | 重复安装状态异常                | 状态文件损坏或版本不兼容 |
| E5002 | 状态管理   | 恢复安装失败                    | 从已有状态恢复时异常 |
| E9001 | 未分类     | 未分类安装失败                  | 未标记错误码的异常 |

## 传递机制

### PowerShell → Inno Setup

bootstrap.ps1 在 catch 块中通过 `Publish-InstallerFailure` 输出：
```
@@OPENCLAW_ERROR|E3001|OpenClaw install script completed, but the openclaw command is not available on PATH.
```

Inno Setup 的 `HandleBootstrapOutput` 回调解析此行，提取 `BootstrapFailureCode` 和 `BootstrapFailureMessage`，
在安装失败对话框中显示：

```
错误码 E3001（执行 OpenClaw 官方安装）

OpenClaw install script completed, but the openclaw command is not available on PATH.
```

### 日志中的错误码

文本日志：
```
[2026-03-23 12:00:00] [ERROR] [E3001] [STEP 11:official-install] OpenClaw install failed.
```

JSONL 日志：
```json
{"timestampUtc":"...","level":"ERROR","code":"E3001","stepId":"official-install","stepNumber":11,...}
```

## 用户指引

安装失败时，请将以下文件发送给开发者：

1. `%ProgramData%\OpenClawInstaller\Logs\install-*.log` — 文本日志
2. `%ProgramData%\OpenClawInstaller\Logs\install-*.jsonl` — 结构化日志
3. `%ProgramData%\OpenClawInstaller\install-state.json` — 安装状态快照
