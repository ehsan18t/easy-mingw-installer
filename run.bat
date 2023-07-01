@ECHO OFF

IF EXIST "%~dp0Output" (RMDIR /S /Q "%~dp0Output")
CALL :CleanUp

powershell.exe -ExecutionPolicy Bypass -File "Build.ps1" -arch "32" -namePattern "winlibs-i686-posix-dwarf-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"
powershell.exe -ExecutionPolicy Bypass -File "Build.ps1" -arch "64" -namePattern "winlibs-x86_64-posix-seh-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"

CALL :CleanUp
PAUSE
EXIT

:CleanUp
IF EXIST "%~dp0*.7z" (DEL "%~dp0*.7z")
IF EXIST "%~dp0mingw64" (RMDIR /S /Q "%~dp0mingw64")
IF EXIST "%~dp0mingw32" (RMDIR /S /Q "%~dp0mingw32")
EXIT /B
