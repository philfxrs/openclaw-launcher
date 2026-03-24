# 快捷方式

桌面和开始菜单快捷方式由 `powershell/steps/create-shortcut.ps1` 在安装流程的步骤 13 动态创建。

快捷方式路径：
- 桌面: `%USERPROFILE%\Desktop\OpenClaw.lnk`
- 开始菜单: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\OpenClaw.lnk`

快捷方式目标: `{app}\bin\OpenClawLauncher.exe`
