@ECHO OFF
TITLE Easy MinGW Installer Builder

@REM ============================================================================
@REM CONFIGURATION
@REM ============================================================================
@REM GCC major version to target (12, 13, 14, 15, 16)
SET "GCC_Ver=16"
@REM Runtime: MSVCRT or UCRT
SET "Runtime=UCRT"
@REM Architectures: 64, 32, or 64,32
SET "archs=64,32"

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
@REM RUN
@REM ============================================================================
@REM Tool discovery and dependency validation live in Builder.ps1; a missing
@REM 7-Zip or Inno Setup produces a clear FATAL there, so this script no longer
@REM duplicates that check. -CleanFirst removes the temp directory and any stale
@REM release notes.
IF EXIST "%~dp0builds" RMDIR /S /Q "%~dp0builds"

PowerShell -ExecutionPolicy Bypass -File "%~dp0Builder.ps1" ^
    -TitlePattern "%TitlePattern%" ^
    -Archs "%archs%" ^
    -NamePatterns %patterns% ^
    -OutputPath "%~dp0builds" ^
    -CheckNewRelease ^
    -CleanFirst

ECHO.
ECHO  ^>^> Press any key to EXIT ^<^<
PAUSE > NUL
