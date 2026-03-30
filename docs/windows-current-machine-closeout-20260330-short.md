# Windows 本机回归短摘要 2026-03-30

可直接用于 PR、Issue 或 Release 说明。

## 一句话结论

2026-03-30 当前代码已完成正式 Windows EXE 构建，并在本机完成升级安装与回归验证；安装器、安装目录二进制一致性、安装状态矩阵、已安装 Configurator smoke、模型区 Raw JSON 保留回归均通过，独立 Launcher 直启时的 gateway readiness 超时问题也已修复并验证通过。

## 核心结果

- 正式产物已生成：Configurator、Launcher、Installer
- Program Files 下已安装 Launcher 与最新构建产物哈希一致
- 本机升级安装返回码 0，安装器 Launch 验证通过
- 已安装 Configurator smoke：`overall = PASS`，`launcherReady = true`
- 已安装模型区回归：`overall = PASS`，`launcherReady = true`

## 关键修复

此次额外修复了独立 Launcher 的启动恢复链路：

- 不再只依赖 `gateway start`
- 恢复触发时机前移，避免超时预算被提前耗尽
- 当前用户会话兜底改为使用已验证可行的 `openclaw gateway`

## 证据

- 长版 closeout：[windows-current-machine-closeout-20260330.md](windows-current-machine-closeout-20260330.md)
- 最终已安装 smoke：[../artifacts/test/installed-configurator-smoke-after-launcher-foreground-gateway-fix-20260330-083000.json](../artifacts/test/installed-configurator-smoke-after-launcher-foreground-gateway-fix-20260330-083000.json)
- 最终模型区回归：[../artifacts/test/installed-models-raw-json-after-launcher-foreground-gateway-fix-20260330-083159.json](../artifacts/test/installed-models-raw-json-after-launcher-foreground-gateway-fix-20260330-083159.json)
- 最终升级安装日志：[../artifacts/test/upgrade-install-after-launcher-foreground-gateway-fix-20260330-082106.log](../artifacts/test/upgrade-install-after-launcher-foreground-gateway-fix-20260330-082106.log)