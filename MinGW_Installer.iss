#include "inno\Environment.iss"

#define MyAppPublisher "Ehsan"
#define MyAppURL "https://ehsan.pages.dev"

#ifndef MyAppName
  #define MyAppName "Easy MinGW Installer"
#endif

#ifndef MyAppVersion
  #define MyAppVersion "0.0.1"
#endif

#ifndef Arch
  #define Arch "64"
#endif

#ifndef SourcePath
  #error "SourcePath not defined!"
#endif

[Setup]
AppId={{078C8544-DE40-43A5-B293-58408E30C089}
AppName={#MyAppName}
SetupIconFile="assets\icon{#Arch}.ico"
UninstallDisplayIcon="{sd}\MinGW{#Arch}\icon{#Arch}.ico"
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
CreateAppDir=no
PrivilegesRequired=admin
OutputDir={#OutputPath}
OutputBaseFilename="{#MyAppName} v{#MyAppVersion} ({#Arch}-bit)"
Compression=lzma2/ultra64  
SolidCompression=yes
WizardStyle=modern
ChangesEnvironment=yes
InfoBeforeFile="{#SourcePath}\version_info.txt"
DisableDirPage=auto
DisableProgramGroupPage=auto

[Languages]
Name: "english"; MessagesFile: "inno\lang\English.isl"

[Files]
Source: "{#SourcePath}\*"; DestDir: "{sd}\MinGW{#Arch}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "assets\icon{#Arch}.ico"; DestDir: "{sd}\MinGW{#Arch}";

[Code]
procedure ExitProcess(uExitCode: Integer);
  external 'ExitProcess@kernel32.dll stdcall';

procedure UninstallExistingVersion;
begin
  if DirExists(ExpandConstant('{sd}') + '\MinGW{#Arch}') then
  begin
    DelTree(ExpandConstant('{sd}') + '\MinGW{#Arch}', True, True, True);
  end;
end;

procedure CheckForExistingInstallation;
var
  UserResponse: Integer;
begin
  if DirExists(ExpandConstant('{sd}') + '\MinGW{#Arch}') then
  begin
    UserResponse := MsgBox('A version of Easy MinGW Installer is already installed. It will be uninstalled to proceed. Do you want to continue?', mbConfirmation, MB_YESNO);
    if UserResponse = IDYES then
    begin
      UninstallExistingVersion;
    end
    else
    begin
      WizardForm.Close;
      ExitProcess(0);
    end;
  end;
end;

procedure InitializeWizard();
begin
  CheckForExistingInstallation;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    EnvAddPath(ExpandConstant('{sd}') + '\MinGW{#Arch}\bin');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    EnvRemovePath(ExpandConstant('{sd}') + '\MinGW{#Arch}\bin');
  end;
end;
