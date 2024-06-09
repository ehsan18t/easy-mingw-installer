@ECHO OFF

TITLE Easy MinGW Installer Builder

@REM CONFIGS
@REM Change "buildOnlyIfNewRelease=0" for your personal build
SET "buildOnlyIfNewRelease=1"
@REM By default, logs are generated only if there is an error.
@REM Change "generateLogsAlways=1" to generate logs always.
SET "generateLogsAlways=0"

@REM DO NOT CHANGE ANYTHING BELOW IF YOU DON'T KNOW WHAT YOU ARE DOING
@REM Parameters
@REM GCC Version 12, 13, 14, 15
SET "GCC_Ver=14"
@REM MSVCRT or UCRT
SET "Runtime=UCRT"

@REM Paths Setup
SET "outputPath=%~dp0builds"
SET "W64=%ProgramFiles%"
SET "W32=%ProgramFiles% (x86)"
SET "SevenZip="
SET "InnoSetup="
SET "Builder_Script=%~dp0Builder.ps1"

@REM Preparing the environment
CALL :CheckApps
IF EXIST "%outputPath%" (RMDIR /S /Q "%outputPath%")
IF EXIST "%~dp0*.log" (DEL "%~dp0*.log")

@REM RegEx Patterns
SET "TP=*CC %GCC_Ver%*POSIX*MinGW*%Runtime%*"
SET "NP64=winlibs-x86_64-posix-seh-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"
SET "NP32=winlibs-i686-posix-dwarf-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"

@REM Build Command
SET PowerShellCmd=PowerShell -ExecutionPolicy Bypass -File "%Builder_Script%" -titlePattern "%TP%" -archs "64","32" -namePatterns "%NP64%","%NP32%"
SET PowerShellCmd=%PowerShellCmd% -outputPath "%outputPath%" -InnoSetupPath "%InnoSetup%" -7ZipPath "%SevenZip%"
IF "%buildOnlyIfNewRelease%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -checkNewRelease )
IF "%generateLogsAlways%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -generateLogsAlways )

@REM Run the build script
%PowerShellCmd%

CALL :END

:CheckApps
IF NOT EXIST "%W32%\Inno Setup 6\ISCC.exe"  (
    IF NOT EXIST "%W64%\Inno Setup 6\ISCC.exe"  (
        ECHO  -^> ERROR: Inno Setup not installed!
        CALL :END
    ) ELSE ( SET "InnoSetup=%W64%\Inno Setup 6\ISCC.exe" )
) ELSE ( SET "InnoSetup=%W32%\Inno Setup 6\ISCC.exe" )
IF NOT EXIST "%W64%\7-Zip\7z.exe"  (
    IF NOT EXIST "%W32%\7-Zip\7z.exe"  (
        ECHO  -^> ERROR: 7-Zip not installed
        CALL :END
    ) ELSE ( SET "SevenZip=%W32%\7-Zip\7z.exe" )
) ELSE ( SET "SevenZip=%W64%\7-Zip\7z.exe" )
EXIT /B

:END
ECHO.
ECHO  ^>^> Press any key to EXIT ^<^<
PAUSE > NUL
EXIT
