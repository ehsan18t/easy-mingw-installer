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

    The script supports multiple modes:
    - NORMAL MODE: Full build with downloads, compilation, and output
    - TEST MODE: Uses mock fixtures for rapid pipeline testing
    - OFFLINE MODE: Skips network requests, uses existing files
    - CI MODE: Automatically detected in GitHub Actions environment

.PARAMETER TitlePattern
    Wildcard pattern to match WinLibs release titles (e.g., "*UCRT*POSIX*").
    This filters which GitHub release to use as the source.

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

.PARAMETER TestMode
    Enables test mode: uses mock data and test fixtures instead of real downloads.
    Useful for testing the build pipeline without network access.

.PARAMETER ValidateAssets
    When used with -TestMode, validates that release assets exist via API
    before proceeding with test fixtures.

.PARAMETER GenerateChangelog
    When used with -TestMode, fetches real release data to generate
    an actual changelog instead of a test placeholder.

.PARAMETER OfflineMode
    Skips all network requests. Use with existing downloaded files.

.PARAMETER CleanFirst
    Removes the temp directory before starting the build.

.PARAMETER CheckNewRelease
    Compares WinLibs version against project's latest tag.
    Skips build if versions match (already up-to-date).

.PARAMETER SkipDownload
    Skips downloading MinGW archives. Use existing files in temp.

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
    .\Builder.ps1 -TestMode
    # Test the build pipeline with mock data

.EXAMPLE
    .\Builder.ps1 -TestMode -ValidateAssets -GenerateChangelog
    # Test mode but validate real assets and generate real changelog

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
    # WinLibs release title pattern (e.g., "*UCRT*POSIX*")
    [Parameter()]
    [string]$TitlePattern = '*UCRT*POSIX*',

    # Architectures to build (e.g., @('64', '32'))
    [Parameter()]
    [string[]]$Archs = @('64'),

    # Asset name patterns for each architecture (regex)
    [Parameter()]
    [string[]]$NamePatterns = @('.*ucrt-runtime.*posix.*without-llvm.*\.7z$'),

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

    # Test mode: uses mock data and test fixtures instead of downloads
    [switch]$TestMode,

    # Validate that release assets exist (makes API calls, but doesn't download)
    [switch]$ValidateAssets,

    # Generate changelog in test mode (fetches real release for changelog generation)
    [switch]$GenerateChangelog,

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

# Build configuration overrides from parameters
$configOverrides = @{}

if ($TestMode) {
    $configOverrides['IsTestMode'] = $true
}
if ($PSBoundParameters.ContainsKey('ValidateAssets')) {
    $configOverrides['ValidateAssets'] = $ValidateAssets.IsPresent
}
if ($PSBoundParameters.ContainsKey('GenerateChangelog')) {
    $configOverrides['GenerateChangelog'] = $GenerateChangelog.IsPresent
    # GenerateChangelog implies we don't skip changelog
    if ($GenerateChangelog.IsPresent) {
        $configOverrides['SkipChangelog'] = $false
    }
}
if ($PSBoundParameters.ContainsKey('OfflineMode')) {
    $configOverrides['OfflineMode'] = $OfflineMode.IsPresent
    # Offline mode implies skip download and skip changelog
    if ($OfflineMode.IsPresent) {
        $configOverrides['SkipDownload'] = $true
        $configOverrides['SkipChangelog'] = $true
    }
}
if ($PSBoundParameters.ContainsKey('CleanFirst')) {
    $configOverrides['CleanFirst'] = $CleanFirst.IsPresent
}
if ($PSBoundParameters.ContainsKey('SkipDownload')) {
    $configOverrides['SkipDownload'] = $SkipDownload.IsPresent
}
if ($PSBoundParameters.ContainsKey('SkipBuild')) {
    $configOverrides['SkipBuild'] = $SkipBuild.IsPresent
}
if ($PSBoundParameters.ContainsKey('SkipChangelog')) {
    $configOverrides['SkipChangelog'] = $SkipChangelog.IsPresent
}
if ($PSBoundParameters.ContainsKey('SkipHashes')) {
    $configOverrides['SkipHashes'] = $SkipHashes.IsPresent
}
if ($PSBoundParameters.ContainsKey('GenerateLogsAlways')) {
    $configOverrides['GenerateLogsAlways'] = $GenerateLogsAlways.IsPresent
}
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

    if ($cfg.IsTestMode) {
        # Test mode: use mock data by default
        $version = $cfg.TestModeVersion
        $previousTag = $version
        $release = @{ name = 'Test Release'; assets = @() }
        
        # If ValidateAssets or GenerateChangelog is set, fetch real release data
        if ($cfg.ValidateAssets -or $cfg.GenerateChangelog) {
            Write-StatusInfo -Type 'Test Mode' -Message 'Fetching real release for validation/changelog...'
            
            $realRelease = Find-GitHubRelease -Owner $cfg.WinLibsOwner -Repo $cfg.WinLibsRepo -TitlePattern $TitlePattern
            if ($realRelease) {
                $release = $realRelease
                Write-StatusInfo -Type 'Real Release' -Message $realRelease.name
            }
            else {
                Write-WarningMessage -Type 'Validation' -Message "No release matches pattern: $TitlePattern"
            }
            
            # Get last 2 tags for changelog generation (compare between our releases)
            if ($cfg.GenerateChangelog) {
                $recentTags = Get-GitHubTags -Owner $cfg.ProjectOwner -Repo $cfg.ProjectRepo -Count 2
                if ($recentTags.Count -ge 2) {
                    # Use latest tag as version, second-to-last as previous
                    $version = $recentTags[0]
                    $previousTag = $recentTags[1]
                    Write-StatusInfo -Type 'Current Tag' -Message $version
                    Write-StatusInfo -Type 'Previous Tag' -Message $previousTag
                }
                elseif ($recentTags.Count -eq 1) {
                    $version = $recentTags[0]
                    $previousTag = $null
                    Write-StatusInfo -Type 'Current Tag' -Message $version
                    Write-WarningMessage -Type 'Changelog' -Message 'No previous tag found for comparison'
                }
                else {
                    Write-WarningMessage -Type 'Changelog' -Message 'No tags found - using test version'
                }
            }
            elseif ($realRelease) {
                # Just validating assets - use release date as version
                $publishedDate = [datetime]$realRelease.published_at
                $version = $publishedDate.ToString('yyyy.MM.dd')
                $releaseDate = $publishedDate.ToString('yyyy-MM-dd')
            }
        }
        else {
            Write-StatusInfo -Type 'Version' -Message "$version (test mode)"
        }
    }
    else {
        # Get project's latest tag for comparison
        if ($CheckNewRelease) {
            $previousTag = Get-LatestGitHubTag -Owner $cfg.ProjectOwner -Repo $cfg.ProjectRepo
            if ($previousTag) {
                Write-StatusInfo -Type 'Current Tag' -Message $previousTag
            }
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

        if ($cfg.IsGitHubActions) {
            # write file inside tags folder with the name of the version
            # NOTE: this must live outside $cfg.TempDirectory because temp is cleaned up in finally.
            $tagsDir = Join-Path -Path $PSScriptRoot -ChildPath 'tag'
            New-Item -ItemType Directory -Path $tagsDir -Force | Out-Null
            $versionFilePath = Join-Path -Path $tagsDir -ChildPath $version
            Set-Content -Path $versionFilePath -Value $version -Encoding utf8 -NoNewline
        }
    }

    # ========================
    # Version Check (Skip if up-to-date)
    # ========================
    if ($CheckNewRelease -and -not $cfg.IsTestMode -and $previousTag -eq $version) {
        Write-SeparatorLine -Character '=' -Length 50
        Write-SuccessMessage -Type 'Up to Date' -Message "Already at version $version - no build required"
        $buildSuccess = $true
    }
    else {
        # ========================
        # Build Each Architecture
        # ========================
        $buildSuccess = $true
        
        # In test mode with GenerateChangelog, pass current tag to fetch from GitHub
        $currentTagForChangelog = $null
        if ($cfg.IsTestMode -and $cfg.GenerateChangelog) {
            $currentTagForChangelog = $version
        }

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
                -CurrentTag $currentTagForChangelog `
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
    if (-not $cfg.IsTestMode -and (Test-Path $cfg.TempDirectory)) {
        Write-VerboseLog "Cleaning up temp directory: $($cfg.TempDirectory)"
        Remove-Item $cfg.TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif ($cfg.IsTestMode) {
        Write-StatusInfo -Type 'Cleanup' -Message "Skipped (test mode) - Temp: $($cfg.TempDirectory)"
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
