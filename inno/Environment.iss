[Code]
const EnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

procedure EnvRemovePath(Path: string);
var
    Paths: string;
    P: Integer;
begin
    { Skip if registry entry doesn't exist }
    if not RegQueryStringValue(HKEY_LOCAL_MACHINE, EnvironmentKey, 'Path', Paths) then
        exit;

    { Skip if string not found in path }
    P := Pos(Uppercase(Path) + ';', Uppercase(Paths));
    if P = 0 then exit;

    { Remove the path from the variable }
    Delete(Paths, P, Length(Path) + 1);

    { Write updated path environment variable }
    if RegWriteStringValue(HKEY_LOCAL_MACHINE, EnvironmentKey, 'Path', Paths)
    then Log(Format('Removed [%s] from PATH', [Path]))
    else Log(Format('Error removing [%s] from PATH', [Path]));
end;