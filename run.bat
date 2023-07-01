@ECHO OFF

@REM powershell.exe -ExecutionPolicy Bypass -File "Build.ps1" -arch "32" -namePattern "winlibs-i686-posix-dwarf-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"
powershell.exe -ExecutionPolicy Bypass -File "Build.ps1" -arch "64" -namePattern "winlibs-x86_64-posix-seh-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"

IF EXIST "%~dp0mingw64" (RMDIR "%~dp0mingw64")
IF EXIST "%~dp0mingw32" (RMDIR "%~dp0mingw32")

PAUSE