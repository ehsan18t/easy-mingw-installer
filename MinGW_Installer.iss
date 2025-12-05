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
WizardStyle=modern dynamic
ChangesEnvironment=yes
InfoBeforeFile="{#SourcePath}\version_info.txt"
DisableWelcomePage=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
; Custom string overrides
ButtonNext=&Install
WizardInfoBefore=Package Info
InfoBeforeLabel=Details regarding the packages included in this build.
SetupWindowTitle={#MyAppName} v{#MyAppVersion}

[Files]
Source: "{#SourcePath}\*"; DestDir: "{sd}\MinGW{#Arch}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "assets\icon{#Arch}.ico"; DestDir: "{sd}\MinGW{#Arch}";

[Registry]
; Add MinGW bin directory to system PATH (automatically removed on uninstall)
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; \
  ValueType: expandsz; ValueName: "Path"; ValueData: "{sd}\MinGW{#Arch}\bin;{olddata}"; \
  Check: NeedsAddPath(ExpandConstant('{sd}\MinGW{#Arch}\bin'))

[Code]
const
  { Auto-click constants for skipping pages }
  BN_CLICKED = 0;
  WM_COMMAND = $0111;
  CN_BASE = $BC00;
  CN_COMMAND = CN_BASE + WM_COMMAND;

var
  MinGWDir: string;    { Initialized in InitializeSetup }
  MinGWBinDir: string; { Initialized in InitializeSetup }
  IsUpgrade: Boolean;  { True if existing installation found }

function NeedsAddPath(Path: string): Boolean;
var
  Paths: string;
begin
  { Returns True if the path is not already in PATH }
  if not RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'Path', Paths) then
    Result := True
  else
    Result := Pos(Uppercase(Path) + ';', Uppercase(Paths + ';')) = 0;
end;

function InitializeSetup: Boolean;
begin
  MinGWDir := ExpandConstant('{sd}\MinGW{#Arch}');
  MinGWBinDir := MinGWDir + '\bin';
  IsUpgrade := DirExists(MinGWDir);
  Result := True;
end;

function CountFiles(const Dir: string): Integer;
var
  FindRec: TFindRec;
  SubDir: string;
begin
  Result := 0;
  if FindFirst(Dir + '\*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        begin
          Inc(Result);
          { Recursively count files in subdirectories }
          if FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0 then
          begin
            SubDir := Dir + '\' + FindRec.Name;
            Result := Result + CountFiles(SubDir);
          end;
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

procedure DeleteDirWithProgress(const Dir: string; ProgressPage: TOutputProgressWizardPage; var CurrentFile, TotalFiles: Integer);
var
  FindRec: TFindRec;
  SubDir: string;
begin
  if FindFirst(Dir + '\*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        begin
          SubDir := Dir + '\' + FindRec.Name;
          if FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0 then
            DeleteDirWithProgress(SubDir, ProgressPage, CurrentFile, TotalFiles)
          else
          begin
            DeleteFile(SubDir);
            Inc(CurrentFile);
            ProgressPage.SetProgress(CurrentFile, TotalFiles);
            ProgressPage.SetText('Removing old installation...', FindRec.Name);
          end;
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
  RemoveDir(Dir);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ProgressPage: TOutputProgressWizardPage;
  TotalFiles, CurrentFile: Integer;
begin
  Result := '';
  
  if IsUpgrade then
  begin
    { Ask user for confirmation }
    if MsgBox('A previous version of Easy MinGW Installer is installed.' + #13#10 + #13#10 +
              'The old installation will be removed before installing the new version.' + #13#10 + #13#10 +
              'Do you want to continue?', mbConfirmation, MB_YESNO) = IDNO then
    begin
      Result := 'Installation cancelled by user.';
      Exit;
    end;
    
    { Create progress page }
    ProgressPage := CreateOutputProgressPage('Removing Previous Version',
      'Please wait while the previous installation is being removed...');
    
    try
      ProgressPage.Show;
      ProgressPage.SetText('Counting files...', '');
      ProgressPage.SetProgress(0, 100);
      
      { Count files for progress bar }
      TotalFiles := CountFiles(MinGWDir);
      if TotalFiles = 0 then
        TotalFiles := 1; { Avoid division by zero }
      
      CurrentFile := 0;
      
      { Remove PATH entry first (in case it's different from new path) }
      EnvRemovePath(MinGWBinDir);
      
      { Delete with progress }
      DeleteDirWithProgress(MinGWDir, ProgressPage, CurrentFile, TotalFiles);
      
      ProgressPage.SetProgress(TotalFiles, TotalFiles);
      ProgressPage.SetText('Removal complete!', '');
      Sleep(500); { Brief pause to show completion }
      
    finally
      ProgressPage.Hide;
    end;
  end;
end;

procedure InitializeWizard;
begin
  WizardForm.InfoBeforeClickLabel.Hide;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Param: Longint;
begin
  { Auto-click Next on Ready page since we disabled it }
  if CurPageID = wpReady then
  begin
    Param := 0 or BN_CLICKED shl 16;
    PostMessage(WizardForm.NextButton.Handle, CN_COMMAND, Param, 0);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    EnvRemovePath(ExpandConstant('{sd}\MinGW{#Arch}\bin'));
end;
