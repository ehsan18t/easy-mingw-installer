<#
.SYNOPSIS
    Main build script for Easy MinGW Installer - downloads WinLibs MinGW packages
    and creates Windows installers with Inno Setup.

.DESCRIPTION
    This is the entry point for building Easy MinGW Installer packages. The script:
    
    1. INITIALIZATION
       - Loads configuration from modules/config.ps1
       - Loads helper functions from modules/functions.ps1 and modules/pretty.ps1
       - Validates dependencies (7-Zip, Inno Setup)
    
    2. VERSION RESOLUTION
       - Fetches latest WinLibs release matching the specified pattern
       - Compares against the project's latest tag to detect new versions
       - In test mode, uses mock data or validates real assets
    
    3. BUILD PROCESS (per architecture)
       - Downloads the MinGW archive from GitHub releases
       - Extracts using 7-Zip to a temp directory
       - Generates changelog from version_info.txt
       - Builds installer using Inno Setup
       - Generates file hashes (SHA256, MD5, etc.)
    
    4. POST-BUILD
       - Appends file hashes to the release notes
       - Cleans up temporary files
       - Displays build summary

    The script supports these modes:
    - NORMAL:        Full build. Downloads the archive, generates the changelog,
                     compiles the installer.
    - -SkipDownload: Everything a normal build does except transferring the archive.
                     The MinGW payload is replaced with generated fixtures, so the
                     resulting installer is a structural test artifact, not a usable
                     toolchain. The release lookup, asset match, changelog and Inno
                     Setup compile all run for real.
    - -OfflineMode:  No network requests at all. Fixtures for the payload, no
                     changelog, version is today's date. Use to verify the Inno
                     Setup script with no connectivity.
    - CI MODE:       Detected automatically in GitHub Actions; adjusts output only.

.PARAMETER TitlePattern
    Wildcard pattern to match WinLibs release titles. Filters which GitHub release
    to use as the source.

    Matched with -like, which is ORDER SENSITIVE. A real title looks like
    "GCC 16.1.0 (POSIX threads) + MinGW-w64 14.0.0 UCRT (release 4)", so the terms
    must appear in that order: "*POSIX*UCRT*" matches, "*UCRT*POSIX*" never does.
    To pin a major version, use "*CC 16*POSIX*UCRT*".

.PARAMETER Archs
    Array of architectures to build: "64", "32", or both @("64", "32").
    Each architecture produces a separate installer.

.PARAMETER NamePatterns
    Regex patterns to match asset filenames for each architecture.
    Must have the same count as -Archs parameter.

.PARAMETER OutputPath
    Directory for built installers and hash files. Defaults to ./output.

.PARAMETER SevenZipPath
    Path to 7z.exe. Auto-detected if not specified.
    Can also be set via EMI_7ZIP_PATH environment variable.

.PARAMETER InnoSetupPath
    Path to ISCC.exe (Inno Setup Compiler). Auto-detected if not specified.
    Can also be set via EMI_INNOSETUP_PATH environment variable.

.PARAMETER OfflineMode
    Makes no network requests at all: no release lookup, no download, no changelog.
    The MinGW payload is replaced with generated fixtures and the version is today's
    date. The temp directory is kept so the generated tree can be inspected.

.PARAMETER CleanFirst
    Removes the temp directory before starting the build.

.PARAMETER CheckNewRelease
    Compares WinLibs version against project's latest tag.
    Skips build if versions match (already up-to-date).

.PARAMETER SkipDownload
    Skips only the archive transfer, replacing the MinGW payload with generated
    fixtures. The release lookup, asset pattern match, changelog generation and Inno
    Setup compile all run exactly as in a normal build. The temp directory is kept so
    the generated tree can be inspected.

.PARAMETER SkipBuild
    Skips the Inno Setup compilation step.

.PARAMETER SkipChangelog
    Skips changelog generation.

.PARAMETER SkipHashes
    Skips generating and appending file hashes.

.PARAMETER GenerateLogsAlways
    Always generates Inno Setup build logs, not just on errors.

.EXAMPLE
    .\Builder.ps1
    # Standard build: 64-bit UCRT/POSIX installer

.EXAMPLE
    .\Builder.ps1 -Archs "64","32"
    # Build both 64-bit and 32-bit installers

.EXAMPLE
    .\Builder.ps1 -SkipDownload
    # Exercise the whole pipeline without the 200MB download. Real release lookup,
    # real changelog, real installer built around fixture files.

.EXAMPLE
    .\Builder.ps1 -OfflineMode
    # No network at all. Verifies the Inno Setup script compiles and packages.

.EXAMPLE
    .\Builder.ps1 -CheckNewRelease
    # Only build if WinLibs has a newer version than our latest release

.NOTES
    File Name      : Builder.ps1
    Prerequisite   : PowerShell 5.1+, 7-Zip, Inno Setup 5/6
    
    Environment Variables:
        EMI_LOG_LEVEL      - Logging verbosity: Verbose, Normal, Quiet
        EMI_7ZIP_PATH      - Custom 7-Zip executable path
        EMI_INNOSETUP_PATH - Custom Inno Setup compiler path
        EMI_PROJECT_OWNER  - GitHub owner for this project (default: ehsan18t)
        EMI_PROJECT_REPO   - GitHub repo name (default: easy-mingw-installer)
        EMI_WINLIBS_OWNER  - WinLibs GitHub owner (default: brechtsanders)
        EMI_WINLIBS_REPO   - WinLibs repo name (default: winlibs_mingw)

.LINK
    https://github.com/ehsan18t/easy-mingw-installer

.LINK
    https://github.com/brechtsanders/winlibs_mingw
#>

# ============================================================================
# Easy MinGW Installer - Main Build Script
# ============================================================================

[CmdletBinding()]
param(
    # WinLibs release title pattern.
    # -like is order-sensitive and real titles read
    # "GCC 16.1.0 (POSIX threads) + MinGW-w64 14.0.0 UCRT (release 4)",
    # so POSIX must come before UCRT here.
    [Parameter()]
    [string]$TitlePattern = '*POSIX*UCRT*',

    # Architectures to build (e.g., @('64', '32'))
    [Parameter()]
    [string[]]$Archs = @('64'),

    # Asset name patterns for each architecture (regex), one per entry in -Archs
    [Parameter()]
    [string[]]$NamePatterns = @('winlibs-x86_64-posix-seh-gcc-[0-9.]+-mingw-w64ucrt-.*\.7z$'),

    # Output directory for built installers
    [Parameter()]
    [string]$OutputPath,

    # Path to 7-Zip executable (auto-detected if not specified)
    [Parameter()]
    [string]$SevenZipPath,

    # Path to Inno Setup compiler (auto-detected if not specified)
    [Parameter()]
    [string]$InnoSetupPath,

    # ========================
    # MODE SWITCHES
    # ========================

    # Offline mode: skip all network requests
    [switch]$OfflineMode,

    # Clean temp directory before starting
    [switch]$CleanFirst,

    # Check if a new release is available before building
    [switch]$CheckNewRelease,

    # ========================
    # GRANULAR CONTROL FLAGS
    # ========================

    # Skip downloading MinGW archives (use existing or test fixtures)
    [switch]$SkipDownload,

    # Skip building the installer with Inno Setup
    [switch]$SkipBuild,

    # Skip generating the changelog
    [switch]$SkipChangelog,

    # Skip generating file hashes (also skips appending hashes to changelog)
    [switch]$SkipHashes,

    # Always generate Inno Setup build logs (not just on errors)
    [switch]$GenerateLogsAlways
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Module Loading
# ============================================================================

. "$PSScriptRoot\modules\pretty.ps1"
. "$PSScriptRoot\modules\config.ps1"
. "$PSScriptRoot\modules\functions.ps1"

# ============================================================================
# Cancellation Support
# ============================================================================
# Store paths and state for cleanup (will be set after config initialization)

$script:CleanupPaths = @{
    TempDirectory   = $null
    OutputDirectory = $null
    ChangelogPath   = $null
    StartTime       = $null
}

# ============================================================================
# Parameter Processing
# ============================================================================

# Handle array parameters passed as comma-separated strings
if ($Archs.Count -eq 1 -and $Archs[0].Contains(',')) {
    $Archs = $Archs[0].Split(',') | ForEach-Object { $_.Trim() }
}
if ($NamePatterns.Count -eq 1 -and $NamePatterns[0].Contains(',')) {
    $NamePatterns = $NamePatterns[0].Split(',') | ForEach-Object { $_.Trim() }
}

# ============================================================================
# Configuration Initialization
# ============================================================================

# Build configuration overrides from parameters.
# Switch parameter names match config property names exactly, so one loop covers
# them all. Only bound parameters are forwarded, which lets Initialize-BuildConfig
# distinguish "not specified" from "explicitly set to false".
$configOverrides = @{}

foreach ($name in @(
        'OfflineMode', 'CleanFirst', 'SkipDownload', 'SkipBuild',
        'SkipChangelog', 'SkipHashes', 'GenerateLogsAlways')) {
    if ($PSBoundParameters.ContainsKey($name)) {
        $configOverrides[$name] = $PSBoundParameters[$name].IsPresent
    }
}

# Tool paths are strings, not switches, and only override when non-empty.
if ($SevenZipPath) {
    $configOverrides['SevenZipPath'] = $SevenZipPath
}
if ($InnoSetupPath) {
    $configOverrides['InnoSetupPath'] = $InnoSetupPath
}

# Initialize configuration
Initialize-BuildConfig -Overrides $configOverrides
$cfg = Get-BuildConfig

# ============================================================================
# Clean First (if requested)
# ============================================================================

if ($cfg.CleanFirst -and (Test-Path $cfg.TempDirectory)) {
    Write-Host "`n[Clean] Removing temp directory: $($cfg.TempDirectory)" -ForegroundColor Yellow
    Remove-Item -Path $cfg.TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# Build Header & Info Display
# ============================================================================

Write-BuildHeader -Title 'Easy MinGW Installer Builder'

# Setup paths
$outputDir = if ($OutputPath) { $OutputPath } else { Join-Path $PSScriptRoot 'output' }
$issPath = Join-Path $PSScriptRoot 'MinGW_Installer.iss'
$releaseNotesPath = Join-Path $PSScriptRoot 'release_notes_body.md'

# Update cleanup paths for cancellation handler
$script:CleanupPaths.TempDirectory = $cfg.TempDirectory
$script:CleanupPaths.OutputDirectory = $outputDir
$script:CleanupPaths.ChangelogPath = $releaseNotesPath

# Display build configuration
Write-BuildInfo -Config $cfg -Architectures $Archs -OutputPath $outputDir

# Verbose logging of paths and directories
if ($cfg.LogLevel -eq 'Verbose') {
    Write-SeparatorLine -Character '-' -Length 50
    Write-LogEntry -Type '7-Zip Path' -Message $cfg.SevenZipPath
    Write-LogEntry -Type 'InnoSetup Path' -Message $cfg.InnoSetupPath
    Write-LogEntry -Type 'Temp Directory' -Message $cfg.TempDirectory
    Write-LogEntry -Type 'Output Directory' -Message $outputDir
    Write-SeparatorLine -Character '-' -Length 50
}

# ============================================================================
# Dependency Validation
# ============================================================================

$depCheck = Test-BuildDependencies
if (-not $depCheck.Success) {
    foreach ($err in $depCheck.Errors) {
        Write-ErrorMessage -ErrorType 'Dependency' -Message $err
    }
    Write-ErrorMessage -ErrorType 'FATAL' -Message 'Required dependencies are missing. Cannot proceed.'
    exit 1
}

# Validate Inno Setup script exists
if (-not $cfg.SkipBuild -and -not (Test-Path $issPath -PathType Leaf)) {
    Write-ErrorMessage -ErrorType 'FATAL' -Message "Inno Setup script not found: $issPath"
    exit 1
}

# Validate arch/pattern count match
if ($Archs.Count -ne $NamePatterns.Count) {
    Write-ErrorMessage -ErrorType 'FATAL' -Message "Architecture count ($($Archs.Count)) must match pattern count ($($NamePatterns.Count))"
    exit 1
}

# ============================================================================
# Main Build Process
# ============================================================================

$buildSuccess = $false
$buildStartTime = Get-Date
$script:CleanupPaths.StartTime = $buildStartTime

try {
    Write-StatusInfo -Type 'Starting' -Message 'Build operations...'

    # ========================
    # Version Resolution
    # ========================
    $previousTag = $null
    $version = $null
    $releaseDate = (Get-Date).ToString('yyyy-MM-dd')
    $release = $null

    if ($cfg.OfflineMode) {
        # No network. There is no release to query, so derive a version from today's
        # date and hand the pipeline an empty release object. SkipDownload and
        # SkipChangelog are already set by Initialize-BuildConfig.
        $version = (Get-Date).ToString('yyyy.MM.dd')
        $release = [PSCustomObject]@{ name = 'Offline Build'; assets = @() }
        Write-StatusInfo -Type 'Offline' -Message "Version $version (no network requests)"
    }
    else {
        # Normal and -SkipDownload take the same path. -SkipDownload differs only in
        # that Invoke-ArchitectureBuild does not transfer the archive.

        # Always fetch the project's latest tag. -CheckNewRelease uses it to decide
        # whether to build at all, and the changelog uses it as the diff baseline and
        # for the "Full Changelog" compare link. Fetching it only under
        # -CheckNewRelease left the changelog with a literal TODO placeholder on a
        # plain build. Invoke-GitHubApi caches, so this is one request per run.
        # The @() is load-bearing: a single-element result must not arrive here as a
        # bare string, or $projectTags[0] would index into it and yield '2'.
        $projectTags = @(Get-GitHubTags -Owner $cfg.ProjectOwner -Repo $cfg.ProjectRepo -Count 1)
        $previousTag = if ($projectTags.Count -gt 0) { $projectTags[0] } else { $null }
        if ($previousTag) {
            Write-StatusInfo -Type 'Previous Tag' -Message $previousTag
        }
        else {
            Write-WarningMessage -Type 'Changelog' -Message 'No previous tag found; comparison will be skipped'
        }

        # Find matching WinLibs release
        $release = Find-GitHubRelease -Owner $cfg.WinLibsOwner -Repo $cfg.WinLibsRepo -TitlePattern $TitlePattern
        if (-not $release) {
            Write-ErrorMessage -ErrorType 'FATAL' -Message "No WinLibs release matches pattern: $TitlePattern"
            exit 1
        }

        # Extract version from release date
        $publishedDate = [datetime]$release.published_at
        $version = $publishedDate.ToString('yyyy.MM.dd')
        $releaseDate = $publishedDate.ToString('yyyy-MM-dd')

        Write-StatusInfo -Type 'Target Version' -Message $version
        Write-StatusInfo -Type 'Release Date' -Message $releaseDate

        # The release workflow reads this file to decide which tag to push, so only a
        # real build may produce one. Recreate the directory so it holds exactly one
        # file: a stale entry from an earlier run would be published under the wrong
        # version. Must live outside $cfg.TempDirectory, which is cleaned in finally.
        if ($cfg.IsGitHubActions -and -not $cfg.SkipDownload) {
            $tagsDir = Join-Path -Path $PSScriptRoot -ChildPath 'tag'
            if (Test-Path $tagsDir) {
                Remove-Item $tagsDir -Recurse -Force
            }
            New-Item -ItemType Directory -Path $tagsDir -Force | Out-Null
            Set-Content -Path (Join-Path $tagsDir $version) -Value $version -Encoding utf8 -NoNewline
        }
    }

    # ========================
    # Version Check (Skip if up-to-date)
    # ========================
    # Offline mode has no tag to compare against, so it can never be "up to date".
    if ($CheckNewRelease -and -not $cfg.OfflineMode -and $previousTag -eq $version) {
        Write-SeparatorLine -Character '=' -Length 50
        Write-SuccessMessage -Type 'Up to Date' -Message "Already at version $version - no build required"
        $buildSuccess = $true
    }
    else {
        # ========================
        # Build Each Architecture
        # ========================
        $buildSuccess = $true

        for ($i = 0; $i -lt $Archs.Count; $i++) {
            $arch = $Archs[$i]
            $pattern = $NamePatterns[$i]

            $archResult = Invoke-ArchitectureBuild `
                -Architecture $arch `
                -AssetPattern $pattern `
                -Release $release `
                -Version $version `
                -Date $releaseDate `
                -PreviousTag $previousTag `
                -OutputDirectory $outputDir `
                -TempDirectory $cfg.TempDirectory `
                -IssPath $issPath `
                -ReleaseNotesPath $releaseNotesPath

            if (-not $archResult) {
                Write-ErrorMessage -ErrorType 'Build Failed' -Message "$arch-bit architecture failed"
                $buildSuccess = $false
            }
        }

        # ========================
        # Post-Build: Append Hashes to Changelog
        # ========================
        if ($buildSuccess -and -not $cfg.SkipBuild -and -not $cfg.SkipHashes) {
            if (Test-Path $releaseNotesPath) {
                Write-SeparatorLine
                Add-HashesToChangelog `
                    -ChangelogPath $releaseNotesPath `
                    -OutputDirectory $outputDir `
                    -Version $version `
                    -Architectures $Archs
            }
        }
    }
}
catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl+C was pressed - perform cleanup
    Set-BuildCancelled
    Invoke-CancellationCleanup `
        -TempDirectory $script:CleanupPaths.TempDirectory `
        -OutputDirectory $script:CleanupPaths.OutputDirectory `
        -ChangelogPath $script:CleanupPaths.ChangelogPath `
        -StartTime $script:CleanupPaths.StartTime
    exit 1
}
catch {
    Write-ErrorMessage -ErrorType 'FATAL' -Message "Unhandled error: $($_.Exception.Message)"
    
    if ($cfg.IsGitHubActions) {
        Write-GitHubActionsError -Message $_.Exception.ToString()
    }
    
    $buildSuccess = $false
}
finally {
    # Skip cleanup if build was cancelled (cancellation handler already cleaned up)
    if (Test-BuildCancelled) {
        exit 1
    }

    # ========================
    # Cleanup Child Processes
    # ========================
    # Clear tracked processes (they should have finished normally)
    Clear-ChildProcesses

    # ========================
    # Cleanup Temp Directory
    # ========================
    # Fixture-based runs keep the temp directory so the generated tree can be
    # inspected. A real build always cleans up.
    $keepTemp = $cfg.SkipDownload -or $cfg.OfflineMode
    if (-not $keepTemp -and (Test-Path $cfg.TempDirectory)) {
        Write-VerboseLog "Cleaning up temp directory: $($cfg.TempDirectory)"
        Remove-Item $cfg.TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif ($keepTemp) {
        Write-StatusInfo -Type 'Cleanup' -Message "Skipped (fixture mode) - Temp: $($cfg.TempDirectory)"
    }

    # ========================
    # Build Summary
    # ========================
    $buildDuration = (Get-Date) - $buildStartTime
    
    Write-BuildSummary `
        -Success $buildSuccess `
        -Version $version `
        -Architectures $Archs `
        -OutputPath $outputDir `
        -Duration $buildDuration

    if (-not $buildSuccess) {
        exit 1
    }
}
