# OpenClaw Windows Bootstrap Installer — 架构文档

## 1. 采用 Inno Setup + PowerShell 的原因

| 维度           | 选择理由 |
|---------------|---------|
| 安装入口       | Inno Setup 6 (Unicode) 生成单 EXE，自带提权、UI、安装/卸载注册 |
| 脚本编排       | PowerShell 5.1 (系统自带) 处理所有环境检测、依赖安装、验证逻辑 |
| Unicode        | Inno Setup Unicode + PowerShell UTF-8 全链路，解决中文乱码 |
| 目标用户       | 不要求预装 Node.js / Git / npm / 任何开发工具 |
| 分发方式       | GitHub Release → 用户下载 OpenClawSetup.exe → 双击完成一切 |

## 2. 安装架构

```
┌──────────────────────────────────────────────────┐
│  顶层: Inno Setup 安装器 EXE (OpenClawSetup.exe) │
│  - 安装入口 / UI / 提权 / 文件分发 / 卸载注册    │
├──────────────────────────────────────────────────┤
│  中间层: PowerShell bootstrapper (bootstrap.ps1)  │
│  - 18 阶段事务管理器                              │
│  - 状态持久化 / 错误码传递 / 日志系统              │
├──────────────────────────────────────────────────┤
│  执行层: Step Scripts + Modules                   │
│  ┌────────────────┬──────────────────────────┐   │
│  │ modules/       │ errors.psm1              │   │
│  │                │ logging.psm1             │   │
│  │                │ common.psm1              │   │
│  ├────────────────┼──────────────────────────┤   │
│  │ steps/         │ detect-dependencies.ps1  │   │
│  │                │ install-dependencies.ps1 │   │
│  │                │ install-openclaw.ps1     │   │
│  │                │ create-shortcut.ps1      │   │
│  │                │ remove-residuals.ps1     │   │
│  ├────────────────┼──────────────────────────┤   │
│  │ validation/    │ validate-install.ps1     │   │
│  │                │ test-openclaw-ready.ps1  │   │
│  └────────────────┴──────────────────────────┘   │
└──────────────────────────────────────────────────┘
```

## 3. 目录结构

```
installer/
├── inno/
│   └── OpenClawSetup.iss          # Inno Setup 脚本
├── powershell/
│   ├── bootstrap.ps1              # 主编排器（18 阶段事务）
│   ├── uninstall.ps1              # 卸载入口
│   ├── init.ps1                   # 模块加载器（被 dot-source）
│   ├── modules/
│   │   ├── errors.psm1            # 错误码定义 + 异常工厂
│   │   ├── logging.psm1           # UTF-8 日志 / JSONL / 控制台
│   │   └── common.psm1            # 检测 / 状态 / 进程 / 重试
│   └── steps/
│       ├── detect-dependencies.ps1    # 依赖检测（步骤 5-8）
│       ├── install-dependencies.ps1   # 依赖安装（步骤 9）
│       ├── install-openclaw.ps1       # OpenClaw 安装 + onboarding（步骤 11）
│       ├── create-shortcut.ps1        # 快捷方式（步骤 13）
│       └── remove-residuals.ps1       # 卸载清理
├── validation/
│   ├── validate-install.ps1       # 统一验证（步骤 10/12/15）
│   └── test-openclaw-ready.ps1    # 启动就绪验证
├── resources/
│   ├── manifests/
│   │   └── dependencies.json      # 依赖版本 + URL + SHA256
│   └── upstream/
│       ├── openclaw-install.ps1   # 官方安装脚本（vendored）
│       └── openclaw-install.manifest.json
├── docs/
│   ├── architecture.md            # 本文档
│   └── error-codes.md             # 错误码表
├── logs/
│   └── README.md                  # 运行时日志位置说明
└── shortcuts/
    └── README.md                  # 快捷方式动态创建说明
```

### 目录职责

| 目录                         | 职责 |
|-----------------------------|------|
| `installer/inno/`           | Inno Setup 脚本，编译参数 |
| `installer/powershell/`     | PowerShell 编排层（bootstrap + uninstall + init） |
| `installer/powershell/modules/` | 可复用模块：日志、错误码、公共工具 |
| `installer/powershell/steps/`   | 步骤脚本：每个脚本对应 1-N 个安装阶段 |
| `installer/validation/`     | 安装结果验证脚本 |
| `installer/resources/`      | 构建时生成的依赖 manifest 和官方安装脚本 |
| `installer/docs/`           | 安装工程文档 |
| `installer/logs/`           | 运行时日志位置说明（实际日志在 ProgramData） |
| `installer/shortcuts/`      | 快捷方式相关说明 |

## 4. 安装执行流程（18 阶段）

| 阶段 | StepId           | 脚本/入口                    | 说明 |
|-----|------------------|-----------------------------|------|
| 1   | (Inno)           | OpenClawSetup.iss           | Inno 启动、提权、解压文件 |
| 2   | admin            | bootstrap.ps1 → Assert-Administrator | 确认管理员权限 |
| 3   | logging          | bootstrap.ps1 → Initialize-InstallerSession | 创建日志文件 |
| 4   | system-info      | bootstrap.ps1               | 收集 OS/PS 版本信息 |
| 5   | check-node       | detect-dependencies.ps1     | 检查 Node.js |
| 6   | check-npm        | detect-dependencies.ps1     | 检查 npm |
| 7   | check-git        | detect-dependencies.ps1     | 检查 Git |
| 8   | check-other      | detect-dependencies.ps1     | 检查 WebView2 等 |
| 9   | dep-install      | install-dependencies.ps1    | 下载并安装缺失依赖 |
| 10  | dep-verify       | validate-install.ps1 -Scenario Prerequisites | 验证依赖安装结果 |
| 11  | official-install | install-openclaw.ps1        | npm install + gateway onboarding |
| 12  | official-verify  | validate-install.ps1 -Scenario Installed | 验证 OpenClaw CLI + Launcher |
| 13  | shortcuts        | create-shortcut.ps1         | 桌面 + 开始菜单快捷方式 |
| 14  | launch           | bootstrap.ps1               | 启动 OpenClaw |
| 15  | launch-verify    | validate-install.ps1 -Scenario Launch → test-openclaw-ready.ps1 | 验证窗口出现 |
| 16  | complete         | bootstrap.ps1               | 标记安装完成 |
| 17  | failure          | bootstrap.ps1 (catch)       | 失败处理 |
| 18  | preserve-logs    | bootstrap.ps1 (catch)       | 保留日志和错误码 |

## 5. 日志系统

### 日志文件
- 文本日志: `%ProgramData%\OpenClawInstaller\Logs\install-YYYYMMDD-HHmmss.log`
- 结构化日志 (JSONL): `%ProgramData%\OpenClawInstaller\Logs\install-YYYYMMDD-HHmmss.jsonl`

### 日志格式
```
[2026-03-23 12:00:00] [INFO] [STEP 5:check-node] Node.js: installed=True, version=v24.14.0, meetsMinimum=True
```

### JSONL 字段
```json
{"timestampUtc":"...","level":"INFO","code":"","stepId":"check-node","stepNumber":5,"stepName":"检查 Node.js","message":"...","data":{}}
```

## 6. 编码与乱码修复

| 层级 | 处理方式 |
|------|---------|
| Inno Setup | Unicode 版本，所有文案写在 .iss 中 |
| PowerShell 脚本 | 文件保存为 UTF-8（无 BOM），`Initialize-ConsoleEncoding` 在模块加载时设置 |
| 日志写入 | 使用 `[System.IO.File]::WriteAllText(..., UTF8NoBomEncoding)` |
| 子进程输出 | `ProcessStartInfo.StandardOutputEncoding = UTF8NoBomEncoding` |
| 控制台 | `[Console]::OutputEncoding = UTF8NoBomEncoding` |

## 7. 失败恢复与重复安装

### 策略: Preserve-for-Resume
- 失败时不执行破坏性清理
- 状态文件 (`install-state.json`) 记录每步状态
- 重新运行时可识别已完成步骤
- 参数 `ExistingInstallAction` 支持: Auto / Repair / Overwrite / SkipIfPresent

### 快捷方式补建
- 如果 OpenClaw 已安装但桌面图标缺失，步骤 13 会自动补建

## 8. 验证机制

| 场景 | 验证内容 |
|------|---------|
| Prerequisites | Node.js ≥ v22, npm 可执行, Git 可执行, WebView2 Runtime |
| Installed | 上述 + OpenClaw CLI 存在 + Launcher EXE 存在 |
| Launch | 上述 + 桌面快捷方式存在 + 通过快捷方式启动窗口 + 网关 HTTP 端点可达 |
