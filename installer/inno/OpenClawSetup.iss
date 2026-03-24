; OpenClawSetup.iss — Inno Setup 6 (Unicode) Bootstrapper
; Packages PowerShell scripts, resources, and launcher into a single EXE.
; On post-install, invokes bootstrap.ps1 which handles dependency detection,
; dependency installation, OpenClaw setup, shortcut creation, and launch.

#define AppName      "OpenClaw"
#define AppVersion   "0.1.0"
#define AppPublisher "OpenClaw"
#define AppExeName   "OpenClawLauncher.exe"

[Setup]
AppId={{7CF1F280-A558-49C9-B1BE-320D4C3CF8E5}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
UninstallDisplayName={#AppName}
DefaultDirName={autopf}\OpenClaw
DefaultGroupName=OpenClaw
UninstallDisplayIcon={app}\bin\{#AppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/ultra64
SolidCompression=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
WizardStyle=modern dynamic
DisableWelcomePage=no
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableReadyMemo=yes
UsePreviousAppDir=no
OutputDir=..\..\artifacts\installer
OutputBaseFilename=OpenClawSetup
SetupLogging=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

; ── Files ────────────────────────────────────────────────────────────────
; Source paths are relative to this .iss file location (installer/inno/)

[Files]
; PowerShell orchestration layer
Source: "..\powershell\*"; DestDir: "{app}\powershell"; Flags: ignoreversion recursesubdirs createallsubdirs

; Validation scripts
Source: "..\validation\*"; DestDir: "{app}\validation"; Flags: ignoreversion recursesubdirs createallsubdirs

; Resources (manifests, upstream installer)
Source: "..\resources\*"; DestDir: "{app}\resources"; Flags: ignoreversion recursesubdirs createallsubdirs

; Compiled launcher + WebView2 DLLs
Source: "..\..\artifacts\launcher\*"; DestDir: "{app}\bin"; Flags: ignoreversion recursesubdirs createallsubdirs

; ── Shortcuts (Inno-managed) ─────────────────────────────────────────────

[Icons]
Name: "{autoprograms}\Uninstall OpenClaw"; Filename: "{uninstallexe}"; Comment: "Uninstall OpenClaw"

; ── Uninstall — calls PowerShell uninstall.ps1 ───────────────────────────

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\powershell\uninstall.ps1"" -InstallRoot ""{app}"" -LauncherPath ""{app}\bin\OpenClawLauncher.exe"" -ShortcutName ""OpenClaw"""; \
  Flags: waituntilterminated runhidden; \
  RunOnceId: "OpenClawCleanup"

; ══════════════════════════════════════════════════════════════════════════
;  Pascal Script — UI, progress, bootstrap invocation
; ══════════════════════════════════════════════════════════════════════════

[Code]
var
  InstallProgressPage: TOutputProgressWizardPage;
  InstallLogMemo: TNewMemo;
  BootstrapResultCode: Integer;
  BootstrapFailureMessage: String;
  BootstrapFailureCode: String;
  BootstrapDidFail: Boolean;

(* ── Log Memo Helper ──────────────────────────────────────────────── *)

procedure AppendInstallLog(const S: String);
begin
  if Trim(S) = '' then
    Exit;

  if InstallLogMemo = nil then
    Exit;

  try
    if InstallLogMemo.Lines.Count > 500 then
      InstallLogMemo.Lines.Delete(0);

    InstallLogMemo.Lines.Add(S);
    WizardForm.Update;
  except
    Log('Bootstrap UI log update failed: ' + GetExceptionMessage);
  end;
end;

(* ── Pipe-delimited field parser ──────────────────────────────────── *)

function PopField(var S: String): String;
var
  P: Integer;
begin
  P := Pos('|', S);
  if P = 0 then begin
    Result := S;
    S := '';
  end else begin
    Result := Copy(S, 1, P - 1);
    Delete(S, 1, P);
  end;
end;

function GetBootstrapLogRoot: String;
begin
  Result := ExpandConstant('{commonappdata}\OpenClawInstaller\Logs');
end;

function LooksLikeUnreadableFailureText(const Value: String): Boolean;
begin
  Result :=
    (Trim(Value) = '') or
    (Pos('�', Value) > 0);
end;

function GetDefaultFailureSummary(const FailureCode: String): String;
begin
  if FailureCode <> '' then
    Result := '错误码 ' + FailureCode + '：安装过程中出现外部命令错误。请查看日志获取详细信息：' + #13#10 + GetBootstrapLogRoot
  else
    Result := 'OpenClaw 安装失败。请查看日志获取详细信息：' + #13#10 + GetBootstrapLogRoot;
end;

function ClampPercent(const Value: Integer): Integer;
begin
  if Value < 0 then
    Result := 0
  else if Value > 100 then
    Result := 100
  else
    Result := Value;
end;

procedure SafeSetInstallProgress(const StageMessage: String; const PercentValue: Integer);
begin
  if InstallProgressPage = nil then
    Exit;

  try
    InstallProgressPage.SetText(StageMessage, '所有安装步骤都在当前窗口内执行，请勿关闭。');
    InstallProgressPage.SetProgress(ClampPercent(PercentValue), 100);
  except
    Log('Bootstrap progress UI update failed: ' + GetExceptionMessage);
  end;
end;

procedure RestoreWizardButtons;
begin
  WizardForm.BackButton.Enabled := True;
  WizardForm.NextButton.Enabled := True;
  WizardForm.CancelButton.Enabled := True;
end;

procedure SafeCloseBootstrapUi;
begin
  RestoreWizardButtons;

  if InstallProgressPage = nil then
    Exit;

  try
    InstallProgressPage.Hide;
  except
    Log('Bootstrap page hide failed: ' + GetExceptionMessage);
  end;
end;

(* ── Stage ID → Chinese caption ──────────────────────────────────── *)

function GetStageCaption(const StageId, DefaultText: String): String;
begin
  { Phase 1 is Inno itself }
  if StageId = 'start' then
    Result := '正在启动 OpenClaw 安装'
  else if StageId = 'admin' then
    Result := '步骤 2/16: 检查管理员权限'
  else if StageId = 'logging' then
    Result := '步骤 3/16: 初始化安装日志'
  else if StageId = 'system-info' then
    Result := '步骤 4/16: 收集系统信息'
  else if StageId = 'check-node' then
    Result := '步骤 5/16: 检查 Node.js'
  else if StageId = 'check-npm' then
    Result := '步骤 6/16: 检查 npm'
  else if StageId = 'check-git' then
    Result := '步骤 7/16: 检查 Git'
  else if StageId = 'check-other' then
    Result := '步骤 8/16: 检查 WebView2 及其他条件'
  else if StageId = 'dep-install' then
    Result := '步骤 9/16: 下载并安装缺失依赖'
  else if StageId = 'dep-verify' then
    Result := '步骤 10/16: 验证依赖安装结果'
  else if StageId = 'official-install' then
    Result := '步骤 11/16: 执行 OpenClaw 官方安装'
  else if StageId = 'official-verify' then
    Result := '步骤 12/16: 验证 OpenClaw 安装结果'
  else if StageId = 'shortcuts' then
    Result := '步骤 13/16: 创建桌面快捷方式'
  else if StageId = 'launch' then
    Result := '步骤 14/16: 自动启动 OpenClaw'
  else if StageId = 'launch-verify' then
    Result := '步骤 15/16: 验证 OpenClaw 启动结果'
  else if StageId = 'complete' then
    Result := '步骤 16/16: OpenClaw 安装完成'
  else if StageId = 'failure' then
    Result := '安装失败，正在整理诊断信息'
  else if StageId = 'preserve-logs' then
    Result := '正在保留日志与错误码'
  else if DefaultText <> '' then
    Result := DefaultText
  else
    Result := '正在执行安装步骤';
end;

(* ── Bootstrap output handler (stdout/stderr callback) ────────────── *)

procedure HandleBootstrapOutput(const S: String; const Error, FirstLine: Boolean);
var
  Line, StageId, PercentText, StageMessage: String;
  PercentValue: Integer;
begin
  Line := Trim(S);
  if Line = '' then
    Exit;

  Log('Bootstrap: ' + Line);

  { ── Error protocol: @@OPENCLAW_ERROR|<code>|<message> ── }
  if Pos('@@OPENCLAW_ERROR|', Line) = 1 then begin
    Delete(Line, 1, Length('@@OPENCLAW_ERROR|'));
    BootstrapFailureCode := PopField(Line);
    BootstrapFailureMessage := Trim(Line);
    if BootstrapFailureCode = '' then
      BootstrapFailureCode := 'E9001';
    if LooksLikeUnreadableFailureText(BootstrapFailureMessage) then
      BootstrapFailureMessage := GetDefaultFailureSummary(BootstrapFailureCode);
    AppendInstallLog('[错误] [' + BootstrapFailureCode + '] ' + BootstrapFailureMessage);
    Exit;
  end;

  { ── Stage protocol: @@OPENCLAW_STAGE|<id>|<percent>|<message> ── }
  if Pos('@@OPENCLAW_STAGE|', Line) = 1 then begin
    Delete(Line, 1, Length('@@OPENCLAW_STAGE|'));
    StageId := PopField(Line);
    PercentText := PopField(Line);
    StageMessage := Trim(Line);
    PercentValue := StrToIntDef(PercentText, 0);
    StageMessage := GetStageCaption(StageId, StageMessage);
    SafeSetInstallProgress(StageMessage, PercentValue);
    AppendInstallLog('[' + StageId + '] ' + StageMessage);
    Exit;
  end;

  { ── General output ── }
  if Error then
    AppendInstallLog('[错误] ' + Line)
  else
    AppendInstallLog(Line);
end;

(* ── Run the bootstrap.ps1 ────────────────────────────────────────── *)

procedure RunOpenClawBootstrap;
var
  Params: String;
begin
  BootstrapResultCode := -1;
  BootstrapFailureMessage := '';
  BootstrapFailureCode := '';
  BootstrapDidFail := False;

  if InstallLogMemo <> nil then begin
    try
      InstallLogMemo.Lines.Clear;
    except
      Log('Bootstrap log clear failed: ' + GetExceptionMessage);
    end;
  end;
  SafeSetInstallProgress('正在准备 OpenClaw 安装环境...', 0);
  if InstallProgressPage <> nil then
    InstallProgressPage.Show;

  WizardForm.BackButton.Enabled := False;
  WizardForm.NextButton.Enabled := False;
  WizardForm.CancelButton.Enabled := False;

  Params :=
    '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' +
    AddQuotes(ExpandConstant('{app}\powershell\bootstrap.ps1')) +
    ' -InstallRoot ' + AddQuotes(ExpandConstant('{app}')) +
    ' -ManifestPath ' + AddQuotes(ExpandConstant('{app}\resources\manifests\dependencies.json')) +
    ' -OfficialScriptPath ' + AddQuotes(ExpandConstant('{app}\resources\upstream\openclaw-install.ps1')) +
    ' -LauncherPath ' + AddQuotes(ExpandConstant('{app}\bin\OpenClawLauncher.exe')) +
    ' -ExistingInstallAction Auto' +
    ' -ShortcutName "OpenClaw"';

  try
    ExecAndLogOutput(
      ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      Params,
      ExpandConstant('{app}'),
      SW_HIDE,
      ewWaitUntilTerminated,
      BootstrapResultCode,
      @HandleBootstrapOutput
    );
  except
    BootstrapDidFail := True;
    SafeCloseBootstrapUi;
    BootstrapFailureMessage := '无法启动 OpenClaw 安装事务: ' + GetExceptionMessage;
    RaiseException(BootstrapFailureMessage);
  end;

  if BootstrapResultCode <> 0 then begin
    BootstrapDidFail := True;
    if LooksLikeUnreadableFailureText(BootstrapFailureMessage) then
      BootstrapFailureMessage := GetDefaultFailureSummary(BootstrapFailureCode);

    if BootstrapFailureCode <> '' then
      BootstrapFailureMessage :=
        '错误码 ' + BootstrapFailureCode + '（' +
        GetStageCaption(BootstrapFailureCode, '') + '）' + #13#10#13#10 +
        BootstrapFailureMessage;

    SafeCloseBootstrapUi;
    RaiseException(BootstrapFailureMessage);
  end;

  SafeSetInstallProgress('OpenClaw 安装完成。', 100);
  Sleep(600);
  SafeCloseBootstrapUi;
end;

(* ── Wizard Initialization ────────────────────────────────────────── *)

procedure InitializeWizard;
begin
  WizardForm.WelcomeLabel1.Caption := '安装 OpenClaw';
  WizardForm.WelcomeLabel2.Caption :=
    '安装器会在当前窗口中显示完整过程，包括环境检测、补装缺失依赖、' +
    '安装 OpenClaw、创建桌面快捷方式与启动验证。' + #13#10#13#10 +
    '整个过程全部自动完成，无需手动操作。';

  InstallProgressPage := CreateOutputProgressPage(
    '正在安装 OpenClaw',
    '安装流程会在此窗口中实时显示。'
  );

  InstallLogMemo := TNewMemo.Create(WizardForm);
  InstallLogMemo.Parent := InstallProgressPage.Surface;
  InstallLogMemo.Left := 0;
  InstallLogMemo.Top := ScaleY(70);
  InstallLogMemo.Width := InstallProgressPage.SurfaceWidth;
  InstallLogMemo.Height := InstallProgressPage.SurfaceHeight - InstallLogMemo.Top;
  InstallLogMemo.ScrollBars := ssVertical;
  InstallLogMemo.ReadOnly := True;
  InstallLogMemo.WordWrap := True;
end;

(* ── Post-install hook — triggers bootstrap ───────────────────────── *)

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep <> ssPostInstall then
    Exit;

  try
    RunOpenClawBootstrap;
  except
    BootstrapDidFail := True;
    SafeCloseBootstrapUi;
    RaiseException(GetExceptionMessage);
  end;
end;

(* ── Finished page text ───────────────────────────────────────────── *)

procedure CurPageChanged(CurPageID: Integer);
begin
  if BootstrapDidFail then
    Exit;

  if CurPageID = wpFinished then begin
    WizardForm.FinishedHeadingLabel.Caption := 'OpenClaw 已安装完成';
    WizardForm.FinishedLabel.Caption :=
      'OpenClaw 已完成安装并通过启动验证。' + #13#10 +
      '你现在可以通过桌面图标启动 OpenClaw。';
  end;
end;
