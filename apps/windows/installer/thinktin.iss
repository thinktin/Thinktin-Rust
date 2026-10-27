; ThinkTin 的 Windows 安装包（Inno Setup 6，docs/windows.md 第 6 节）。
; 由 .github/workflows/windows-release.yml 调用：iscc /DAppVersion=<版本> /DSourceExe=<exe 路径> thinktin.iss
; 装到当前用户的 %LOCALAPPDATA%\Programs\ThinkTin，不要管理员权限。

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceExe
  #define SourceExe "..\..\target\release\thinktin.exe"
#endif

[Setup]
AppId={{6F0C8B6E-5C1D-4F7A-9A58-2C3F8D5E1B21}
AppName=ThinkTin
AppVersion={#AppVersion}
AppVerName=ThinkTin {#AppVersion}
AppPublisher=ThinkTin
AppPublisherURL=https://thinktin.cn
DefaultDirName={localappdata}\Programs\ThinkTin
DefaultGroupName=ThinkTin
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\target\installer
OutputBaseFilename=ThinkTin-Setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=ThinkTin
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "autostart"; Description: "登录 Windows 后在后台启动 ThinkTin / Start ThinkTin in the background when you sign in"; Flags: unchecked

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; DestName: "thinktin.exe"; Flags: ignoreversion

[Icons]
Name: "{group}\ThinkTin"; Filename: "{app}\thinktin.exe"
Name: "{userdesktop}\ThinkTin"; Filename: "{app}\thinktin.exe"; Tasks: autostart

[Registry]
; 和 App 设置里的“开机时在后台启动”写同一个值。
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "ThinkTin"; ValueData: """{app}\thinktin.exe"" --background"; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\thinktin.exe"; Description: "{cm:LaunchProgram,ThinkTin}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "taskkill"; Parameters: "/IM thinktin.exe /F"; Flags: runhidden; RunOnceId: "stop"
