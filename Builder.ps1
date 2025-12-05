# ============================================================================
# Easy MinGW Installer - Main Build Script
# ============================================================================
# Entry point for building Easy MinGW Installer packages.
# Supports normal mode and test mode with granular control flags.
# ============================================================================

[CmdletBinding()]
param(
    # WinLibs release title pattern (e.g., "*UCRT*POSIX*Win64*14*")
    [Parameter(Mandatory = $false)]
    [string]$TitlePattern = '*UCRT*POSIX*',

    # Architectures to build (e.g., @('64', '32'))
    [Parameter(Mandatory = $false)]
    [string[]]$Archs = @('64'),

    # Asset name patterns for each architecture
    [Parameter(Mandatory = $false)]
    [string[]]$NamePatterns = @('.*ucrt-runtime.*posix.*without-llvm.*\.7z$'),

    # Output directory for built installers
    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    # Path to 7-Zip executable (auto-detected if not specified)
    [Parameter(Mandatory = $false)]
    [string]$SevenZipPath,

    # Path to Inno Setup compiler (auto-detected if not specified)
    [Parameter(Mandatory = $false)]
    [string]$InnoSetupPath,

    # ========================
    # MODE SWITCHES
    # ========================
    
    # Test mode: enables all skip flags and uses mock data
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
    
    # Offline mode: don't make any network requests
    [switch]$OfflineMode,
    
    # Always generate Inno Setup build logs
    [switch]$GenerateLogsAlways,

    # Clean temp directories before starting
    [switch]$CleanFirst
)

# ============================================================================
# Module Loading
# ============================================================================

$ErrorActionPreference = 'Stop'

# Load modules in order
. "$PSScriptRoot\modules\config.ps1"
. "$PSScriptRoot\modules\pretty.ps1"
. "$PSScriptRoot\modules\functions.ps1"

# ============================================================================
# Parameter Processing
# ============================================================================

# Handle array parameters passed as single comma-separated strings
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
    # Test mode enables all skip flags
    $configOverrides['IsTestMode'] = $true
    $configOverrides['SkipDownload'] = $true
    $configOverrides['SkipChangelog'] = $true
    $configOverrides['OfflineMode'] = $true
}

# Allow individual flags to override test mode defaults
if ($PSBoundParameters.ContainsKey('SkipDownload')) {
    $configOverrides['SkipDownload'] = $SkipDownload.IsPresent
}
if ($PSBoundParameters.ContainsKey('SkipBuild')) {
    $configOverrides['SkipBuild'] = $SkipBuild.IsPresent
}
if ($PSBoundParameters.ContainsKey('SkipChangelog')) {
    $configOverrides['SkipChangelog'] = $SkipChangelog.IsPresent
}
if ($PSBoundParameters.ContainsKey('OfflineMode')) {
    $configOverrides['OfflineMode'] = $OfflineMode.IsPresent
}

# Tool paths (parameters override env vars override auto-detection)
if ($SevenZipPath) {
    $configOverrides['SevenZipPath'] = $SevenZipPath
}
if ($InnoSetupPath) {
    $configOverrides['InnoSetupPath'] = $InnoSetupPath
}

# Initialize configuration
$null = Initialize-BuildConfig -Overrides $configOverrides

# Get active configuration
$config = Get-BuildConfig

# ============================================================================
# Environment Validation
# ============================================================================

Write-StatusInfo -Type 'Script Start' -Message 'Easy MinGW Installer Builder'
Write-SeparatorLine

# Display mode info
if ($config.IsTestMode) {
    Write-StatusInfo -Type 'Mode' -Message 'TEST MODE - Using mock data and test fixtures'
}
if ($config.OfflineMode) {
    Write-StatusInfo -Type 'Mode' -Message 'OFFLINE MODE - No network requests'
}

# Show active flags
$activeFlags = @()
if ($config.SkipDownload) { $activeFlags += 'SkipDownload' }
if ($config.SkipBuild) { $activeFlags += 'SkipBuild' }
if ($config.SkipChangelog) { $activeFlags += 'SkipChangelog' }
if ($activeFlags.Count -gt 0) {
    Write-StatusInfo -Type 'Active Flags' -Message ($activeFlags -join ', ')
}

# Validate dependencies
$dependencyCheck = Test-BuildDependencies
if (-not $dependencyCheck.Success) {
    foreach ($error in $dependencyCheck.Errors) {
        Write-ErrorMessage -ErrorType 'Dependency Error' -Message $error
    }
    Write-ErrorMessage -ErrorType 'CRITICAL' -Message 'Required dependencies are missing. Cannot proceed.'
    exit 1
}

# Set up paths
$baseTempDir = $config.TempDirectory
$outputDir = if ($OutputPath) { $OutputPath } else { Join-Path $PSScriptRoot 'output' }
$innoSetupScript = Join-Path $PSScriptRoot 'MinGW_Installer.iss'

# Validate Inno Setup script
if (-not $config.SkipBuild -and -not (Test-Path $innoSetupScript -PathType Leaf)) {
    Write-ErrorMessage -ErrorType 'CRITICAL CONFIG' -Message "Inno Setup script not found: $innoSetupScript"
    exit 1
}

# Clean temp directory if requested
if ($CleanFirst -and (Test-Path $baseTempDir)) {
    Remove-DirectoryRecursive -Path $baseTempDir
}
Ensure-Directory -Path $baseTempDir
Ensure-Directory -Path $outputDir

# Log configuration
Write-LogEntry -Type '7-Zip Path' -Message $config.SevenZipPath
Write-LogEntry -Type 'InnoSetup Path' -Message $config.InnoSetupPath
Write-LogEntry -Type 'Temp Directory' -Message $baseTempDir
Write-LogEntry -Type 'Output Directory' -Message $outputDir
Write-SeparatorLine

# ============================================================================
# Helper Functions
# ============================================================================

function Append-HashesToChangelog {
    <#
    .SYNOPSIS
        Appends hash file contents to the changelog.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ChangelogPath,
        
        [Parameter(Mandatory)]
        [string]$OutputDir,
        
        [Parameter(Mandatory)]
        [string]$Version,
        
        [Parameter(Mandatory)]
        [string[]]$Archs
    )
    
    if (-not (Test-Path $ChangelogPath -PathType Leaf)) {
        Write-WarningMessage -Type 'Hash Append' -Message "Changelog file not found at '$ChangelogPath'. Cannot append hashes."
        return
    }

    Write-StatusInfo -Type 'Hash Append' -Message 'Appending hashes to changelog...'
    
    $cfg = Get-BuildConfig
    $changelogContent = Get-Content $ChangelogPath -Raw -Encoding UTF8
    
    $codeBlockStart = '```text'
    $codeBlockEnd = '```'
    
    foreach ($arch in $Archs) {
        $hashFileName = "$($cfg.InstallerBaseName).v$Version.$arch-bit.hashes.txt"
        $hashFilePath = Join-Path $OutputDir $hashFileName
        $archHeaderMarkdown = "**$arch-bit**"
        
        if (Test-Path $hashFilePath -PathType Leaf) {
            # Check if this architecture's hash block already exists
            $searchPattern = [regex]::Escape($archHeaderMarkdown) + '\s*' + [regex]::Escape($codeBlockStart)
            if ($changelogContent -notmatch $searchPattern) {
                Write-StatusInfo -Type 'Appending Hashes' -Message "For $arch-bit from $hashFileName"
                $hashBlockContent = Get-Content $hashFilePath -Raw -Encoding UTF8
                
                if ($hashBlockContent) {
                    $hashBlockContent = $hashBlockContent.TrimEnd()
                    $fullHashBlockToAppend = "`n`n$archHeaderMarkdown`n$codeBlockStart`n$hashBlockContent`n$codeBlockEnd"
                    Add-Content -Path $ChangelogPath -Value $fullHashBlockToAppend -Encoding UTF8
                    $changelogContent = Get-Content $ChangelogPath -Raw -Encoding UTF8
                }
                else {
                    Write-WarningMessage -Type 'Hash Content Empty' -Message "Hash file '$hashFilePath' is empty. Not appending."
                }
            }
            else {
                Write-WarningMessage -Type 'Hash Append Skip' -Message "Hash block for $arch-bit already found in changelog."
            }
        }
        else {
            Write-WarningMessage -Type 'Hash File Missing' -Message "Hash file not found for $arch-bit at '$hashFilePath'."
        }
    }
}

function Invoke-BuildPipeline {
    <#
    .SYNOPSIS
        Main build pipeline orchestration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Architectures,
        
        [Parameter(Mandatory)]
        [string[]]$AssetPatterns,
        
        [Parameter(Mandatory)]
        [PSCustomObject]$ReleaseMetadata,
        
        [PSCustomObject]$ReleaseInfo,
        [string]$ProjectLatestTag,
        
        [Parameter(Mandatory)]
        [string]$OutputDirectory,
        
        [Parameter(Mandatory)]
        [string]$TempDirectory,
        
        [Parameter(Mandatory)]
        [string]$InnoSetupScriptPath,
        
        [Parameter(Mandatory)]
        [string]$ReleaseNotesPath,
        
        [switch]$SkipIfVersionMatchesTag,
        [switch]$GenerateLogs
    )

    if ($Architectures.Length -ne $AssetPatterns.Length) {
        Write-ErrorMessage -ErrorType 'CRITICAL CONFIG' -Message 'Mismatch between the number of architectures and name patterns.'
        return $false
    }

    $overallSuccess = $true
    
    for ($i = 0; $i -lt $Architectures.Length; $i++) {
        $currentArch = $Architectures[$i]
        $currentPattern = $AssetPatterns[$i]
        
        Write-StatusInfo -Type 'Initiating Build' -Message "Architecture: $currentArch-bit, Pattern: $currentPattern"
        
        $buildSuccess = Invoke-MingwCompilation `
            -Architecture $currentArch `
            -AssetPattern $currentPattern `
            -ReleaseMetadata $ReleaseMetadata `
            -ReleaseInfo $ReleaseInfo `
            -ProjectLatestTag $ProjectLatestTag `
            -FinalOutputPath $OutputDirectory `
            -TempDirectory $TempDirectory `
            -InnoSetupScriptPath $InnoSetupScriptPath `
            -ReleaseNotesPath $ReleaseNotesPath `
            -SkipIfVersionMatchesTag:$SkipIfVersionMatchesTag `
            -GenerateLogsAlways:$GenerateLogs
        
        if (-not $buildSuccess) {
            Write-ErrorMessage -ErrorType 'Architecture Build Failed' -Message "Failed to process $currentArch-bit architecture."
            $overallSuccess = $false
        }
    }

    return $overallSuccess
}

# ============================================================================
# Main Execution
# ============================================================================

$scriptSuccess = $false

try {
    Write-StatusInfo -Type 'Main Process' -Message 'Starting build operations...'

    # Get project's latest tag for version comparison
    $projectLatestTag = $null
    if ($CheckNewRelease -and -not $config.OfflineMode) {
        $projectLatestTag = Get-LatestGitHubTag -Owner $config.ProjectOwner -Repo $config.ProjectRepo
        if (-not $projectLatestTag) {
            Write-WarningMessage -Type 'Tag Check' -Message 'Could not retrieve latest project tag. Version check might be affected.'
        }
    }
    elseif ($config.IsTestMode) {
        $projectLatestTag = $config.TestModeVersion
        Write-StatusInfo -Type 'Tag (Test Mode)' -Message $projectLatestTag
    }

    # Get WinLibs release info
    $winLibsReleaseInfo = $null
    if (-not $config.OfflineMode -and -not $config.IsTestMode) {
        $winLibsReleaseInfo = Find-GitHubRelease -Owner $config.WinLibsOwner -Repo $config.WinLibsRepo -TitlePattern $TitlePattern
        if (-not $winLibsReleaseInfo) {
            Write-ErrorMessage -ErrorType 'CRITICAL' -Message "No matching WinLibs release found for pattern: $TitlePattern"
            throw 'No WinLibs release found.'
        }
    }
    elseif ($config.IsTestMode) {
        Write-StatusInfo -Type 'Release (Test Mode)' -Message 'Using mock release data'
        $winLibsReleaseInfo = [PSCustomObject]@{
            name         = 'Test Release'
            published_at = (Get-Date).ToString('o')
            assets       = @()
        }
    }
    else {
        Write-StatusInfo -Type 'Release (Offline)' -Message 'Skipping release fetch in offline mode'
        # In offline mode without test mode, we need release info
        # This should be rare - typically offline mode implies test mode
        $winLibsReleaseInfo = [PSCustomObject]@{
            name         = 'Offline Mode Release'
            published_at = (Get-Date).ToString('o')
            assets       = @()
        }
    }

    # Get release metadata
    $releaseMetadata = Get-ReleaseMetadata -ReleaseInfo $winLibsReleaseInfo -IsTestMode:$config.IsTestMode
    $targetVersion = $releaseMetadata.Version
    
    if (-not $targetVersion) {
        Write-ErrorMessage -ErrorType 'CRITICAL' -Message 'Could not determine the release version. Cannot proceed.'
        throw 'Could not determine release version.'
    }

    Write-StatusInfo -Type 'Target Version' -Message $targetVersion
    if (-not $config.IsTestMode -and $releaseMetadata.PublishedDateDisplay) {
        Write-StatusInfo -Type 'Release Date' -Message $releaseMetadata.PublishedDateDisplay
    }

    $releaseNotesPath = Join-Path $PSScriptRoot 'release_notes_body.md'

    # Version check for skip
    if ($CheckNewRelease -and -not $config.IsTestMode -and $projectLatestTag -eq $targetVersion) {
        Write-SeparatorLine
        Write-SuccessMessage -Type 'Version Check' -Message "Project tag '$projectLatestTag' matches the latest release version. No new build required."
        $scriptSuccess = $true
    }
    else {
        # Run build pipeline
        $scriptSuccess = Invoke-BuildPipeline `
            -Architectures $Archs `
            -AssetPatterns $NamePatterns `
            -ReleaseMetadata $releaseMetadata `
            -ReleaseInfo $winLibsReleaseInfo `
            -ProjectLatestTag $projectLatestTag `
            -OutputDirectory $outputDir `
            -TempDirectory $baseTempDir `
            -InnoSetupScriptPath $innoSetupScript `
            -ReleaseNotesPath $releaseNotesPath `
            -SkipIfVersionMatchesTag:$CheckNewRelease `
            -GenerateLogs:$GenerateLogsAlways

        # Append hashes to changelog after all builds complete
        if ($scriptSuccess -and -not $config.SkipBuild) {
            if (Test-Path $releaseNotesPath -PathType Leaf) {
                Write-SeparatorLine
                Append-HashesToChangelog `
                    -ChangelogPath $releaseNotesPath `
                    -OutputDir $outputDir `
                    -Version $targetVersion `
                    -Archs $Archs
            }
            else {
                Write-WarningMessage -Type 'Hash Append' -Message "Cannot append hashes: changelog file not found at '$releaseNotesPath'"
            }
        }
    }
}
catch {
    Write-ErrorMessage -ErrorType 'FATAL SCRIPT ERROR' -Message "An unhandled error occurred: $($_.Exception.Message)"
    if ($config.IsGitHubActions) {
        Write-GitHubActionsError -Message $_.Exception.ToString()
    }
    $scriptSuccess = $false
}
finally {
    Write-SeparatorLine
    
    # Cleanup temp directory (skip in test mode to allow inspection)
    if (-not $config.IsTestMode -and (Test-Path $baseTempDir)) {
        Write-StatusInfo -Type 'Cleanup' -Message "Removing temporary directory: $baseTempDir"
        Remove-DirectoryRecursive -Path $baseTempDir
    }
    elseif ($config.IsTestMode) {
        Write-StatusInfo -Type 'Cleanup' -Message "Skipping cleanup in test mode. Temp dir: $baseTempDir"
    }
    
    # Final status
    Write-SeparatorLine
    if ($scriptSuccess) {
        Write-SuccessMessage -Type 'Script End' -Message 'Build process completed successfully.'
    }
    else {
        Write-ErrorMessage -ErrorType 'Script End' -Message 'Build process finished with errors.'
        exit 1
    }
}
