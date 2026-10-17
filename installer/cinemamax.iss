; Windows-Installer für CinemaMax (Inno Setup 6).
; Wird im GitHub-Build erzeugt:  iscc /DAppVersion=1.6.1 installer\cinemamax.iss
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{F609ADA8-8D75-4A39-BE0B-6884C9BB1AC4}
AppName=CinemaMax
AppVersion={#AppVersion}
AppVerName=CinemaMax {#AppVersion}
AppPublisher=Emre1001
AppPublisherURL=https://emre1001.github.io/CinemaMax/
AppSupportURL=https://github.com/Emre1001/CinemaMax/issues
DefaultDirName={autopf}\CinemaMax
DefaultGroupName=CinemaMax
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\cinemamax.exe
UninstallDisplayName=CinemaMax
SetupIconFile=..\windows\runner\resources\app_icon.ico
OutputDir=..\dist
OutputBaseFilename=CinemaMax-{#AppVersion}-windows-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Ohne Admin-Rechte für den eigenen Benutzer installierbar
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=yes

[Languages]
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "tr"; MessagesFile: "compiler:Languages\Turkish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\CinemaMax"; Filename: "{app}\cinemamax.exe"
Name: "{group}\{cm:UninstallProgram,CinemaMax}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\CinemaMax"; Filename: "{app}\cinemamax.exe"; Tasks: desktopicon

[Registry]
; „Öffnen mit“: Playlists und Videos an CinemaMax übergeben (externe Links/Dateien)
Root: HKA; Subkey: "Software\Classes\CinemaMax.Media"; ValueType: string; ValueName: ""; ValueData: "CinemaMax"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\CinemaMax.Media\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\cinemamax.exe,0"
Root: HKA; Subkey: "Software\Classes\CinemaMax.Media\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\cinemamax.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\.m3u\OpenWithProgids"; ValueType: string; ValueName: "CinemaMax.Media"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.m3u8\OpenWithProgids"; ValueType: string; ValueName: "CinemaMax.Media"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mp4\OpenWithProgids"; ValueType: string; ValueName: "CinemaMax.Media"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mkv\OpenWithProgids"; ValueType: string; ValueName: "CinemaMax.Media"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.ts\OpenWithProgids"; ValueType: string; ValueName: "CinemaMax.Media"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.avi\OpenWithProgids"; ValueType: string; ValueName: "CinemaMax.Media"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.mov\OpenWithProgids"; ValueType: string; ValueName: "CinemaMax.Media"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.webm\OpenWithProgids"; ValueType: string; ValueName: "CinemaMax.Media"; ValueData: ""; Flags: uninsdeletevalue

[Run]
Filename: "{app}\cinemamax.exe"; Description: "{cm:LaunchProgram,CinemaMax}"; Flags: nowait postinstall skipifsilent
