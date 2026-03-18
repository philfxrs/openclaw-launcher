#define AppName "OpenClaw"
#define AppVersion "0.1.0"
#define AppPublisher "OpenClaw"
#define AppExeName "OpenClawLauncher.exe"

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
OutputDir=..\artifacts\installer
OutputBaseFilename=OpenClawSetup
SetupLogging=yes

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\bootstrap\*"; DestDir: "{app}\bootstrap"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\scripts\*"; DestDir: "{app}\scripts"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\resources\*"; DestDir: "{app}\resources"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\artifacts\launcher\*"; DestDir: "{app}\bin"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Uninstall OpenClaw"; Filename: "{uninstallexe}"; Comment: "Uninstall OpenClaw"

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\bootstrap\Uninstall-OpenClaw.ps1"" -InstallRoot ""{app}"" -LauncherPath ""{app}\bin\OpenClawLauncher.exe"" -ShortcutName ""OpenClaw"""; \
  Flags: waituntilterminated runhidden; \
  RunOnceId: "OpenClawCleanup"

[Code]
var
  InstallProgressPage: TOutputProgressWizardPage;
  InstallLogMemo: TNewMemo;
  BootstrapResultCode: Integer;
  BootstrapFailureMessage: String;

procedure AppendInstallLog(const S: String);
begin
  if Trim(S) = '' then
    Exit;

  if InstallLogMemo.Lines.Count > 400 then
    InstallLogMemo.Lines.Delete(0);

  InstallLogMemo.Lines.Add(S);
  WizardForm.Update;
end;

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

function GetStageCaption(const StageId, DefaultText: String): String;
begin
  if StageId = 'start' then
    Result := '正在启动 OpenClaw 安装'
  else if StageId = 'cleanup' then
    Result := '正在清理旧版本和残留配置'
  else if StageId = 'preflight' then
    Result := '正在检查系统环境'
  else if StageId = 'dependencies' then
    Result := '正在安装运行依赖'
  else if StageId = 'official-install' then
    Result := '正在执行 OpenClaw 官方安装'
  else if StageId = 'onboarding' then
    Result := '正在配置本地网关和首次启动'
  else if StageId = 'shortcuts' then
    Result := '正在创建桌面入口'
  else if StageId = 'verification' then
    Result := '正在验证 OpenClaw 窗口'
  else if StageId = 'complete' then
    Result := 'OpenClaw 已安装完成'
  else if DefaultText <> '' then
    Result := DefaultText
  else
    Result := '正在执行安装步骤';
end;

procedure HandleBootstrapOutput(const S: String; const Error, FirstLine: Boolean);
var
  Line, StageId, PercentText, StageMessage: String;
  PercentValue: Integer;
begin
  Line := Trim(S);
  if Line = '' then
    Exit;

  Log('Bootstrap: ' + Line);

  if Pos('@@OPENCLAW_STAGE|', Line) = 1 then begin
    Delete(Line, 1, Length('@@OPENCLAW_STAGE|'));
    StageId := PopField(Line);
    PercentText := PopField(Line);
    StageMessage := Line;
    PercentValue := StrToIntDef(PercentText, 0);
    StageMessage := GetStageCaption(StageId, StageMessage);
    InstallProgressPage.SetText(StageMessage, '所有安装步骤都在当前窗口内执行。');
    InstallProgressPage.SetProgress(PercentValue, 100);
    AppendInstallLog('[' + StageId + '] ' + StageMessage);
    Exit;
  end;

  if Error then
    AppendInstallLog('[error] ' + Line)
  else
    AppendInstallLog(Line);
end;

procedure RunOpenClawBootstrap;
var
  Params: String;
begin
  BootstrapResultCode := -1;
  BootstrapFailureMessage := '';

  InstallLogMemo.Lines.Clear;
  InstallProgressPage.SetText('正在准备 OpenClaw 安装环境...', '请不要关闭此窗口。');
  InstallProgressPage.SetProgress(0, 100);
  InstallProgressPage.Show;

  WizardForm.BackButton.Enabled := False;
  WizardForm.NextButton.Enabled := False;
  WizardForm.CancelButton.Enabled := False;

  Params :=
    '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' +
    AddQuotes(ExpandConstant('{app}\bootstrap\Install-OpenClaw.ps1')) +
    ' -InstallRoot ' + AddQuotes(ExpandConstant('{app}')) +
    ' -ManifestPath ' + AddQuotes(ExpandConstant('{app}\resources\manifests\dependencies.json')) +
    ' -OfficialScriptPath ' + AddQuotes(ExpandConstant('{app}\resources\upstream\openclaw-install.ps1')) +
    ' -LauncherPath ' + AddQuotes(ExpandConstant('{app}\bin\OpenClawLauncher.exe')) +
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
    BootstrapFailureMessage := '无法启动 OpenClaw 安装事务: ' + GetExceptionMessage;
    RaiseException(BootstrapFailureMessage);
  end;

  if BootstrapResultCode <> 0 then begin
    BootstrapFailureMessage :=
      'OpenClaw 安装失败。请查看日志: ' +
      ExpandConstant('{commonappdata}\OpenClawInstaller\Logs');
    RaiseException(BootstrapFailureMessage);
  end;

  InstallProgressPage.SetText('OpenClaw 安装完成。', '正在切换到完成页面。');
  InstallProgressPage.SetProgress(100, 100);
  Sleep(600);
  InstallProgressPage.Hide;
end;

procedure InitializeWizard;
begin
  WizardForm.WelcomeLabel1.Caption := '安装 OpenClaw';
  WizardForm.WelcomeLabel2.Caption :=
    '安装器会在当前窗口中显示完整过程，包括清理旧版本、检查环境、安装 OpenClaw、本地网关初始化与启动验证。';

  InstallProgressPage := CreateOutputProgressPage('正在安装 OpenClaw', '真实安装流程会在此窗口中实时显示。');

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

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    RunOpenClawBootstrap;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then begin
    WizardForm.FinishedHeadingLabel.Caption := 'OpenClaw 已安装完成';
    WizardForm.FinishedLabel.Caption :=
      'OpenClaw 已完成真实安装并已通过启动验证。你现在可以直接使用桌面图标启动它。';
  end;
end;


