[Code]
const EnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

procedure EnvAddPath(Path: string);
var
    Paths: string;
begin
    { Retrieve current path (use empty string if entry not exists) }
    if not RegQueryStringValue(HKEY_LOCAL_MACHINE, EnvironmentKey, 'Path', Paths)
    then Paths := '';

    { Skip if string already found in path }
    if Pos(Uppercase(Path) + ';', Uppercase(Paths)) > 0 then exit;

    { Prepend to the beginning of the path variable }
    Paths := Path + ';' + Paths;

    { Overwrite (or create if missing) path environment variable }
    if RegWriteStringValue(HKEY_LOCAL_MACHINE, EnvironmentKey, 'Path', Paths)
    then Log(Format('The [%s] added to PATH: [%s]', [Path, Paths]))
    else Log(Format('Error while adding the [%s] to PATH: [%s]', [Path, Paths]));
end;

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