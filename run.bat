@ECHO OFF

TITLE Easy MinGW Installer Builder

IF EXIST "%~dp0Output" (RMDIR /S /Q "%~dp0Output")
IF EXIST "%~dp0*.log" (DEL "%~dp0*.log")
CALL :Check
CALL :CleanUp

@REM CONFIGS
@REM Change "buildOnlyIfNewRelease=0" for your personal build
SET "buildOnlyIfNewRelease=1"
@REM By default, logs are generated only if there is an error.
@REM Change "generateLogsAlways=1" to generate logs always
SET "generateLogsAlways=0"

@REM DO NOT CHANGE ANYTHING BELOW IF YOU DON'T KNOW WHAT YOU ARE DOING
SET "TP=*CC*POSIX*MinGW*UCRT*"
SET "NP64=winlibs-x86_64-posix-seh-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"
SET "NP32=winlibs-i686-posix-dwarf-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"

set PowerShellCmd=PowerShell -ExecutionPolicy Bypass -File "Build.ps1" -titlePattern "%TP%" -archs "64","32" -namePatterns "%NP64%","%NP32%"

if "%buildOnlyIfNewRelease%"=="1" (set PowerShellCmd=%PowerShellCmd% -checkNewRelease)
if "%generateLogsAlways%"=="1" (set PowerShellCmd=%PowerShellCmd% -generateLogsAlways)

%PowerShellCmd%

CALL :CleanUp
CALL :END

:CleanUp
IF EXIST "%~dp0*.7z" (DEL "%~dp0*.7z")
IF EXIST "%~dp0mingw64" (RMDIR /S /Q "%~dp0mingw64")
IF EXIST "%~dp0mingw32" (RMDIR /S /Q "%~dp0mingw32")
EXIT /B

:Check
IF NOT EXIST "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" (
        ECHO  -^> ERROR: Inno Setup not installed!
        CALL :END
    )
IF NOT EXIST "C:\Program Files\7-Zip\7z.exe" (
        ECHO  -^> ERROR: 7-Zip not installed
        CALL :END
    )
EXIT /B

:END
ECHO  ^>^> Press any key to EXIT...
PAUSE > NUL
EXIT
