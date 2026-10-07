#define AppVersion "0.1.0"
[Setup]
AppId={{763A4A80-03CE-42DE-9EBD-97AA39A89D6D}
AppName=LumaCaption
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\LumaCaption
DefaultGroupName=LumaCaption
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19045
OutputDir=..\dist
OutputBaseFilename=LumaCaption-{#AppVersion}-windows-x64
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\lumacaption.exe
WizardStyle=modern
[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\LumaCaption"; Filename: "{app}\lumacaption.exe"
Name: "{autodesktop}\LumaCaption"; Filename: "{app}\lumacaption.exe"; Tasks: desktopicon
[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked
[Run]
Filename: "{app}\lumacaption.exe"; Description: "Launch LumaCaption"; Flags: nowait postinstall skipifsilent
