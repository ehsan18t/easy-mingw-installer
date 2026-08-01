; Registry location of the machine-wide environment block. Defined once here and
; consumed by both the [Registry] entry and the Pascal code in
; MinGW_Installer.iss, so the copies of this path cannot drift apart.
#define EnvironmentKeyPath "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"

[Code]
const EnvironmentKey = '{#EnvironmentKeyPath}';

procedure EnvRemovePath(Path: string);
var
    Paths: string;
    P: Integer;
    Changed: Boolean;
begin
    { An empty needle would match everywhere and loop forever. }
    if Path = '' then exit;

    { Skip if registry entry doesn't exist }
    if not RegQueryStringValue(HKEY_LOCAL_MACHINE, EnvironmentKey, 'Path', Paths) then
        exit;

    Changed := False;

    { Pad the haystack with ';' so a trailing entry that has no separator after it
      still matches. This mirrors NeedsAddPath in MinGW_Installer.iss. Without the
      padding, an entry that ends up last in PATH is silently left behind on
      uninstall, pointing at a deleted directory. Loop so a duplicated entry is
      fully removed rather than leaving one behind. Delete clamps to the string
      length, so removing a trailing entry is safe. }
    P := Pos(Uppercase(Path) + ';', Uppercase(Paths) + ';');
    while P > 0 do
    begin
        Delete(Paths, P, Length(Path) + 1);
        Changed := True;
        P := Pos(Uppercase(Path) + ';', Uppercase(Paths) + ';');
    end;

    if not Changed then exit;

    { Removing an entry that sits last leaves a dangling separator. Delete clamps
      to the string length, so 'C:\Windows;C:\MinGW64\bin' comes back as
      'C:\Windows;'. Windows ignores the empty field, but there is no reason to
      write it. Tested against the real engine, so the shape matters: this is a
      loop with an explicit Break rather than
      "while (Length(Paths) > 0) and (Paths[Length(Paths)] = ';')", because
      Pascal Script does not guarantee short-circuit evaluation and the second
      operand would index Paths[0] once the string was empty. }
    while Paths <> '' do
    begin
        if Paths[Length(Paths)] <> ';' then Break;
        Delete(Paths, Length(Paths), 1);
    end;

    { Never blank out the machine PATH. If this entry were somehow the only one
      present, everything above reduces Paths to '' and the write below would
      strip every directory from the system PATH for every user. }
    if Paths = '' then
    begin
        Log(Format('Refusing to write an empty system PATH while removing [%s]', [Path]));
        exit;
    end;

    { Write updated path environment variable. RegWriteStringValue preserves an
      existing REG_EXPAND_SZ value's type, so the %SystemRoot% style entries in
      PATH keep expanding. }
    if RegWriteStringValue(HKEY_LOCAL_MACHINE, EnvironmentKey, 'Path', Paths)
    then Log(Format('Removed [%s] from PATH', [Path]))
    else Log(Format('Error removing [%s] from PATH', [Path]));
end;