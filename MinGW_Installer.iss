#include "inno\Environment.iss"

#define MyAppPublisher "Ehsan"
#define MyAppURL "https://ehsan.pages.dev"

#ifndef MyAppName
  #define MyAppName "Easy MinGW Installer"
#endif

#ifndef MyOutputName
  #define MyOutputName MyAppName
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
OutputBaseFilename="{#MyOutputName}.v{#MyAppVersion}.{#Arch}-bit"
Compression=lzma2/ultra64  
SolidCompression=yes
WizardStyle=modern
ChangesEnvironment=yes
InfoBeforeFile="{#SourcePath}\version_info.txt"
DisableWelcomePage=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes

[Languages]
Name: "english"; MessagesFile: "inno\lang\English.isl"

[Files]
Source: "{#SourcePath}\*"; DestDir: "{sd}\MinGW{#Arch}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "assets\icon{#Arch}.ico"; DestDir: "{sd}\MinGW{#Arch}";

[Code]
const
  { Auto-click constants for skipping pages }
  BN_CLICKED = 0;
  WM_COMMAND = $0111;
  CN_BASE = $BC00;
  CN_COMMAND = CN_BASE + WM_COMMAND;

var
  SkipInfoPage: Boolean;
  MinGWDir: string;    { Initialized in InitializeSetup }
  MinGWBinDir: string; { Initialized in InitializeSetup }

function InitializeSetup: Boolean;
begin
  MinGWDir := ExpandConstant('{sd}\MinGW{#Arch}');
  MinGWBinDir := MinGWDir + '\bin';
  Result := True;
end;

procedure UninstallExistingVersion;
begin
  if DirExists(MinGWDir) then
    DelTree(MinGWDir, True, True, True);
end;

procedure CheckForExistingInstallation;
begin
  if DirExists(MinGWDir) then
  begin
    if MsgBox('A version of Easy MinGW Installer is already installed. ' +
              'It will be uninstalled to proceed. Do you want to continue?',
              mbConfirmation, MB_YESNO) = IDYES then
    begin
      UninstallExistingVersion;
      SkipInfoPage := True;
    end
    else
      Abort; { Cancel installation }
  end;
end;

procedure InitializeWizard;
begin
  CheckForExistingInstallation;
  WizardForm.InfoBeforeClickLabel.Hide;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Param: Longint;
begin
  if SkipInfoPage and (CurPageID = wpInfoBefore) then
  begin
    Param := 0 or BN_CLICKED shl 16;
    PostMessage(WizardForm.NextButton.Handle, CN_COMMAND, Param, 0);
  end;

  if CurPageID = wpReady then
  begin
    Param := 0 or BN_CLICKED shl 16;
    PostMessage(WizardForm.NextButton.Handle, CN_COMMAND, Param, 0);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    EnvAddPath(MinGWBinDir);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    EnvRemovePath(ExpandConstant('{sd}\MinGW{#Arch}\bin'));
end;
