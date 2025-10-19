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
Ensure-Directory -Path $baseTempDir

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

# --- Main Build Logic ---
function Main {
    param(
        # Add parameters to Main to pass in the required info
        [Parameter(Mandatory=$true)]
        $WinLibsReleaseInfo,
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$ReleaseMetadata,
        [Parameter(Mandatory=$true)]
        [string]$ReleaseNotesPath,
        $ProjectLatestTag,
        [Parameter(Mandatory=$true)]
        [string[]]$Archs,
        [Parameter(Mandatory=$true)]
        [string[]]$NamePatterns,
        [Parameter(Mandatory=$true)]
        [string]$SevenZipPath,
        [Parameter(Mandatory=$true)]
        [string]$InnoSetupPath,
        [Parameter(Mandatory=$true)]
        [string]$FinalOutputPath,
        [Parameter(Mandatory=$true)]
        [string]$BaseTempDir,
        [Parameter(Mandatory=$true)]
        [string]$InnoSetupScriptPath,
        [Parameter(Mandatory=$true)]
        [switch]$SkipIfVersionMatchesTag,
        [Parameter(Mandatory=$true)]
        [switch]$GenerateLogsAlways,
        [Parameter(Mandatory=$true)]
        [switch]$IsTestMode
    )

    if ($Archs.Length -ne $NamePatterns.Length) {
        Write-ErrorMessage -ErrorType "CRITICAL CONFIG" -Message "Mismatch between the number of architectures and name patterns."
        # Returning false will cause the script to exit with an error code
        return $false
    }

    $overallSuccess = $true
    for ($i = 0; $i -lt $Archs.Length; $i++) {
        $currentArch = $Archs[$i]
        $currentPattern = $NamePatterns[$i]
        
        Write-StatusInfo -Type "Initiating Build" -Message "Architecture: $currentArch-bit, Pattern: $currentPattern"
        
        $buildSuccess = Process-MingwCompilation -Architecture $currentArch `
            -AssetPattern $currentPattern `
            -WinLibsReleaseInfo $WinLibsReleaseInfo `
            -ReleaseMetadata $ReleaseMetadata `
            -ReleaseNotesPath $ReleaseNotesPath `
            -ProjectLatestTag $ProjectLatestTag `
            -SevenZipExePath $SevenZipPath `
            -InnoSetupExePath $InnoSetupPath `
            -FinalOutputPath $FinalOutputPath `
            -TempDirectory $BaseTempDir `
            -InnoSetupScriptPath $InnoSetupScriptPath `
            -SkipIfVersionMatchesTag:$SkipIfVersionMatchesTag `
            -GenerateLogsAlways:$GenerateLogsAlways `
            -IsTestMode:$IsTestMode
        
        if (-not $buildSuccess) {
            Write-ErrorMessage -ErrorType "Architecture Build Failed" -Message "Failed to process $currentArch-bit architecture."
            $overallSuccess = $false
        }
    }

    return $overallSuccess
}

function Append-HashesToChangelog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ChangelogPath,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [Parameter(Mandatory = $true)]
        [string[]]$Archs
    )
    
    if (-not (Test-Path $ChangelogPath -PathType Leaf)) {
        Write-WarningMessage -Type "Hash Append" -Message "Changelog file not found at '$ChangelogPath'. Cannot append hashes."
        return
    }

    Write-StatusInfo -Type "Hash Append" -Message "Appending hashes to changelog..."
    
    $changelogContent = Get-Content $ChangelogPath -Raw -Encoding UTF8
    
    # Define the backticks as variables to avoid PowerShell interpretation
    $codeBlockStart = '```text'
    $codeBlockEnd = '```'
    
    foreach ($arch in $Archs) {
        $hashFileName = "EasyMinGW.Installer.v$($Version).$($arch)-bit.hashes.txt"
        $hashFilePath = Join-Path -Path $OutputPath -ChildPath $hashFileName
        $archHeaderMarkdown = "**$($arch)-bit**"
        
        if (Test-Path $hashFilePath -PathType Leaf) {
            # Check if this architecture's hash block already exists
            $searchPattern = [regex]::Escape($archHeaderMarkdown) + "\s*" + [regex]::Escape($codeBlockStart)
            if ($changelogContent -notmatch $searchPattern) {
                Write-StatusInfo -Type "Appending Hashes" -Message "For $arch-bit from $hashFileName"
                $hashBlockContent = Get-Content $hashFilePath -Raw -Encoding UTF8
                
                if ($null -ne $hashBlockContent) {
                    $hashBlockContent = $hashBlockContent.TrimEnd()
                    $fullHashBlockToAppend = "`n`n$archHeaderMarkdown`n$codeBlockStart`n$hashBlockContent`n$codeBlockEnd"
                    Add-Content -Path $ChangelogPath -Value $fullHashBlockToAppend -Encoding UTF8
                    $changelogContent = Get-Content $ChangelogPath -Raw -Encoding UTF8 # Update for next iteration
                } else {
                    Write-WarningMessage -Type "Hash Content Empty" -Message "Hash file '$hashFilePath' is empty. Not appending."
                }
            } else {
                Write-WarningMessage -Type "Hash Append Skip" -Message "Hash block for $arch-bit already found in changelog. Skipping append."
            }
        } else {
            Write-WarningMessage -Type "Hash File Missing" -Message "Hash file not found for $arch-bit at '$hashFilePath'. Cannot append."
        }
    }
}

# --- Script Execution & Cleanup ---
$scriptSuccess = $false
try {
    # This logic is moved from Main to the main script body
    Write-StatusInfo -Type "Main Process" -Message "Starting build operations..."

    $projectLatestTag = $null
    if ($checkNewRelease -and -not $testMode) {
        $projectLatestTag = Get-LatestGitHubTag -Owner "ehsan18t" -Repo "easy-mingw-installer"
        if (-not $projectLatestTag) {
            Write-WarningMessage -Type "Tag Check" -Message "Could not retrieve latest project tag. Version check might be affected."
        }
    } elseif ($testMode) {
        $projectLatestTag = "2024.10.05" # Example for testing version check logic
        Write-StatusInfo -Type "Tag (Test Mode)" -Message $projectLatestTag
    }

    $winLibsReleaseInfo = $null
    if (-not $testMode) {
        $winLibsReleaseInfo = Find-GitHubRelease -Owner "brechtsanders" -Repo "winlibs_mingw" -TitlePattern $titlePattern
        if (-not $winLibsReleaseInfo) {
            Write-ErrorMessage -ErrorType "CRITICAL" -Message "No matching WinLibs release found for pattern: $titlePattern. Cannot proceed."
            throw "No WinLibs release found." # Throw to trigger catch block
        }
    } else {
        Write-StatusInfo -Type "Release (Test Mode)" -Message "Skipping actual WinLibs release fetching."
        $winLibsReleaseInfo = [PSCustomObject]@{ name = "Test Release"; published_at = (Get-Date).ToString("o"); assets = @() }
    }

    $releaseMetadata = Get-ReleaseMetadata -ReleaseInfo $winLibsReleaseInfo -IsTestMode:$testMode
    $targetVersion = $releaseMetadata.Version
    if (-not $targetVersion) {
        Write-ErrorMessage -ErrorType "CRITICAL" -Message "Could not determine the global release version. Cannot proceed."
        throw "Could not determine global release version."
    }

    Write-StatusInfo -Type "Global Release Version" -Message "This build run targets version: $targetVersion"
    if (-not $testMode) {
        Write-StatusInfo -Type "Release Date" -Message $releaseMetadata.PublishedDateDisplay
    }

    $releaseNotesBodyPath = Join-Path -Path $PSScriptRoot -ChildPath 'release_notes_body.md'

    if ($checkNewRelease -and -not $testMode -and $projectLatestTag -eq $targetVersion) {
        Write-SeparatorLine
        Write-SuccessMessage -Type "Version Check" -Message "Project tag '$projectLatestTag' matches the latest release version. No new build is required."
        # Set success to true and the script will exit gracefully in the finally block
        $scriptSuccess = $true 
    } else {
        # Call Main with all necessary parameters
        $scriptSuccess = Main -WinLibsReleaseInfo $winLibsReleaseInfo `
                              -ReleaseMetadata $releaseMetadata `
                              -ReleaseNotesPath $releaseNotesBodyPath `
                              -ProjectLatestTag $projectLatestTag `
                              -Archs $archs `
                              -NamePatterns $namePatterns `
                              -SevenZipPath $7ZipPath `
                              -InnoSetupPath $InnoSetupPath `
                              -FinalOutputPath $outputPath `
                              -BaseTempDir $baseTempDir `
                              -InnoSetupScriptPath $innoSetupScript `
                              -SkipIfVersionMatchesTag:$checkNewRelease `
                              -GenerateLogsAlways:$generateLogsAlways `
                              -IsTestMode:$testMode

        # Append hashes to changelog after all builds are complete
        if ($scriptSuccess) {
            if (Test-Path $releaseNotesBodyPath -PathType Leaf) {
                Write-SeparatorLine
                Append-HashesToChangelog -ChangelogPath $releaseNotesBodyPath -OutputPath $outputPath -Version $targetVersion -Archs $archs
            } else {
                Write-WarningMessage -Type "Hash Append" -Message "Cannot append hashes: changelog file '$releaseNotesBodyPath' not found."
            }
        }
    }
}
catch {
    Write-ErrorMessage -ErrorType "FATAL SCRIPT ERROR" -Message "An unhandled error occurred: $($_.Exception.ToString())"
    $scriptSuccess = $false
}
finally {
    Write-SeparatorLine
    Write-StatusInfo -Type "Cleanup" -Message "Removing base temporary directory: $baseTempDir"
    Remove-DirectoryRecursive -Path $baseTempDir # Cleanup base temp dir
    
    if ($scriptSuccess) {
        Write-StatusInfo -Type "Script End" -Message "Build process completed successfully."
    } else {
        Write-ErrorMessage -ErrorType "Script End" -Message "Build process finished with errors."
        Exit 1 # Ensure a non-zero exit code for CI/CD or automation
    }
}
