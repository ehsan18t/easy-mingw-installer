function Invoke-GitHubApi {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Headers = @{ "Accept" = "application/vnd.github.v3+json" },
        [int]$TimeoutSec = 30
    )
    try {
        Write-LogEntry -Type "GitHub API" -Message "Requesting $Uri"
        $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $response
    }
    catch {
        Write-ErrorMessage -ErrorType "API Request Failed" -Message "Error fetching '$Uri': $($_.Exception.Message)"
        return $null
    }
}

function Get-LatestGitHubTag {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Owner,
        [Parameter(Mandatory = $true)]
        [string]$Repo
    )
    $tagsUrl = "https://api.github.com/repos/$Owner/$Repo/tags"
    $tagsInfo = Invoke-GitHubApi -Uri $tagsUrl
    if ($tagsInfo -and $tagsInfo.Count -gt 0) {
        Write-StatusInfo -Type "Latest Tag" -Message "$($tagsInfo[0].name) (for $Owner/$Repo)"
        return $tagsInfo[0].name
    }
    Write-WarningMessage -Type "API Warning" -Message "No tags found for $Owner/$Repo."
    return $null
}

function Find-GitHubRelease {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Owner,
        [Parameter(Mandatory = $true)]
        [string]$Repo,
        [Parameter(Mandatory = $true)]
        [string]$TitlePattern
    )
    $releasesUrl = "https://api.github.com/repos/$Owner/$Repo/releases"
    $releasesInfo = Invoke-GitHubApi -Uri $releasesUrl
    $selectedRelease = $null

    if ($releasesInfo) {
        foreach ($release in $releasesInfo) {
            if ($release.name -like $TitlePattern -and -not $release.prerelease) {
                if (-not $selectedRelease -or ([datetime]$release.published_at) -gt ([datetime]$selectedRelease.published_at)) {
                    $selectedRelease = $release
                }
            }
        }
    }

    if ($selectedRelease) {
        Write-StatusInfo -Type "Selected Release" -Message "$($selectedRelease.name) (from $Owner/$Repo)"
        $parsedTime = ConvertTo-VersionStringFromDate -DateString $selectedRelease.published_at -FormatType Display
        Write-StatusInfo -Type "Release Date" -Message $parsedTime
    } else {
        Write-WarningMessage -Type "Release Search" -Message "No release found matching pattern '$TitlePattern' for $Owner/$Repo."
    }
    return $selectedRelease
}

function ConvertTo-VersionStringFromDate {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$DateString,
        [ValidateSet("Version", "Display")]
        [string]$FormatType = "Display"
    )
    try {
        $dateObject = Get-Date -Date $DateString
        if ($FormatType -eq "Version") {
            return $dateObject.ToString("yyyy.MM.dd")
        }
        return $dateObject.ToString("dd-MMM-yyyy HH:mm:ss")
    }
    catch {
        Write-WarningMessage -Type "Date Format" -Message "Could not parse date string '$DateString': $($_.Exception.Message)"
        return $DateString # Return original if parsing fails
    }
}

function Invoke-DownloadFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string]$DestinationFile,
        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3,
        [Parameter(Mandatory = $false)]
        [int]$RetryDelaySeconds = 5,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60
    )

    Write-ActionProgress -ActionName "Preparing Download" -Details "From: $Url"
    # Destination message can be removed if too verbose, or kept.
    # Write-ActionProgress -ActionName "Destination" -Details $DestinationFile 

    $userAgent = "Easy-MinGW-Installer-Builder-Script/1.0"
    $isGitHubActions = $env:GITHUB_ACTIONS -eq "true"
    $currentTry = 0
    $downloadSuccess = $false

    while ($currentTry -lt $MaxRetries -and -not $downloadSuccess) {
        $currentTry++
        if ($currentTry -gt 1) {
            Write-WarningMessage -Type "Download Retry" -Message "Attempt $($currentTry) of $($MaxRetries) after $($RetryDelaySeconds) seconds..."
            Start-Sleep -Seconds $RetryDelaySeconds
        }

        # Initial download message for the current attempt (not updating)
        if (-not $isGitHubActions) {
            Write-LogEntry -Type "Download" -Message "Starting download attempt $currentTry for $Url..."
        }


        $webRequest = $null
        $response = $null
        $responseStream = $null
        $targetStream = $null

        try {
            $webRequest = [System.Net.HttpWebRequest]::Create($Url)
            $webRequest.UserAgent = $userAgent
            $webRequest.Timeout = $TimeoutSeconds * 1000

            $response = $webRequest.GetResponse()
            $totalLength = $response.ContentLength
            $totalLengthKB = [System.Math]::Floor($totalLength / 1024)
            $responseStream = $response.GetResponseStream()

            $targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $DestinationFile, 'Create'
            $buffer = New-Object byte[] 80KB
            $downloadedBytes = 0
            $lastReportedProgressPercentage = -1

            while ($true) {
                $bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)
                if ($bytesRead -eq 0) { break }

                $targetStream.Write($buffer, 0, $bytesRead)
                $downloadedBytes += $bytesRead

                if (-not $isGitHubActions -and $totalLength -gt 0) {
                    $currentProgressPercentage = [System.Math]::Floor(($downloadedBytes / $totalLength) * 100)
                    if ($currentProgressPercentage -gt $lastReportedProgressPercentage) {
                        # Construct the full progress string for the updating line
                        $progressText = "    Progress (Attempt $currentTry): $([System.Math]::Floor($downloadedBytes / 1024))KB / ${totalLengthKB}KB ($currentProgressPercentage%)"
                        Write-UpdatingLine -Text $progressText # Use the new function
                        $lastReportedProgressPercentage = $currentProgressPercentage
                    }
                }
            }
            
            if (-not $isGitHubActions) {
                End-UpdatingLine # Finalize the updating line by printing a newline
            }

            Write-ColoredHost -Text "    Download successful: $DestinationFile (Attempt $currentTry)" -ForegroundColor $script:colors.Green
            $downloadSuccess = $true
        }
        catch [System.Net.WebException] {
            if (-not $isGitHubActions) { End-UpdatingLine } # Ensure newline if error occurs mid-progress
            $ex = $_.Exception
            $errorMessage = "WebException during download (Attempt $currentTry): $($ex.Message)"
            if ($ex.Response) {
                $statusCode = [int]$ex.Response.StatusCode
                $statusDescription = $ex.Response.StatusDescription
                $errorMessage += " | Status: $statusCode ($statusDescription)"
            }
            Write-ErrorMessage -ErrorType "Download Attempt Failed" -Message $errorMessage
            if ($ex.Response) { $ex.Response.Dispose() }
        }
        catch {
            if (-not $isGitHubActions) { End-UpdatingLine } # Ensure newline if error occurs mid-progress
            Write-ErrorMessage -ErrorType "Download Attempt Failed" -Message "Generic error during download (Attempt $currentTry): $($_.Exception.Message)"
        }
        finally {
            if ($targetStream) { $targetStream.Dispose() }
            if ($responseStream) { $responseStream.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }

    if (-not $downloadSuccess) {
        Write-ErrorMessage -ErrorType "Download Failed" -Message "Failed to download '$Url' after $MaxRetries attempts."
    }
    return $downloadSuccess
}

function Start-SevenZipExtraction {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $true)]
        [string]$SevenZipExePath
    )
    Write-ActionProgress -ActionName "Extracting" -Details $ArchivePath
    if (-not (Test-Path $SevenZipExePath -PathType Leaf)) {
        Write-ErrorMessage -ErrorType "Configuration Error" -Message "7-Zip executable not found at '$SevenZipExePath'."
        throw "7-Zip not found at $SevenZipExePath"
    }
    $arguments = "x `"$ArchivePath`" -o`"$DestinationPath`" -y"
    try {
        $process = Start-Process -FilePath $SevenZipExePath -ArgumentList $arguments -Wait -NoNewWindow -PassThru -ErrorAction Stop
        if ($process.ExitCode -eq 0) {
            Write-ColoredHost -Text "    Extraction complete to $DestinationPath" -ForegroundColor $script:colors.Green
            return $true
        }
        Write-ErrorMessage -ErrorType "Extraction Failed" -Message "7-Zip failed for '$ArchivePath'. Exit Code: $($process.ExitCode)"
        return $false
    }
    catch {
        Write-ErrorMessage -ErrorType "Process Error" -Message "Exception during 7-Zip execution: $($_.Exception.Message)"
        throw # Re-throw to indicate critical failure
    }
}

function Remove-DirectoryRecursive {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if (Test-Path $Path) {
        Write-ActionProgress -ActionName "Cleaning" -Details "Removing directory $Path"
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-ColoredHost -Text "    Successfully removed $Path" -ForegroundColor $script:colors.Green
        }
        catch {
            Write-WarningMessage -Type "Cleanup Warning" -Message "Failed to remove folder '$Path': $($_.Exception.Message)"
        }
    }
}

function Build-InnoSetupInstaller {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$InstallerName,
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [Parameter(Mandatory = $true)]
        [string]$Architecture,
        [Parameter(Mandatory = $true)]
        [string]$SourceContentPath,
        [Parameter(Mandatory = $true)]
        [string]$InnoSetupExePath,
        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory,
        [Parameter(Mandatory = $true)]
        [string]$InnoSetupScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$SevenZipExePath, # Added for hash generation
        [Parameter(Mandatory = $false)]
        [bool]$GenerateLogsAlways = $false
    )
    Write-ActionProgress -ActionName "Building Installer" -Details "$InstallerName $Version ($Architecture)"
    $logFileName = "build_${InstallerName}_${Architecture}.log"
    $logFilePath = Join-Path -Path $PSScriptRoot -ChildPath "..\$logFileName"

    $arguments = "/DMyAppName=`"$InstallerName`" /DMyAppVersion=`"$Version`" /DArch=`"$Architecture`" /DSourcePath=`"$SourceContentPath`" /DOutputPath=`"$OutputDirectory`""
    
    $stdOutFile = $null
    $stdErrFile = $null
    $installerBuiltSuccessfully = $false
    $installerExeName = "$($InstallerName).v$($Version).$($Architecture)-bit.exe"
    $installerExeFullPath = Join-Path -Path $OutputDirectory -ChildPath $installerExeName

    try {
        if (-not (Test-Path $OutputDirectory)) {
            New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
        }

        $stdOutFile = [System.IO.Path]::GetTempFileName()
        $stdErrFile = [System.IO.Path]::GetTempFileName()

        $process = Start-Process -FilePath $InnoSetupExePath -ArgumentList $InnoSetupScriptPath, $arguments `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput $stdOutFile -RedirectStandardError $stdErrFile -ErrorAction Stop
        
        $exitCode = $process.ExitCode
        $stdOutContent = Get-Content $stdOutFile -Raw -ErrorAction SilentlyContinue
        $stdErrContent = Get-Content $stdErrFile -Raw -ErrorAction SilentlyContinue

        if ($exitCode -ne 0 -or $GenerateLogsAlways) {
            $logContent = "Timestamp: $(Get-Date -Format 'u')`nInno Setup Arguments: $arguments`n`nStandard Output:`n$stdOutContent`n`nStandard Error:`n$stdErrContent`nExit Code: $exitCode"
            Set-Content -Path $logFilePath -Value $logContent -Encoding UTF8
            if ($exitCode -ne 0) {
                Write-ErrorMessage -ErrorType "Build Failed" -Message "$InstallerName ($Architecture) compilation failed." -LogFilePath $logFilePath -AssociatedExitCode $exitCode
                return $false
            }
            Write-ColoredHost -Text "    Build Succeeded (Log generated): $InstallerName ($Architecture)" -ForegroundColor $script:colors.Green
            Write-StatusInfo -Type "Log File" -Message $logFilePath
            $installerBuiltSuccessfully = $true
        } else {
            Write-ColoredHost -Text "    Build Succeeded: $InstallerName ($Architecture)" -ForegroundColor $script:colors.Green
            $installerBuiltSuccessfully = $true
        }

        # Generate hashes if installer was built successfully
        if ($installerBuiltSuccessfully -and (Test-Path $installerExeFullPath -PathType Leaf)) {
            Write-StatusInfo -Type "Hash Generation" -Message "Generating hashes for $installerExeName..."
            $hashFileName = "$($InstallerName).v$($Version).$($Architecture)-bit.hashes.txt"
            $hashOutputFilePath = Join-Path -Path $OutputDirectory -ChildPath $hashFileName
            $formatHashesScriptPath = Join-Path -Path $PSScriptRoot -ChildPath "Format-7ZipHashes.ps1"

            if (-not (Test-Path $formatHashesScriptPath -PathType Leaf)) {
                Write-WarningMessage -Type "Hash Script Missing" -Message "Format-7ZipHashes.ps1 not found at '$formatHashesScriptPath'. Skipping hash generation."
            } else {
                try {
                    # Call the Format-7ZipHashes.ps1 script and save output to hash file
                    & $formatHashesScriptPath -FilePath $installerExeFullPath -SevenZipExePath $SevenZipExePath | Out-File -FilePath $hashOutputFilePath -Encoding utf8 -Force
                    Write-StatusInfo -Type "Hash File" -Message "Hashes saved to $hashOutputFilePath"
                } catch {
                    Write-WarningMessage -Type "Hash Gen Error" -Message "Failed to generate or save hashes for $installerExeName : $($_.Exception.Message)"
                }
            }
        } elseif ($installerBuiltSuccessfully) {
            Write-WarningMessage -Type "Hash Skip" -Message "Installer EXE not found at '$installerExeFullPath'. Skipping hash generation."
        }

        return $installerBuiltSuccessfully
    }
    catch {
        Write-ErrorMessage -ErrorType "InnoSetup Error" -Message "Exception during Inno Setup for $Architecture : $($_.Exception.Message)" -LogFilePath $logFilePath
        return $false
    }
    finally {
        if ($stdOutFile -and (Test-Path $stdOutFile)) { Remove-Item $stdOutFile -Force -ErrorAction SilentlyContinue }
        if ($stdErrFile -and (Test-Path $stdErrFile)) { Remove-Item $stdErrFile -Force -ErrorAction SilentlyContinue }
        Remove-DirectoryRecursive -Path $SourceContentPath
    }
}

function Process-MingwCompilation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture, # e.g., "64" or "32"
        [Parameter(Mandatory = $true)]
        [string]$AssetPattern, # Regex pattern for the asset name
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$WinLibsReleaseInfo, # Output from Find-GitHubRelease
        [Parameter(Mandatory = $false)] # Made false as it might not be available on first run
        [string]$ProjectLatestTag, # Latest tag of easy-mingw-installer
        [Parameter(Mandatory = $true)]
        [string]$SevenZipExePath,
        [Parameter(Mandatory = $true)]
        [string]$InnoSetupExePath,
        [Parameter(Mandatory = $true)]
        [string]$FinalOutputPath, # e.g., "builds" directory
        [Parameter(Mandatory = $true)]
        [string]$TempDirectory, # Base temp directory
        [Parameter(Mandatory = $true)]
        [string]$InnoSetupScriptPath,
        [Parameter(Mandatory = $false)]
        [switch]$SkipIfVersionMatchesTag,
        [Parameter(Mandatory = $false)]
        [switch]$GenerateLogsAlways,
        [Parameter(Mandatory = $false)]
        [switch]$IsTestMode
    )
    Write-SeparatorLine
    Write-StatusInfo -Type "Processing Arch" -Message "$($Architecture)-bit"

    $selectedAsset = $null
    if ($IsTestMode) {
        $selectedAsset = @{ name = "mingw-w64-$Architecture-Test.7z"; browser_download_url = "file:///placeholder-for-test.7z" }
        Write-StatusInfo -Type "Asset (Test Mode)" -Message $selectedAsset.name
    } elseif ($WinLibsReleaseInfo) {
        $selectedAsset = $WinLibsReleaseInfo.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
        if ($selectedAsset) { Write-StatusInfo -Type "Asset Found" -Message $selectedAsset.name } 
        else { Write-ErrorMessage -ErrorType "Asset Error" -Message "No asset found in release '$($WinLibsReleaseInfo.name)' matching pattern '$AssetPattern'."; return $false }
    } else { Write-ErrorMessage -ErrorType "Configuration Error" -Message "WinLibs release information not provided and not in test mode."; return $false }

    $releaseVersion = $null 
    $winlibsPublishedDateForInfoFile = ""

    if ($IsTestMode) {
        $releaseVersion = "2030.10.10" 
        $winlibsPublishedDateForInfoFile = (Get-Date).ToString("yyyy-MM-dd")
    } elseif ($WinLibsReleaseInfo) {
        $releaseVersion = ConvertTo-VersionStringFromDate -DateString $WinLibsReleaseInfo.published_at -FormatType Version
        $winlibsPublishedDateForInfoFile = ($WinLibsReleaseInfo.published_at | Get-Date).ToString("yyyy-MM-dd")
    } else {
        Write-ErrorMessage -ErrorType "Version Error" -Message "Cannot determine release version."
        return $false
    }
    Write-StatusInfo -Type "New Release Tag" -Message $releaseVersion

    # Create tag file for GitHub Actions - this will run per arch if build proceeds
    # If multiple archs produce the same tag, it's just overwritten, which is fine.
    if ($env:GITHUB_ACTIONS -eq "true") {
        $repoRootPathForTag = (Get-Item $PSScriptRoot).Parent.FullName
        $tagFileDir = Join-Path $repoRootPathForTag "tag"
        if (-not (Test-Path $tagFileDir -PathType Container)) {
            New-Item -Path $tagFileDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }
        New-Item -Path (Join-Path $tagFileDir $releaseVersion) -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
        Write-LogEntry -Type "GitHub Actions" -Message "Tag file for '$releaseVersion' created/updated in $tagFileDir."
    }

    $proceedWithBuild = $true
    if ($SkipIfVersionMatchesTag.IsPresent -and -not $IsTestMode) { # Check .IsPresent for switches
        if (-not $ProjectLatestTag) {
            Write-WarningMessage -Type "Version Check" -Message "Project's latest tag not available. Proceeding with build."
        } elseif ($ProjectLatestTag -eq $releaseVersion) {
            Write-StatusInfo -Type "Version Check" -Message "Current release version $releaseVersion matches project tag. Skipping build for $Architecture-bit."
            $proceedWithBuild = $false
        } else {
            Write-StatusInfo -Type "Version Check" -Message "New version $releaseVersion available (Project tag: $ProjectLatestTag)."
        }
    }
    
    $archTempDir = Join-Path -Path $TempDirectory -ChildPath "mingw$Architecture" 
    $sourcePathForInstaller = Join-Path -Path $archTempDir -ChildPath "mingw$Architecture" # Initial assumption
    $currentBuildInfoFilePath = Join-Path -Path $archTempDir -ChildPath "current_build_info.txt" # This is the input for Python
    
    # Path for the final release notes body in the repo root.
    # Construct the path without Resolve-Path, as the file won't exist until Python creates it.
    if (-not $repoRootPath) { # Ensure $repoRootPath is defined if not in GHA
         $repoRootPath = (Get-Item $PSScriptRoot).Parent.FullName
    }
    $releaseNotesBodyFinalPath = Join-Path $repoRootPath 'release_notes_body.md' # Output of Python

    try {
        if (Test-Path $archTempDir) { Remove-DirectoryRecursive -Path $archTempDir } 
        New-Item -ItemType Directory -Path $archTempDir -Force | Out-Null

        if ($IsTestMode) {
            Write-WarningMessage -Type "Test Mode" -Message "Skipping download and extraction for $Architecture-bit."
            New-Item -Path $sourcePathForInstaller -ItemType Directory -Force | Out-Null # Create dummy sourcePathForInstaller
            $dummyInfoContent = @"
winlibs personal build version gcc-TEST.0-mingw-w64ucrt-TEST.0-r0
This is the winlibs Intel/AMD $Architecture-bit standalone build of:
- GCC TEST.0
- GDB TEST.0
Thread model: POSIX
Runtime library: UCRT (Test Mode)
This build was compiled with GCC TEST.0 and packaged on $winlibsPublishedDateForInfoFile.
"@
            Set-Content -Path $currentBuildInfoFilePath -Value $dummyInfoContent -Encoding UTF8
            Set-Content -Path (Join-Path $sourcePathForInstaller "version_info.txt") -Value "Test Mode - GCC for $Architecture-bit" # Dummy version_info.txt
        } else {
            $downloadedFilePath = Join-Path -Path $archTempDir -ChildPath $selectedAsset.name
            if (-not (Invoke-DownloadFile -Url $selectedAsset.browser_download_url -DestinationFile $downloadedFilePath)) { throw "Download failed for $($selectedAsset.name)" }
            if (-not (Start-SevenZipExtraction -ArchivePath $downloadedFilePath -DestinationPath $archTempDir -SevenZipExePath $SevenZipExePath)) { throw "Extraction failed for $($selectedAsset.name)" }
            
            # Auto-detect the actual extracted folder (e.g., mingw64, mingw32)
            # $sourcePathForInstaller was an initial assumption, now we find the actual one
            $extractedDirs = Get-ChildItem -Path $archTempDir -Directory | Where-Object {$_.Name -like "mingw*"}
            if ($extractedDirs.Count -eq 1) {
                $sourcePathForInstaller = $extractedDirs[0].FullName # Update to the actual extracted path
                Write-StatusInfo -Type "Extraction Path" -Message "Actual source path for installer content: $sourcePathForInstaller"
            } elseif ($extractedDirs.Count -gt 1) {
                 Write-WarningMessage -Type "Extraction Ambiguity" -Message "Multiple mingw* directories found in $archTempDir. Using the first one: $($extractedDirs[0].FullName)"
                 $sourcePathForInstaller = $extractedDirs[0].FullName
            } else {
                Write-ErrorMessage -ErrorType "Extraction Error" -Message "Could not determine extracted MinGW folder (e.g., mingw64) in $archTempDir."
                throw "Extracted MinGW folder not found"
            }


            $winlibsInfoFileSource = Join-Path -Path $sourcePathForInstaller -ChildPath "version_info.txt" # Or "readme.txt", etc.
            if (Test-Path $winlibsInfoFileSource -PathType Leaf) {
                Write-StatusInfo -Type "Changelog Source" -Message "Using '$winlibsInfoFileSource' to create input for Python script."
                $fileContent = Get-Content -Path $winlibsInfoFileSource -Raw -Encoding UTF8
                if ($fileContent -notmatch "packaged on" -and $winlibsPublishedDateForInfoFile) {
                    $fileContent += "`nThis build was compiled with GCC (Version from file) and packaged on $winlibsPublishedDateForInfoFile."
                }
                Set-Content -Path $currentBuildInfoFilePath -Value $fileContent -Encoding UTF8
            } else {
                Write-WarningMessage -Type "Changelog Source" -Message "Could not find '$winlibsInfoFileSource'. Using placeholder for '$currentBuildInfoFilePath'."
                $placeholderInfoContent = @"
winlibs personal build version gcc-15.1.0-mingw-w64ucrt-13.0.0-r2

This is the winlibs Intel/AMD $Architecture-bit standalone build of:
- GCC 15.1.0
- GDB 16.3
- MinGW-w64 13.0.0 (linked with ucrt)
- GNU Binutils 2.44
- GNU Make 4.4.1
- PExports 0.47
- dos2unix 7.5.2
- Yasm 1.3.0
- NASM 2.16.03
- JWasm 2.12pre
- ccache 4.11.3
- CMake 4.0.2
- ninja 1.12.1
- Doxygen 1.14.0
- pedeps 0.1.15
- Universal Ctags 6.2.0
- Cppcheck 2.17.0
- Premake 5.0.0-beta6

Thread model: posix
Runtime library: UCRT (Windows 10 or higher, or when [Update for Universal C Runtime](https://support.microsoft.com/en-us/topic/update-for-universal-c-runtime-in-windows-c0514201-7fe6-95a3-b0a5-287930f3560c) is installed on older Windows versions, not supported on systems older than Windows 7 SP1 and Windows Server 2008 R2 SP1)

This build was compiled with GCC 15.1.0 and packaged on $winlibsPublishedDateForInfoFile.

Please check out https://winlibs.com/ for the latest personal build.
"@
                Set-Content -Path $currentBuildInfoFilePath -Value $placeholderInfoContent -Encoding UTF8
            }
        }

        if ($proceedWithBuild) {
            # Conditional Changelog Generation
            if (-not (Test-Path $releaseNotesBodyFinalPath)) {
                if (Test-Path $currentBuildInfoFilePath) {
                    Write-StatusInfo -Type "Changelog Generation" -Message "Attempting to generate release notes body..."
                    $pythonPath = "python.exe" 
                    $pythonScriptItself = Join-Path -Path $PSScriptRoot -ChildPath "generate_changelog.py" 
                    $effectivePrevTag = if ([string]::IsNullOrEmpty($ProjectLatestTag)) { "HEAD" } else { $ProjectLatestTag }

                    $pythonScriptArgs = @(
                        "--input-file", """$currentBuildInfoFilePath""" # Use the prepared file
                        "--output-file", """$releaseNotesBodyFinalPath"""
                        "--prev-tag", """$effectivePrevTag"""
                        "--current-build-tag", """$releaseVersion"""
                        "--github-owner", "ehsan18t"
                        "--github-repo", "easy-mingw-installer"
                    )
                    $fullArgumentList = @($pythonScriptItself) + $pythonScriptArgs
                    Write-LogEntry -Type "Python Call" -Message "$pythonPath $($fullArgumentList -join ' ')"
                    
                    $processInfo = Start-Process -FilePath $pythonPath -ArgumentList $fullArgumentList -Wait -NoNewWindow -PassThru -ErrorAction SilentlyContinue
                    
                    if ($processInfo.ExitCode -ne 0) {
                        Write-WarningMessage -Type "Changelog Gen Failed" -Message "Python script exited with code $($processInfo.ExitCode). Check Python script output."
                    } elseif (Test-Path $releaseNotesBodyFinalPath) {
                        Write-SuccessMessage -Type "Changelog Generated" -Message "Release notes body created at $releaseNotesBodyFinalPath"
                    } else {
                        Write-WarningMessage -Type "Changelog Gen Issue" -Message "Python script ran but output file $releaseNotesBodyFinalPath not found."
                    }
                } else {
                    Write-WarningMessage -Type "Changelog Skip" -Message "Input file '$currentBuildInfoFilePath' for Python script not found. Skipping changelog generation."
                }
            } else {
                Write-StatusInfo -Type "Changelog Skip" -Message "Release notes body '$releaseNotesBodyFinalPath' already exists. Skipping generation."
            }
            
            return Build-InnoSetupInstaller -InstallerName "EasyMinGW" `
                                     -Version $releaseVersion `
                                     -Architecture $Architecture `
                                     -SourceContentPath $sourcePathForInstaller `
                                     -InnoSetupExePath $InnoSetupExePath `
                                     -OutputDirectory $FinalOutputPath `
                                     -InnoSetupScriptPath $InnoSetupScriptPath `
                                     -SevenZipExePath $SevenZipExePath `
                                     -GenerateLogsAlways:$GenerateLogsAlways
        } else {
            Write-StatusInfo -Type "Build Skipped" -Message "Skipping InnoSetup build for $Architecture-bit."
            return $true 
        }
    }
    catch {
        Write-ErrorMessage -ErrorType "Compilation Failed" -Message "Error processing $Architecture-bit MinGW: $($_.Exception.Message)"
        return $false
    }
}
