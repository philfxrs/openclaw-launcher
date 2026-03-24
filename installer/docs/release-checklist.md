# OpenClaw Windows 发布前清单

## 发布门禁

GitHub 发布不是第一步，只能在以下项目全部完成后执行：

- 本地静态检查通过
- 本地构建通过
- 本机安装/卸载回归通过
- 至少一轮干净 Windows 环境安装通过
- 日志、错误码、中文显示验证通过

## 必须确认项

- `artifacts\installer\OpenClawSetup.exe` 已生成
- `artifacts\launcher\OpenClawLauncher.exe` 已生成
- `installer\resources\manifests\dependencies.json` 已生成
- `installer\resources\upstream\openclaw-install.ps1` 已同步
- 安装失败时界面显示错误码与日志路径
- `%ProgramData%\OpenClawInstaller\Logs\` 中日志可定位问题

## GitHub Release 产物

- `OpenClawSetup.exe`
- 可选：`SHA256SUMS.txt`
- 可选：本地测试报告摘要

## Release 说明必须包含

- 支持系统：Windows 10/11 x64
- 安装器会自动检测并补装 Node.js / Git / WebView2
- 安装失败时请反馈错误码和日志目录
- 如果本地测试未全部通过，不允许创建正式 Release