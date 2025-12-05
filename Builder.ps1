# ============================================================================
# Easy MinGW Installer - Main Build Script
# ============================================================================
# Entry point for building Easy MinGW Installer packages.
# Supports normal mode and test mode with granular control flags.
#
# Usage:
#   .\Builder.ps1 -TestMode                    # Test build
#   .\Builder.ps1 -Archs "64","32"             # Build both architectures
#   .\Builder.ps1 -CheckNewRelease             # Skip if already at latest
#
# Environment Variables:
#   EMI_LOG_LEVEL    - Logging verbosity: Verbose, Normal, Quiet
#   EMI_7ZIP_PATH    - Custom 7-Zip path
#   EMI_INNOSETUP_PATH - Custom Inno Setup path
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
if ($PSBoundParameters.ContainsKey('SkipDownload')) {
    $configOverrides['SkipDownload'] = $SkipDownload.IsPresent
}
if ($PSBoundParameters.ContainsKey('SkipBuild')) {
    $configOverrides['SkipBuild'] = $SkipBuild.IsPresent
}
if ($PSBoundParameters.ContainsKey('SkipChangelog')) {
    $configOverrides['SkipChangelog'] = $SkipChangelog.IsPresent
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
# Build Header & Info Display
# ============================================================================

Write-BuildHeader -Title 'Easy MinGW Installer Builder'

# Setup paths
$outputDir = if ($OutputPath) { $OutputPath } else { Join-Path $PSScriptRoot 'output' }
$issPath = Join-Path $PSScriptRoot 'MinGW_Installer.iss'
$releaseNotesPath = Join-Path $PSScriptRoot 'release_notes_body.md'

# Display build configuration
Write-BuildInfo -Config $cfg -Architectures $Archs -OutputPath $outputDir

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
        # Test mode: use mock data
        $version = $cfg.TestModeVersion
        $previousTag = $version
        $release = @{ name = 'Test Release'; assets = @() }
        
        Write-StatusInfo -Type 'Version' -Message "$version (test mode)"
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
        if ($buildSuccess -and -not $cfg.SkipBuild) {
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
catch {
    Write-ErrorMessage -ErrorType 'FATAL' -Message "Unhandled error: $($_.Exception.Message)"
    
    if ($cfg.IsGitHubActions) {
        Write-GitHubActionsError -Message $_.Exception.ToString()
    }
    
    $buildSuccess = $false
}
finally {
    # ========================
    # Cleanup
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
