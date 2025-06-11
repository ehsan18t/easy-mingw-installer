param(
    [Parameter(Mandatory = $true)]
    [string]$titlePattern,
    [Parameter(Mandatory = $true)]
    [string[]]$archs,
    [Parameter(Mandatory = $true)]
    [string[]]$namePatterns,
    [Parameter(Mandatory = $true)]
    [string]$outputPath,
    [Parameter(Mandatory = $true)]
    [string]$7ZipPath,
    [Parameter(Mandatory = $true)]
    [string]$InnoSetupPath,
    [Parameter(Mandatory = $false)]
    [switch]$checkNewRelease,
    [Parameter(Mandatory = $false)]
    [switch]$generateLogsAlways,
    [Parameter(Mandatory = $false)]
    [switch]$testMode
)

# --- Script Setup ---
$ErrorActionPreference = "Stop" # Exit on unhandled errors
. "$PSScriptRoot\modules\pretty.ps1"
. "$PSScriptRoot\modules\functions.ps1"

# --- Environment Preparation ---
Write-StatusInfo -Type "Script Start" -Message "Easy MinGW Installer Builder"
Write-SeparatorLine

# Handle array parameters passed as single comma-separated strings
if ($archs.Count -eq 1 -and $archs[0].Contains(',')) {
    $archs = $archs[0].Split(',') | ForEach-Object { $_.Trim() }
}
if ($namePatterns.Count -eq 1 -and $namePatterns[0].Contains(',')) {
    $namePatterns = $namePatterns[0].Split(',') | ForEach-Object { $_.Trim() }
}

$baseTempDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "EasyMinGWInstaller_Build"
if (Test-Path $baseTempDir) {
    Remove-DirectoryRecursive -Path $baseTempDir
}
New-Item -ItemType Directory -Path $baseTempDir -Force | Out-Null

$innoSetupScript = Join-Path -Path $PSScriptRoot -ChildPath "MinGW_Installer.iss"
if (-not (Test-Path $innoSetupScript -PathType Leaf)) {
    Write-ErrorMessage -ErrorType "CRITICAL CONFIG" -Message "Inno Setup script not found: $innoSetupScript"
    Exit 1
}

Write-LogEntry -Type "7-Zip Path" -Message $7ZipPath
Write-LogEntry -Type "InnoSetup Path" -Message $InnoSetupPath
Write-LogEntry -Type "InnoSetup Script" -Message $innoSetupScript
Write-LogEntry -Type "Base Temp Directory" -Message $baseTempDir
Write-LogEntry -Type "Final Output Directory" -Message $outputPath
Write-SeparatorLine

# --- Determine Versions and Release Info (ONCE) ---
$ProjectLatestTag = Get-LatestGitHubTag -Owner "ehsan18t" -Repo "easy-mingw-installer"
$WinLibsReleaseInfo = Find-GitHubRelease -Owner "brechtsanders" -Repo "winlibs_mingw" -TitlePattern "*-ucrt-*" # Adjust pattern as needed

if (-not $WinLibsReleaseInfo) {
    Write-ErrorMessage -ErrorType "Prerequisite Failed" -Message "Could not find a suitable WinLibs release. Exiting."
    exit 1
}
$CurrentReleaseVersionString = ConvertTo-VersionStringFromDate -DateString $WinLibsReleaseInfo.published_at -FormatType Version
Write-StatusInfo -Type "Overall Release Version" -Message $CurrentReleaseVersionString


# --- Process Architectures ---
$allArchBuildsSucceeded = $true
$primaryArchProcessedForChangelog = $false # Flag to ensure we only mark one as primary

foreach ($i in 0..($archs.Length - 1)) {
    $currentArch = $archs[$i]
    $currentPattern = $namePatterns[$i]
    Write-StatusInfo -Type "Starting Arch Loop" -Message "Processing $currentArch-bit with pattern '$currentPattern'"

    $isPrimary = $false
    if (-not $primaryArchProcessedForChangelog) { # Mark the first one in the loop as primary
        $isPrimary = $true
        $primaryArchProcessedForChangelog = $true 
    }

    $archResult = Process-MingwCompilation -Architecture $currentArch `
                        -AssetPattern $currentPattern `
                        -WinLibsReleaseInfo $WinLibsReleaseInfo `
                        -ProjectLatestTag $ProjectLatestTag `
                        -SevenZipExePath $7ZipPath `
                        -InnoSetupExePath $innoSetupExePath `
                        -FinalOutputPath $buildDir `
                        -TempDirectory $baseTempDir `
                        -InnoSetupScriptPath $innoSetupScript `
                        -SkipIfVersionMatchesTag:(-not $skipVersionMatchCheck.IsPresent) ` # Pass based on new global switch
                        -GenerateLogsAlways:$GenerateLogsAlways `
                        -IsTestMode:$IsTestMode `
                        -IsPrimaryArchForChangelogInfo:$isPrimary `
                        -CurrentReleaseVersionString $CurrentReleaseVersionString
    
    if (-not $archResult) {
        $allArchBuildsSucceeded = $false
        Write-ErrorMessage -ErrorType "Architecture Build Failed" -Message "Failed to process $currentArch-bit architecture."
        # Decide if you want to continue with other architectures or exit
        # For now, it continues
    }
}

# --- Generate Changelog (ONCE, after processing architectures) ---
$masterBuildInfoPath = Join-Path -Path $baseTempDir -ChildPath "master_build_info_for_changelog.txt"
$releaseNotesBodyFinalPath = Join-Path -Path $PSScriptRoot -ChildPath 'release_notes_body.md' # In repo root

if (Test-Path $masterBuildInfoPath) {
    Write-StatusInfo -Type "Global Changelog Generation" -Message "Attempting to generate release notes body..."
    $pythonPath = "python.exe" 
    $pythonScriptItself = Join-Path -Path "$PSScriptRoot\modules" -ChildPath "generate_changelog.py" 
    $effectivePrevTag = if ([string]::IsNullOrEmpty($ProjectLatestTag)) { "HEAD" } else { $ProjectLatestTag }

    $pythonScriptArgs = @(
        "--input-file", """$masterBuildInfoPath"""
        "--output-file", """$releaseNotesBodyFinalPath"""
        "--prev-tag", """$effectivePrevTag"""
        "--current-build-tag", """$CurrentReleaseVersionString"""
        "--github-owner", "ehsan18t"
        "--github-repo", "easy-mingw-installer"
    )
    $fullArgumentList = @($pythonScriptItself) + $pythonScriptArgs
    Write-LogEntry -Type "Python Call (Global)" -Message "$pythonPath $($fullArgumentList -join ' ')"
    
    try {
        $processInfo = Start-Process -FilePath $pythonPath -ArgumentList $fullArgumentList -Wait -NoNewWindow -PassThru -ErrorAction Stop
        if ($processInfo.ExitCode -ne 0) {
            Write-WarningMessage -Type "Changelog Gen Failed" -Message "Python script exited with code $($processInfo.ExitCode)."
        } elseif (Test-Path $releaseNotesBodyFinalPath) {
            Write-StatusInfo -Type "Changelog Generated" -Message "Global release notes body created at $releaseNotesBodyFinalPath"
        } else {
            Write-WarningMessage -Type "Changelog Gen Issue" -Message "Python script ran but output file $releaseNotesBodyFinalPath not found."
        }
    } catch {
        Write-WarningMessage -Type "Changelog Gen Error" -Message "Failed to execute Python script: $($_.Exception.Message)"
    }
} else {
    Write-WarningMessage -Type "Changelog Info Missing" -Message "Master build info file not found at '$masterBuildInfoPath'. Skipping changelog generation."
}

# --- Create Tag File for GitHub Actions (ONCE) ---
if ($env:GITHUB_ACTIONS -eq "true" -and $CurrentReleaseVersionString) {
    $tagFileDir = Join-Path $PSScriptRoot "tag" # In repo root
    if (-not (Test-Path $tagFileDir -PathType Container)) {
        New-Item -Path $tagFileDir -ItemType Directory -Force | Out-Null
    }
    New-Item -Path (Join-Path $tagFileDir $CurrentReleaseVersionString) -ItemType File -Force | Out-Null
    Write-LogEntry -Type "GitHub Actions" -Message "Global tag file for '$CurrentReleaseVersionString' created in $tagFileDir."
}

# --- Final Status ---
Write-SeparatorLine
if ($allArchBuildsSucceeded) {
    Write-StatusInfo -Type "Script End" -Message "All builds completed successfully."
    # Consider cleaning up $baseTempDir here if desired
    # Remove-DirectoryRecursive -Path $baseTempDir
} else {
    Write-ErrorMessage -ErrorType "Script End" -Message "One or more architecture builds failed."
}
