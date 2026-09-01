; MoneyFly Windows 安装包（Inno Setup 6）
; 用法: ISCC.exe /DVERSION=1.0.0 /DBUILD_DIR=C:\...\Release scripts\windows_installer.iss
; 产物: ..\dist\MoneyFly-setup-<VERSION>.exe（相对脚本所在目录）

#ifndef VERSION
  #define VERSION "1.0.0"
#endif
#ifndef BUILD_DIR
  #define BUILD_DIR "..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{B0C9E8F7-4D2A-4C5E-9F1B-6A3D2E7C8B1A}
AppName=MoneyFly
AppVersion={#VERSION}
AppPublisher=top.moneyfly
AppPublisherURL=https://dy.moneyfly.top
DefaultDirName={autopf}\MoneyFly
DefaultGroupName=MoneyFly
; 便携解压为 zip 版；安装版默认不强制管理员（v1 系统代理模式无需提权，
; 后续 TUN 模式需要时改为 requireAdministrator）
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=MoneyFly-setup-{#VERSION}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\moneyfly.exe
; 支持 Windows 10 及以上（Flutter 引擎最低要求，见 README「系统要求」）
MinVersion=10.0

[Languages]
Name: "chinesesimp"; MessagesFile: "languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BUILD_DIR}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\MoneyFly"; Filename: "{app}\moneyfly.exe"
Name: "{group}\{cm:UninstallProgram,MoneyFly}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\MoneyFly"; Filename: "{app}\moneyfly.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\moneyfly.exe"; Description: "{cm:LaunchProgram,MoneyFly}"; Flags: nowait postinstall skipifsilent

[Code]
// 安装前检查残留进程，避免文件占用（可选增强）
function InitializeSetup(): Boolean;
begin
  Result := True;
end;
