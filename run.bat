@ECHO OFF

TITLE Easy MinGW Installer Builder

IF EXIST "%~dp0Output" (RMDIR /S /Q "%~dp0Output")
CALL :Check
CALL :CleanUp

@REM CONFIGS
@REM Change "buildOnlyIfNewRelease=0" for your personal build
SET "buildOnlyIfNewRelease=1"

@REM DO NOT CHANGE ANYTHING BELOW IF YOU DON'T KNOW WHAT YOU ARE DOING
SET "NR="
SET "TP=*CC*POSIX*MinGW*UCRT*"
SET "NP64=winlibs-x86_64-posix-seh-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"
SET "NP32=winlibs-i686-posix-dwarf-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"

if "%buildOnlyIfNewRelease%"=="1" (
    SET "NR=-checkNewRelease"
)

PowerShell -ExecutionPolicy Bypass -File "Build.ps1" -arch "64" %NR% -titlePattern "%TP%" -namePattern "%NP64%"
PowerShell -ExecutionPolicy Bypass -File "Build.ps1" -arch "32" %NR% -titlePattern "%TP%" -namePattern "%NP32%"

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
