# Windows 安装失败回传模板

请尽量按下面模板填写。没有的内容可以写“未确认”或“拿不到”。

## 基本信息

- 安装结果：成功 / 失败
- Windows 版本：
- 机器架构：x64 / 其他 / 未确认
- 是否已有旧版 OpenClaw：是 / 否 / 不确定
- 是否是首次安装：是 / 否 / 不确定
- 是否手动管理员启动：是 / 否 / 不确定
- 安装过程中是否出现 UAC 提权提示：是 / 否 / 不确定
- 安装前做了什么操作：

## 失败页信息

- 失败页截图：
- reportId：
- 错误码：
- 本地日志路径：
- 失败页主提示原文：

## diagnostics-summary.json 信息

- diagnostics-summary.json 路径：
- 文件是否存在：是 / 否 / 未确认
- 文件是否可打开：是 / 否 / 未确认
- 是否看起来已脱敏：是 / 否 / 未确认
- diagnostics-summary.json 内容截图（可选）：

建议至少确认这些字段是否能看到：

- `installerVersion`
- `buildVersion`
- `timestampUtc`
- `errorCode`
- `errorMessage`
- `failedStep`
- `dependencies`
- `installationState`

## 上传结果

- 是否看到安装器自动尝试回传：是 / 否 / 不确定
- 是否需要手动操作上传：是 / 否 / 不确定
- 如果失败页中出现 `reportId`，是否可以确认安装器没有要求你手动上传：是 / 否 / 不确定
- 若失败页上有 `reportId`，请填写：
  - reportId：

## 补充材料（可选）

- 安装日志末尾几行：
- 其他截图：
- 其他补充说明：

## 回传重点提醒

如果只能提供最少信息，请至少回传以下 5 项：

- 失败页截图
- reportId
- 错误码
- 本地日志路径
- diagnostics-summary.json 路径