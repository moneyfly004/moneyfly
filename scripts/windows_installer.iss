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
; 注意：**不能加 skipifsilent**。应用内「重启即更新」用的是 /SILENT 静默安装，
; 加了 skipifsilent 装完就不会拉起 App —— 用户看到的就是「升级装完了但程序没回来」
; （旧版本还停在后台/或窗口消失）。nowait 让安装器立刻返回，不阻塞收尾。
Filename: "{app}\moneyfly.exe"; Description: "{cm:LaunchProgram,MoneyFly}"; Flags: nowait postinstall

; ===== 卸载彻底：删除应用数据残留 =====
; path_provider 在 Windows 上：支持目录 %APPDATA%\top.moneyfly\MoneyFly、
; 缓存目录 %LOCALAPPDATA%\top.moneyfly\MoneyFly；mihomo 内核工作目录在
; 系统临时目录 moneyfly_core。卸载时一并删除，保证重装后为全新状态
; （重新登录 + 重新拉取订阅），不沿用旧订阅/节点配置 ——
; 与客户端首启 install_id 检测互为兜底。
[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\top.moneyfly\MoneyFly"
Type: filesandordirs; Name: "{localappdata}\top.moneyfly\MoneyFly"
Type: filesandordirs; Name: "{localappdata}\Temp\moneyfly_core"

[Code]
// 升级安装时先结束正在运行的旧版本：/CLOSEAPPLICATIONS 靠 Restart Manager，
// 个别环境下拿不到句柄就替换失败，这里兜一层 taskkill（没在跑时它返回非零，无害）。
//
// ⚠️ 位置很重要：**绝不能放在 InitializeSetup 里**。Inno 的 {app} 等常量在
// 向导初始化阶段还没赋值，那里展开会直接抛
//   "An attempt was made to expand the "app" constant before it was initialized"
// 并中断安装（2.2.14 的真实事故：所有 Windows 用户装到 1:56 就报这个错）。
// PrepareToInstall 是「安装目录已确定、文件还没开始复制」的时机，
// 普通安装与 /SILENT 静默安装都会走到这里。
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Exec('taskkill.exe', '/f /im moneyfly.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := '';
end;
