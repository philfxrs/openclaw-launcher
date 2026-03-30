# Windows 安装验证邀请

这是一轮小范围 Windows 安装验证，不是正式大规模发布。

本次主要目标：

- 确认真实机器上的安装成功情况
- 收集真实机器上的安装失败证据
- 补齐失败页、`reportId`、错误码、日志路径和 `diagnostics-summary.json` 的实机证据

请帮我们完成一次安装验证：

1. 下载并运行本次 Windows 安装包。
2. 用户不一定需要手动以管理员身份运行安装器；若安装过程涉及提权，按系统提示允许即可。
3. 如果安装成功，请直接回复：`成功`
4. 如果安装失败，请按模板回传：
   [docs/windows-installer-failure-feedback-template.md](docs/windows-installer-failure-feedback-template.md)

安装失败时，请优先提供：

- 失败页截图
- reportId
- 错误码
- 本地日志路径
- `diagnostics-summary.json` 路径

这轮的重点不是宣传发布，而是帮助我们拿到真实机器上的安装成功/失败证据。感谢配合。