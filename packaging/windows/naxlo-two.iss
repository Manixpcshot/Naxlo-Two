; Naxlo Two — Inno Setup script (Windows x64 installer)
;
;   & "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" /DMyAppVersion=0.1.0 ^
;       /DEngineBinary=app\assets\engine\windows-amd64\xray\xray.exe packaging\windows\naxlo-two.iss
;
; Kept deliberately plain: no bundled runtime, no service, no scheduled task.
; A proxy client that installs a service is a much bigger promise than this
; project makes, and the engine is a child process the app supervises and kills
; on exit.
;
; Privilege choice: `PrivilegesRequiredOverridesAllowed=dialog` is what makes
; "install per-user, no UAC prompt" possible. TUN mode is the only feature that
; needs machine-wide rights, and the app asks for elevation for that one action
; instead of forcing every install to be elevated.

; Target architecture. ISCC decides the output name, the allowed-arch guards and
; where the built bundle is picked up, so one .iss serves both
;   /DMyAppArch=x64    /DMyAppVersion=0.1.0
;   /DMyAppArch=arm64  /DMyAppVersion=0.1.0
; The default below is only a default: `#ifndef` keeps a command-line define
; authoritative, which is what lets CI build both installers from one script.
#ifndef MyAppArch
  #define MyAppArch "x64"
#endif

#define MyAppName "Naxlo Two"
#define MyAppVersion "0.2.0"
#define MyAppPublisher "Naxlo"
#define MyAppURL "https://github.com/Manixpcshot/Naxlo-Two"
#define MyAppExeName "naxlo_two.exe"
#define BundleId "dev.naxlo.naxloTwo"

#ifndef EngineBinary
  #if MyAppArch == "arm64"
    #define EngineBinary "app\assets\engine\windows-arm64\xray\xray.exe"
  #else
    #define EngineBinary "app\assets\engine\windows-amd64\xray\xray.exe"
  #endif
#endif

[Setup]
AppId={#BundleId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
DefaultDirName={autopf}\NaxloTwo
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
DisableWelcomePage=no
OutputBaseFilename=setup-Naxlo.{#MyAppArch}
OutputDir=installer\Output
SetupIconFile=
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
; An arm64 exe installed on x64 (or the reverse) installs cleanly and fails at
; runtime with a confusing "not a valid Win32 application"; guard it here instead
; of leaving it to the user's error message.
#if MyAppArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
Compression=lzma2/normal
SolidCompression=yes
WizardStyle=modern
; The engine writes config + logs under %AppData%; leaving them alone on
; uninstall is the difference between "I lost my servers" and a clean removal.
; They are only deleted if the user ticks the box below.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "purgeprofiles"; Description: "Delete profiles, server lists and measurement history"; Flags: unchecked

[Files]
Source: "build\windows\{#MyAppArch}\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; The engine binary ships next to the app so the first run does not need network.
; If you built without running scripts/fetch_engine.sh this file is absent and
; Inno fails loudly here, which is the intended outcome: an installer that
; silently ships no engine produces a client that cannot connect and a user who
; has no way to tell those two facts apart.
Source: "{#EngineBinary}"; DestDir: "{app}\engine"; DestName: "xray.exe"; Flags: ignoreversion
#ifdef SingBoxBinary
Source: "{#SingBoxBinary}"; DestDir: "{app}\engine"; DestName: "sing-box.exe"; Flags: ignoreversion skipifsourcedoesntexist
#endif

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Code]
// The app restores the system proxy on clean shutdown, but a machine that loses
// power with a 127.0.0.1 proxy set leaves every browser broken. So the
// uninstaller checks whether the values still look like ours and clears them.
const
  RegPath = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings';

procedure DeinitializeUninstall();
var
  Server: String;
begin
  if RegQueryValue(HKEY_CURRENT_USER, RegPath, 'ProxyServer', Server) then
  begin
    if (Pos('127.0.0.1:20151', Server) > 0) or (Pos('127.0.0.1:20152', Server) > 0) then
    begin
      RegWriteDWordValue(HKEY_CURRENT_USER, RegPath, 'ProxyEnable', 0);
      RegDeleteValue(HKEY_CURRENT_USER, RegPath, 'ProxyServer');
      Log('cleared proxy settings left behind by Naxlo Two');
    end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usPostUninstall) and
     (WizardIsTaskSelected('purgeprofiles') = True) then
  begin
    DelTree(ExpandConstant('{userappdata}\naxlo_two'), True, True, True);
    Log('removed per-profile state and engine binaries');
  end;
end;
