# Windows 安装验证发布说明

## 定位

这次不是正式大规模发布，而是一轮 GitHub Windows 安装验证版发布。

建议对外发布方式：

- GitHub Pre-release
- Beta / 验证版
- 小范围测试下载

当前已经确认的部分：

- 安装器已按正式地址重新构建
- 失败摘要上传地址已接入 `https://mingos.cc/installer-diagnostics`
- 服务端可以接收脱敏 diagnostics summary
- 服务端可以创建 GitHub 私有仓库 issue
- 服务端可以返回 `reportId`

当前还缺少的，不是服务端能力，而是真实 Windows 机器上的安装失败链路实机证据。

本次验证发布的核心目标是：

- 收集真实机器上的安装成功证据
- 收集真实机器上的安装失败证据
- 尤其补齐失败页、`reportId`、错误码、本地日志路径、`diagnostics-summary.json` 路径这组实机证据

当前统一结论仍然是：

- 部分通过，缺少真实 Windows 安装器失败场景的实机 GUI 证据闭环

这意味着本次发布的目标不是承诺“稳定可用”，而是尽快收集：

- 真实机器上的安装成功反馈
- 真实机器上的安装失败证据
- 失败链路中的 GUI 级证据

## 下载与安装

请下载本次提供的 Windows 安装验证包并直接运行。

用户不一定需要手动以管理员身份运行安装器；若安装过程涉及提权，按系统提示允许即可。

建议只面向以下测试用户发出：

- 能接受测试版安装包的内部或小范围外部用户
- 愿意在失败时回传截图和关键信息的测试用户
- 愿意帮助确认 Windows 实机安装结果的用户

本轮验证重点不是让所有人都必须安装成功，而是帮助我们确认：

- 安装成功链路在真实机器上是否稳定
- 安装失败时失败页是否正常展示
- 失败摘要是否能自动回传

## 用户需要做什么

请按下面流程执行：

1. 下载并运行本次 Windows 安装验证包。
2. 若系统提示提权，按提示允许。
3. 等待安装完成或失败页出现。
4. 安装成功时，直接回复“成功”即可。
5. 安装失败时，请按 [docs/windows-installer-failure-feedback-template.md](docs/windows-installer-failure-feedback-template.md) 回传信息。

## 成功时如何反馈

如果安装成功，请只回复一条最短反馈：

```text
成功
```

如果愿意补充，可附加：

- Windows 版本
- 是否已有旧版 OpenClaw
- 是否是首次安装
- 是否出现过 UAC 提权提示

## 失败时必须回传什么

安装失败时，请优先回传以下关键信息：

- 失败页截图
- 失败页上的 `reportId`
- 失败页上的错误码
- 失败页上的本地日志路径
- `diagnostics-summary.json` 的实际路径
- `diagnostics-summary.json` 是否存在、可打开

如果方便，请再补充：

- `diagnostics-summary.json` 关键字段截图
- 安装日志末尾几行
- 失败前做了什么操作
- 是否出现 UAC 提权提示

## 为什么这些信息重要

本轮最重要的不是泛泛描述“安装失败了”，而是以下证据是否能在真实机器上闭环出现：

- 失败页是否显示 `reportId`
- 失败页是否显示错误码
- 失败页是否显示本地日志路径
- 本地是否生成脱敏后的 `diagnostics-summary.json`
- 安装器是否会自动发起上传

其中，`reportId`、错误码、本地日志路径和 `diagnostics-summary.json` 路径，是我们定位真实失败链路的核心线索。

## GitHub 发布口径

这次 GitHub Release 应明确标记为：

- Pre-release
- Beta
- Windows 安装验证版

不要将这次版本描述为正式稳定版，也不要把当前状态写成“完整通过”。

推荐统一表述：

- 部分通过。正式地址构建、线上上传、`reportId` 回传与 GitHub issue 回流链路已确认成立；但真实 Windows 安装器失败场景下的失败页展示、本地 `diagnostics-summary.json` 生成与日志路径展示，尚缺实机 GUI 证据闭环。

## 失败回传入口

请使用模板：

- [docs/windows-installer-failure-feedback-template.md](docs/windows-installer-failure-feedback-template.md)

## 测试用户简短通知

对外发送时可配合使用：

- [docs/windows-installer-test-invite.md](docs/windows-installer-test-invite.md)