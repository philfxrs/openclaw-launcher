# 安装日志

安装日志在运行时生成，保存在：

```
%ProgramData%\OpenClawInstaller\Logs\
```

文件命名规则：
- `install-YYYYMMDD-HHmmss.log` — 文本日志（人类可读）
- `install-YYYYMMDD-HHmmss.jsonl` — 结构化日志（机器可读）
- `uninstall-YYYYMMDD-HHmmss.log` — 卸载日志

所有日志均为 UTF-8 编码（无 BOM）。
