@ECHO OFF
TITLE Easy MinGW Installer Builder

@REM ============================================================================
@REM BUILD OPTIONS - set to 1 to enable, 0 to disable
@REM ============================================================================

@REM Only build when WinLibs has a version newer than this project's latest tag.
@REM With this off, every run rebuilds even if nothing changed upstream.
SET "buildOnlyIfNewRelease=1"

@REM Wipe the temp directory and any stale release_notes_body.md before starting,
@REM so a build cannot reuse artifacts from a previous run.
SET "cleanFirst=1"

@REM Always write the Inno Setup build log, not only when a build fails.
SET "generateLogsAlways=0"

@REM Skip ONLY the 200MB archive transfer. Release lookup, asset match, changelog
@REM and the Inno Setup compile all still run, against generated fixture files.
@REM This is the "test build" mode.
SET "skipDownload=0"

@REM No network at all: no release lookup, no download, no changelog. Version
@REM becomes today's date. Use to check the Inno Setup script with no connectivity.
SET "offlineMode=0"

@REM Skip the Inno Setup compile step.
SET "skipBuild=0"

@REM Skip changelog generation (it is ON by default).
SET "skipChangelog=0"

@REM Skip generating and appending file hashes.
SET "skipHashes=0"

@REM ============================================================================
@REM BUILD PARAMETERS
@REM ============================================================================
@REM GCC major version to target (12, 13, 14, 15, 16)
SET "GCC_Ver=16"
@REM Runtime: MSVCRT or UCRT
SET "Runtime=UCRT"
@REM Architectures: 64, 32, or 64,32
SET "archs=64,32"

@REM ============================================================================
@REM OPTIONAL PATH OVERRIDES - leave blank to auto-detect
@REM ============================================================================
@REM Equivalent to the EMI_7ZIP_PATH / EMI_INNOSETUP_PATH environment variables.
SET "SevenZip="
SET "InnoSetup="

@REM ============================================================================
@REM RELEASE AND ASSET MATCHING
@REM ============================================================================
@REM TitlePattern is matched with PowerShell's -like, which is ORDER SENSITIVE.
@REM A real title reads "GCC 16.1.0 (POSIX threads) + MinGW-w64 14.0.0 UCRT
@REM (release 4)", so POSIX must come before UCRT.
SET "TitlePattern=*CC %GCC_Ver%*POSIX*MinGW*%Runtime%*"
SET "P64=winlibs-x86_64-posix-seh-gcc-[0-9.]+-mingw-w64ucrt-.*\.7z$"
SET "P32=winlibs-i686-posix-dwarf-gcc-[0-9.]+-mingw-w64ucrt-.*\.7z$"

IF "%archs%"=="64" (
    SET "patterns=%P64%"
) ELSE IF "%archs%"=="32" (
    SET "patterns=%P32%"
) ELSE (
    SET "patterns=%P64%","%P32%"
)

@REM ============================================================================
@REM FLAG ASSEMBLY - translates the options above into Builder.ps1 switches
@REM ============================================================================
SET "FLAGS="
IF "%buildOnlyIfNewRelease%"=="1" SET "FLAGS=%FLAGS% -CheckNewRelease"
IF "%cleanFirst%"=="1"            SET "FLAGS=%FLAGS% -CleanFirst"
IF "%generateLogsAlways%"=="0"    SET "FLAGS=%FLAGS% -GenerateLogsAlways"
IF "%skipDownload%"=="1"          SET "FLAGS=%FLAGS% -SkipDownload"
IF "%offlineMode%"=="1"           SET "FLAGS=%FLAGS% -OfflineMode"
IF "%skipBuild%"=="1"             SET "FLAGS=%FLAGS% -SkipBuild"
IF "%skipChangelog%"=="1"         SET "FLAGS=%FLAGS% -SkipChangelog"
IF "%skipHashes%"=="1"            SET "FLAGS=%FLAGS% -SkipHashes"

@REM Assigned without outer quotes so the inner quotes around the path survive.
IF DEFINED SevenZip  SET FLAGS=%FLAGS% -SevenZipPath "%SevenZip%"
IF DEFINED InnoSetup SET FLAGS=%FLAGS% -InnoSetupPath "%InnoSetup%"

@REM ============================================================================
@REM RUN
@REM ============================================================================
@REM Tool discovery and dependency validation live in Builder.ps1; a missing
@REM 7-Zip or Inno Setup produces a clear FATAL there, so this script does not
@REM duplicate that check.
IF EXIST "%~dp0builds" RMDIR /S /Q "%~dp0builds"

PowerShell -ExecutionPolicy Bypass -File "%~dp0Builder.ps1" ^
    -TitlePattern "%TitlePattern%" ^
    -Archs "%archs%" ^
    -NamePatterns %patterns% ^
    -OutputPath "%~dp0builds"%FLAGS%

ECHO.
ECHO  ^>^> Press any key to EXIT ^<^<
PAUSE > NUL
