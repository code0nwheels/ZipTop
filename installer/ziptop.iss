; ZipTop Windows installer (Inno Setup 6).
;
; Build with tool\build_installer.ps1, which makes the release build, adds
; the Visual C++ runtime DLLs and passes the versions in:
;   ISCC /DAppVersion=1.2.0-dev.14 /DFileVersion=1.2.0.14 installer\ziptop.iss
;
; Installs per user (no administrator prompt), so the self-updater can run
; a new installer without elevation.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
; Four plain numbers, as Windows requires.
#ifndef FileVersion
  #define FileVersion "0.0.0.0"
#endif
#define AppName "ZipTop"
#define AppExe "ziptop.exe"
#define BuildDir "..\build\windows\x64\runner\Release"

[Setup]
; Never change AppId: it is how an update finds the existing installation.
AppId={{6C0B5E3A-2F4D-4B7E-9C1A-5D2E8F0A7B31}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=ZipStreams
VersionInfoVersion={#FileVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=output
OutputBaseFilename=ZipTop-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Lets an update replace a running ZipTop: Setup asks it to close first.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; The self-updater runs Setup with /VERYSILENT, so this must not be
; skipifsilent: a silent install starts ZipTop again; a normal one offers it.
Filename: "{app}\{#AppExe}"; Description: "Start {#AppName}"; Flags: nowait postinstall

[Registry]
; "Start with Windows" is switched on inside the app. If it was on, point it
; at this installation; either way remove it on uninstall.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "ZipTop"; ValueData: """{app}\{#AppExe}"" --minimized"; Flags: uninsdeletevalue; Check: StartWithWindowsWasOn

[Code]
function StartWithWindowsWasOn: Boolean;
begin
  Result := RegValueExists(HKEY_CURRENT_USER,
    'Software\Microsoft\Windows\CurrentVersion\Run', 'ZipTop');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(HKEY_CURRENT_USER,
      'Software\Microsoft\Windows\CurrentVersion\Run', 'ZipTop');
end;
