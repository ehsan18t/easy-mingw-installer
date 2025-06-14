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

# --- Main Build Logic ---
function Main {
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
            Exit 1 # Critical failure, cannot build anything
        }
    } else {
        Write-StatusInfo -Type "Release (Test Mode)" -Message "Skipping actual WinLibs release fetching."
        # Create a dummy $winLibsReleaseInfo for test mode structure if needed by Process-MingwCompilation
        $winLibsReleaseInfo = [PSCustomObject]@{ name = "Test Release"; published_at = (Get-Date).ToString("o"); assets = @() }
    }

    # Determine the version that will be used for all builds
    $globalReleaseVersion = $null
    if ($testMode) {
        $globalReleaseVersion = "2030.10.10"
    } elseif ($winLibsReleaseInfo) {
        $globalReleaseVersion = ConvertTo-VersionStringFromDate -DateString $winLibsReleaseInfo.published_at -FormatType Version
    }
    
    if (-not $globalReleaseVersion) {
        Write-ErrorMessage -ErrorType "CRITICAL" -Message "Could not determine the global release version. Cannot proceed."
        Exit 1
    }
    
    Write-StatusInfo -Type "Global Release Version" -Message "This build run targets version: $globalReleaseVersion"

    if ($archs.Length -ne $namePatterns.Length) {
        Write-ErrorMessage -ErrorType "CRITICAL CONFIG" -Message "Mismatch between the number of architectures and name patterns."
        Exit 1
    }

    $overallSuccess = $true
    for ($i = 0; $i -lt $archs.Length; $i++) {
        $currentArch = $archs[$i]
        $currentPattern = $namePatterns[$i]
        
        Write-StatusInfo -Type "Initiating Build" -Message "Architecture: $currentArch-bit, Pattern: $currentPattern"
        
        $buildSuccess = Process-MingwCompilation -Architecture $currentArch `
            -AssetPattern $currentPattern `
            -WinLibsReleaseInfo $winLibsReleaseInfo `
            -ProjectLatestTag $projectLatestTag `
            -SevenZipExePath $7ZipPath `
            -InnoSetupExePath $InnoSetupPath `
            -FinalOutputPath $outputPath `
            -TempDirectory $baseTempDir `
            -InnoSetupScriptPath $innoSetupScript `
            -SkipIfVersionMatchesTag:$checkNewRelease `
            -GenerateLogsAlways:$generateLogsAlways `
            -IsTestMode:$testMode
        
        if (-not $buildSuccess) {
            Write-ErrorMessage -ErrorType "Architecture Build Failed" -Message "Failed to process $currentArch-bit architecture."
            $overallSuccess = $false
        }
    }

    # Append hashes to changelog after all builds are complete
    if ($overallSuccess) {
        $releaseNotesBodyPath = Join-Path -Path $PSScriptRoot -ChildPath 'release_notes_body.md'
        if (Test-Path $releaseNotesBodyPath -PathType Leaf) {
            Write-SeparatorLine
            Append-HashesToChangelog -ChangelogPath $releaseNotesBodyPath -OutputPath $outputPath -Version $globalReleaseVersion -Archs $archs
        } else {
            Write-WarningMessage -Type "Hash Append" -Message "Cannot append hashes: changelog file '$releaseNotesBodyPath' not found."
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
        $hashFileName = "EasyMinGW.v$($Version).$($arch)-bit.hashes.txt"
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
    $scriptSuccess = Main
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
