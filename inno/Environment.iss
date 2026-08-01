[Code]
const EnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

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

    { Write updated path environment variable }
    if RegWriteStringValue(HKEY_LOCAL_MACHINE, EnvironmentKey, 'Path', Paths)
    then Log(Format('Removed [%s] from PATH', [Path]))
    else Log(Format('Error removing [%s] from PATH', [Path]));
end;