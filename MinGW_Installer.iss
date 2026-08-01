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
  MinGWDir: string;      { Initialized in InitializeSetup }
  MinGWBinDir: string;   { Initialized in InitializeSetup }
  OtherDir: string;      { The other architecture's install, if any }
  OtherBinDir: string;   { Initialized in InitializeSetup }
  IsUpgrade: Boolean;    { True if this architecture is already installed }
  HasOtherArch: Boolean; { True if the other architecture is installed }

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

  { Only one architecture may be installed at a time. Both builds put a gcc.exe
    on the system PATH, and whichever entry comes first silently wins, so a
    32-bit install left sitting next to a 64-bit one hands the user a toolchain
    they did not ask for. Installing either build therefore replaces the other.

    Sharing one AppId across both architectures is deliberate -- it keeps a
    single Add/Remove Programs entry -- but it does NOT make Inno remove the
    other build. Same AppId means Setup *appends* to the existing uninstall log.
    The replacement has to be done here. }
  if '{#Arch}' = '64' then
    OtherDir := ExpandConstant('{sd}\MinGW32')
  else
    OtherDir := ExpandConstant('{sd}\MinGW64');
  OtherBinDir := OtherDir + '\bin';

  IsUpgrade    := DirExists(MinGWDir);
  HasOtherArch := DirExists(OtherDir);
  Result := True;
end;

{ Removes one installation and its PATH entry. Returns False if the tree could
  not be fully deleted, which in practice means a file is still locked by a
  running gcc.exe, gdb.exe or a shell sitting in the directory.

  Safe to call for a directory that does not exist, which is what lets the
  caller ask for both architectures unconditionally. }
function RemoveInstallation(const Dir, BinDir: string): Boolean;
begin
  Result := True;
  if not DirExists(Dir) then
    Exit;

  { PATH entry first: if the delete then fails part-way, the user is left with a
    stale directory rather than a PATH entry pointing into a half-deleted tree. }
  EnvRemovePath(BinDir);
  Result := DelTree(Dir, True, True, True);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ProgressPage: TOutputProgressWizardPage;
  Prompt: string;
  Removed: Boolean;
begin
  Result := '';

  if IsUpgrade or HasOtherArch then
  begin
    { Ask the user for confirmation, but only when there is a user to ask.
      PrepareToInstall still runs under /SILENT and /VERYSILENT, where this
      MsgBox appears with no visible parent and blocks Setup until someone
      finds and clicks it -- a headless deployment hangs until it is killed.
      Passing /SILENT is itself consent to an unattended upgrade, so silent
      runs proceed as if Yes was chosen.

      Note: this is deliberately a nested if rather than
      "if (not WizardSilent) and (MsgBox(...) = IDNO)". Pascal Script does not
      guarantee short-circuit evaluation, so the combined form would still
      call MsgBox during a silent install. }
    if not WizardSilent then
    begin
      Prompt := '';
      if IsUpgrade then
        Prompt := 'A previous version of Easy MinGW Installer is installed.' + #13#10;
      if HasOtherArch then
        Prompt := Prompt +
                  'A different architecture is installed at ' + OtherDir + '.' + #13#10 +
                  'Only one architecture can be installed at a time, because both' + #13#10 +
                  'add a compiler to the system PATH.' + #13#10;

      if MsgBox(Prompt + #13#10 +
                'The existing installation will be removed before installing this version.' + #13#10 + #13#10 +
                'Do you want to continue?', mbConfirmation, MB_YESNO) = IDNO then
      begin
        Result := 'Installation cancelled by user.';
        Exit;
      end;
    end;

    { Create progress page }
    ProgressPage := CreateOutputProgressPage('Removing Previous Version',
      'Please wait while the previous installation is being removed...');
    
    try
      ProgressPage.Show;
      ProgressPage.SetText('Removing previous installation...', '');
      ProgressPage.SetProgress(0, 2);

      { This architecture first, then the other one. Each call is a no-op when
        its directory is absent, so one pair of calls covers all three cases:
        a same-arch upgrade, an architecture switch, and a machine that ended
        up with both installed before this replacement logic existed.

        Both calls are made unconditionally and the results combined afterwards.
        Folding them into one expression would risk the second being skipped,
        since Pascal Script does not guarantee short-circuit evaluation. }
      Removed := RemoveInstallation(MinGWDir, MinGWBinDir);
      ProgressPage.SetProgress(1, 2);
      if not RemoveInstallation(OtherDir, OtherBinDir) then
        Removed := False;
      ProgressPage.SetProgress(2, 2);

      { A locked file used to fail silently: DeleteFile's result was discarded
        and the page still reported success, so Setup went on to install over a
        half-removed tree.

        Unlike the confirmation prompt above, this is a real error and must stop
        the install. Inno shows it in a message box, which under /SILENT blocks
        exactly like any other Setup error, so unattended callers should pass
        /SUPPRESSMSGBOXES -- they then get exit code 7 instead of a hang. }
      if not Removed then
        Result := 'The previous installation could not be fully removed.' + #13#10 + #13#10 +
                  'Close anything using MinGW -- a terminal, an editor, a running' + #13#10 +
                  'gcc or gdb -- and run Setup again.';
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
