# Windows 安装验证版 GitHub Release 文案

## 建议 Release 标题

`OpenClaw Windows Installer 0.1.9 Beta (Pre-release)`

## 建议 Release 正文

```md
## Windows 安装验证版 / Pre-release

这是一个 **Windows 安装验证版（Pre-release / Beta）**，用于小范围测试真实 Windows 机器上的安装链路。

这次版本不是正式稳定版发布。

当前已确认成立的能力：

- Windows 安装器产物可构建
- 安装失败时可回传第一阶段脱敏 diagnostics summary
- 线上 diagnostics 上传地址可用
- 服务端支持 multipart 上传
- 服务端可返回 `reportId`
- 服务端可创建 GitHub 私有仓库 issue

当前尚未完成确认的部分：

- 真实 Windows 安装失败场景下的失败页展示
- 失败页上的 `reportId` / 错误码 / 本地日志路径展示
- `diagnostics-summary.json` 的实机生成路径
- 上传失败时失败页是否仍能正常显示而不是二次崩溃

当前统一结论：

- **部分通过。正式地址构建、线上上传、`reportId` 回传与 GitHub issue 回流链路已确认成立；但真实 Windows 安装器失败场景下的失败页展示、本地 `diagnostics-summary.json` 生成与日志路径展示，尚缺实机 GUI 证据闭环。**

## 适合谁下载

建议仅限以下用户下载：

- 愿意帮助验证 Windows 安装体验的测试用户
- 愿意在安装失败时回传截图和关键信息的测试用户
- 能接受测试版安装包的内部或小范围外部用户

## 如何安装

1. 下载本次 Windows 安装验证包。
2. 直接运行安装器。
3. 用户不一定需要手动以管理员身份运行安装器；若安装过程涉及提权，按系统提示允许即可。
4. 等待安装完成或失败页出现。

## 安装成功时如何反馈

如果安装成功，请直接回复：

```text
成功
```

如果愿意补充，也可以附上：

- Windows 版本
- 是否已有旧版 OpenClaw
- 是否是首次安装

## 安装失败时如何回传

安装失败时，请优先回传以下内容：

- 失败页截图
- `reportId`
- 错误码
- 本地日志路径
- `diagnostics-summary.json` 路径

如果方便，请再补充：

- `diagnostics-summary.json` 关键字段截图
- 安装日志末尾几行
- 失败前做了什么操作

请使用失败回传模板：

- `docs/windows-installer-failure-feedback-template.md`

## 为什么这些信息重要

本次验证最重要的是补齐真实机器上的失败链路证据，尤其是：

- 失败页是否显示 `reportId`
- 失败页是否显示错误码
- 失败页是否显示本地日志路径
- 本地是否生成 `diagnostics-summary.json`
- 安装器是否自动发起上传

其中，`reportId`、错误码、本地日志路径和 `diagnostics-summary.json` 路径，是定位真实安装失败链路的关键线索。
```