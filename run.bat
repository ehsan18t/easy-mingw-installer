@ECHO OFF

TITLE Easy MinGW Installer Builder

@REM ============================================================================
@REM CONFIGURATION - Modify these settings as needed
@REM ============================================================================

@REM Build mode: Set to 1 to only build if there's a new release
SET "buildOnlyIfNewRelease=0"

@REM Logging: Set to 1 to always generate build logs (not just on errors)
SET "generateLogsAlways=0"

@REM Test mode: Set to 1 to run in test mode (no downloads, uses fixtures)
SET "testMode=1"

@REM Test mode flags:
@REM   validateAssets - Verify release assets exist via API (no download)
@REM   generateChangelog - Generate real changelog from last release
SET "validateAssets=1"
SET "generateChangelog=1"

@REM Offline mode: Set to 1 to skip all network requests (use existing files)
SET "offlineMode=0"

@REM Clean first: Set to 1 to clean temp directory before starting
SET "cleanFirst=1"

@REM Skip flags (advanced): Override individual steps
@REM SET "skipDownload=0"
@REM SET "skipBuild=0"
@REM SET "skipChangelog=0"
@REM SET "skipHashes=0"

@REM ============================================================================
@REM BUILD PARAMETERS - Change these to target different GCC versions
@REM ============================================================================

@REM GCC Version: 12, 13, 14, 15
SET "GCC_Ver=15"

@REM Runtime: MSVCRT or UCRT
SET "Runtime=UCRT"

@REM Architectures: 64, 32, or both
SET "archs=64,32"

@REM ============================================================================
@REM PATHS SETUP - Auto-detected but can be overridden
@REM ============================================================================

SET "outputPath=%~dp0builds"
SET "W64=%ProgramFiles%"
SET "W32=%ProgramFiles% (x86)"
SET "SevenZip="
SET "InnoSetup="
SET "Builder_Script=%~dp0Builder.ps1"

@REM ============================================================================
@REM ENVIRONMENT PREPARATION
@REM ============================================================================

CALL :CheckApps
IF EXIST "%outputPath%" (RMDIR /S /Q "%outputPath%")
IF EXIST "%~dp0*.log" (DEL "%~dp0*.log")

@REM ============================================================================
@REM BUILD PATTERNS
@REM ============================================================================

SET "TitlePattern=*CC %GCC_Ver%*POSIX*MinGW*%Runtime%*"
SET "Pattern64=winlibs-x86_64-posix-seh-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"
SET "Pattern32=winlibs-i686-posix-dwarf-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"

@REM ============================================================================
@REM BUILD COMMAND CONSTRUCTION
@REM ============================================================================

SET PowerShellCmd=PowerShell -ExecutionPolicy Bypass -File "%Builder_Script%"
SET PowerShellCmd=%PowerShellCmd% -TitlePattern "%TitlePattern%"
SET PowerShellCmd=%PowerShellCmd% -Archs "%archs%"
SET PowerShellCmd=%PowerShellCmd% -NamePatterns "%Pattern64%","%Pattern32%"
SET PowerShellCmd=%PowerShellCmd% -OutputPath "%outputPath%"

@REM Add tool paths if auto-detection found them
IF DEFINED InnoSetup ( SET PowerShellCmd=%PowerShellCmd% -InnoSetupPath "%InnoSetup%" )
IF DEFINED SevenZip ( SET PowerShellCmd=%PowerShellCmd% -SevenZipPath "%SevenZip%" )

@REM Add optional flags
IF "%buildOnlyIfNewRelease%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -CheckNewRelease )
IF "%generateLogsAlways%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -GenerateLogsAlways )
IF "%testMode%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -TestMode )
IF "%validateAssets%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -ValidateAssets )
IF "%generateChangelog%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -GenerateChangelog )
IF "%offlineMode%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -OfflineMode )
IF "%cleanFirst%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -CleanFirst )

@REM Advanced skip flags (uncomment to use)
@REM IF "%skipDownload%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -SkipDownload )
@REM IF "%skipBuild%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -SkipBuild )
@REM IF "%skipChangelog%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -SkipChangelog )
@REM IF "%skipHashes%"=="1" ( SET PowerShellCmd=%PowerShellCmd% -SkipHashes )

@REM ============================================================================
@REM RUN BUILD
@REM ============================================================================

ECHO.
ECHO Running: %PowerShellCmd%
ECHO.

%PowerShellCmd%

CALL :END

:CheckApps
CALL :CheckAppInstalled "Inno Setup" "InnoSetup" "Inno Setup 6\ISCC.exe"
CALL :CheckAppInstalled "7-Zip" "SevenZip" "7-Zip\7z.exe"
ECHO.
EXIT /B

:CheckAppInstalled
IF NOT EXIST "%W32%\%~3"  (
    IF NOT EXIST "%W64%\%~3"  (
        ECHO  -^> ERROR: %~1 not installed!
        CALL :END
    ) ELSE ( SET "%~2=%W64%\%~3" )
) ELSE ( SET "%~2=%W32%\%~3" )
EXIT /B

:END
ECHO.
ECHO  ^>^> Press any key to EXIT ^<^<
PAUSE > NUL
EXIT
