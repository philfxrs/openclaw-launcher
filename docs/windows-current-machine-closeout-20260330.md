# Windows 本机构建与升级回归 Closeout

日期：2026-03-30

范围：

- 生成当前代码的正式 Configurator、Launcher、Installer EXE
- 在当前开发机执行本机升级安装验证
- 验证安装目录与构建产物一致
- 验证安装状态矩阵、已安装 Configurator smoke、模型区保留回归
- 修复独立 Launcher 直启时的 gateway readiness 超时问题

## 最终结论

本轮结果为：全部通过。

状态汇总：

| 项目 | 结果 | 说明 |
| --- | --- | --- |
| Build / Package | PASS | 正式 Configurator、Launcher、Installer EXE 已生成 |
| Local Upgrade Install | PASS | 静默升级安装返回码 0，安装器完整跑通 |
| Installed File Equivalence | PASS | Program Files 下已安装二进制与本次构建产物哈希一致 |
| Installation State Matrix | PASS | Prerequisites、Installed、Launch 三个场景均通过 |
| Installed Configurator Smoke | PASS | 配置器启动、保存、直启 Launcher、Control UI ready 全部通过 |
| Model-Area Preservation Regression | PASS | models.providers 与 model array 保留验证通过，launcherReady=true |

## 正式产物

| 产物 | 路径 | 大小 | SHA256 |
| --- | --- | ---: | --- |
| Configurator | [../artifacts/configurator/OpenClawConfigurator.exe](../artifacts/configurator/OpenClawConfigurator.exe) | 48640 | `6CD249B9F8F6F67C085F3D49AA323213C41EFDF2F9A6CC5B77705706F609D49B` |
| Launcher | [../artifacts/launcher/OpenClawLauncher.exe](../artifacts/launcher/OpenClawLauncher.exe) | 46080 | `D73A9971A4103C2EF9EEBB51C63E50AF948A164662FA0A9FFFCDDC1EA7C09BF8` |
| Installer | [../artifacts/installer/OpenClawSetup.exe](../artifacts/installer/OpenClawSetup.exe) | 2636014 | `9897C890D4CD21F10B146759BBD4B66918F8E5B218473388226313AAFAB8966C` |

补充说明：安装目录中的 Launcher 与本次正式 Launcher 哈希一致，说明最终修复后的二进制已实际进入 `C:\Program Files\OpenClaw\bin\OpenClawLauncher.exe`。

## 升级安装结果

本机已有一套位于 `C:\Program Files\OpenClaw` 的安装，因此本轮执行的是升级安装验证，而不是首次安装验证。

最终升级安装结果：

- 最新安装器静默升级返回码为 0
- 安装器状态文件记录 `complete=completed`、`launcherValidated=true`
- 安装器日志记录快捷方式创建成功、Launch 验证成功

最终升级安装证据：

- 升级安装日志：[../artifacts/test/upgrade-install-after-launcher-foreground-gateway-fix-20260330-082106.log](../artifacts/test/upgrade-install-after-launcher-foreground-gateway-fix-20260330-082106.log)

## 安装目录一致性验证

Program Files 下落地的二进制与本次正式构建产物逐个比对，结果完全一致。

| 文件 | 构建产物 SHA256 | 已安装文件 SHA256 | 结果 |
| --- | --- | --- | --- |
| OpenClawConfigurator.exe | `6CD249B9F8F6F67C085F3D49AA323213C41EFDF2F9A6CC5B77705706F609D49B` | `6CD249B9F8F6F67C085F3D49AA323213C41EFDF2F9A6CC5B77705706F609D49B` | MATCH |
| OpenClawLauncher.exe | `D73A9971A4103C2EF9EEBB51C63E50AF948A164662FA0A9FFFCDDC1EA7C09BF8` | `D73A9971A4103C2EF9EEBB51C63E50AF948A164662FA0A9FFFCDDC1EA7C09BF8` | MATCH |

这说明：

- 安装器已正确覆盖 Program Files 下的目标二进制
- 本轮升级安装不是“日志成功但文件未替换”的假通过

## 安装状态矩阵

最终重新执行本机安装状态矩阵验证：

- `Prerequisites`：PASS
- `Installed`：PASS
- `Launch`：PASS

矩阵验证与安装器内建 Launch 验证都保持通过，说明修复后的 Launcher 没有破坏原有安装链路。

## Installed Configurator Smoke

对安装后的 Configurator 和 Launcher 做了最终独立 smoke，结果为 PASS。

关键字段：

- `installValidation = PASS`
- `launchValidation = PASS`
- `configuratorLaunch = true`
- `rawJsonApply = true`
- `tokenPersisted = true`
- `portPersisted = true`
- `rawArrayPreserved = true`
- `derivedKeysPersisted = false`
- `systemObjectLeak = false`
- `launcherRuntimeTargetFollowed = true`
- `launcherReady = true`
- `overall = PASS`

证据：

- 已安装 smoke 报告：[../artifacts/test/installed-configurator-smoke-after-launcher-foreground-gateway-fix-20260330-083000.json](../artifacts/test/installed-configurator-smoke-after-launcher-foreground-gateway-fix-20260330-083000.json)

## 模型区保留回归

在最终修复后的已安装版本上重新执行模型区 Raw JSON 保留回归，结果为 PASS。

关键字段：

- `configuratorLaunch = true`
- `saveCompleted = true`
- `tokenPersisted = true`
- `portPersisted = true`
- `modelsProvidersPreserved = true`
- `modelArrayPreserved = true`
- `legacyProviderObjectPresent = false`
- `systemObjectLeak = false`
- `cliValidation = PASS`
- `launcherRuntimeTargetFollowed = true`
- `launcherReady = true`
- `overall = PASS`

证据：

- 模型区保留回归报告：[../artifacts/test/installed-models-raw-json-after-launcher-foreground-gateway-fix-20260330-083159.json](../artifacts/test/installed-models-raw-json-after-launcher-foreground-gateway-fix-20260330-083159.json)

结论：

- `models.providers` 在保存后被正确保留
- model array 在保存后被正确保留
- 没有重新引入旧的 `provider` 根对象
- 没有出现 `System.Object[]` 泄漏
- Launcher 仍然会跟随新的 runtime port，且最终可以走到 ready 状态

## Launcher 问题根因与修复

本轮额外完成了对独立 Launcher 直启超时问题的定位和修复。

根因：

- 直启 Launcher 最初只有 `gateway start` + 轮询可达这一条路径
- 当计划任务式 gateway 启动不稳定时，Launcher 没有像安装验证脚本那样做当前用户会话兜底
- 恢复触发过晚会消耗掉大部分启动预算
- 当前用户会话兜底命令如果使用 `openclaw gateway start`，仍会回到 daemon 路径；已验证可用的兜底命令应为 `openclaw gateway`

修复点：

- Launcher 在短暂首等后即可进入本地恢复，而不是耗尽全部预算后才恢复
- Launcher 读取并复用当前 `gateway.mode` / `gateway.bind`，跳过不必要的配置重写
- Launcher 的当前用户会话兜底改为启动 `openclaw gateway`

最终结果：

- custom port 直启路径下，Launcher 日志已记录 `Gateway endpoint is reachable.`
- 随后成功解析 dashboard URL、完成 WebView2 导航，并记录 `Control UI is ready for use.`
- 该问题已从“已知问题”转为“已修复并验证通过”

## 证据清单

- 正式 Configurator：[../artifacts/configurator/OpenClawConfigurator.exe](../artifacts/configurator/OpenClawConfigurator.exe)
- 正式 Launcher：[../artifacts/launcher/OpenClawLauncher.exe](../artifacts/launcher/OpenClawLauncher.exe)
- 正式 Installer：[../artifacts/installer/OpenClawSetup.exe](../artifacts/installer/OpenClawSetup.exe)
- 最终升级安装日志：[../artifacts/test/upgrade-install-after-launcher-foreground-gateway-fix-20260330-082106.log](../artifacts/test/upgrade-install-after-launcher-foreground-gateway-fix-20260330-082106.log)
- 最终已安装 Configurator smoke：[../artifacts/test/installed-configurator-smoke-after-launcher-foreground-gateway-fix-20260330-083000.json](../artifacts/test/installed-configurator-smoke-after-launcher-foreground-gateway-fix-20260330-083000.json)
- 最终已安装模型区保留回归：[../artifacts/test/installed-models-raw-json-after-launcher-foreground-gateway-fix-20260330-083159.json](../artifacts/test/installed-models-raw-json-after-launcher-foreground-gateway-fix-20260330-083159.json)

## 发布口径建议

如果需要对外或对内同步简版结论，建议统一表述为：

> 2026-03-30 当前代码已完成正式 Windows EXE 构建，并在本机完成一次升级安装与回归验证。安装器升级流程、安装目录文件替换、安装状态矩阵、已安装 Configurator smoke 和模型区 Raw JSON 保留回归均通过。此前独立 Launcher 直启时的 gateway readiness 超时问题已完成根因修复，并在 custom port 场景下验证通过。