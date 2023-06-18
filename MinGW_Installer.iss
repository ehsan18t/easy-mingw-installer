#include "Environment.iss"

#ifndef MyAppName
  #define MyAppName "Easy MinGW Installer"
#endif

#ifndef MyAppVersion
  #define MyAppVersion "0.0.1"
#endif

#ifndef SourcePath
  #define SourcePath "C:\mingw64\*"
#endif

[Setup]
AppId={{078C8544-DE40-43A5-B293-58408E30C089}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
;AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
CreateAppDir=no
PrivilegesRequired=admin
OutputBaseFilename="{#MyAppName} v{#MyAppVersion}"
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ChangesEnvironment=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourcePath}"; DestDir: "{sd}\MinGW"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
Name: envPath; Description: "Add to PATH variable" 

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
begin
    if CurStep = ssPostInstall 
     then EnvAddPath(ExpandConstant('{sd}') + '\MinGW\bin');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
    if CurUninstallStep = usPostUninstall
    then EnvRemovePath(ExpandConstant('{sd}') + '\MinGW\bin');
end;
