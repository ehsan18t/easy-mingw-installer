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
        [string]$InnoSetupScriptPath, # Path to MinGW_Installer.iss
        [Parameter(Mandatory = $false)]
        [bool]$GenerateLogsAlways = $false
    )
    Write-ActionProgress -ActionName "Building Installer" -Details "$InstallerName $Version ($Architecture)"
    $logFileName = "build_${InstallerName}_${Architecture}.log"
    $logFilePath = Join-Path -Path $PSScriptRoot -ChildPath "..\$logFileName" # Logs in the project root

    $arguments = "/DMyAppName=`"$InstallerName`" /DMyAppVersion=`"$Version`" /DArch=`"$Architecture`" /DSourcePath=`"$SourceContentPath`" /DOutputPath=`"$OutputDirectory`""
    
    $stdOutFile = $null
    $stdErrFile = $null

    try {
        # Ensure OutputDirectory exists
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
        } else {
            Write-ColoredHost -Text "    Build Succeeded: $InstallerName ($Architecture)" -ForegroundColor $script:colors.Green
        }
        return $true
    }
    catch {
        Write-ErrorMessage -ErrorType "InnoSetup Error" -Message "Exception during Inno Setup for $Architecture : $($_.Exception.Message)" -LogFilePath $logFilePath
        return $false # Critical failure
    }
    finally {
        if ($stdOutFile -and (Test-Path $stdOutFile)) { Remove-Item $stdOutFile -Force -ErrorAction SilentlyContinue }
        if ($stdErrFile -and (Test-Path $stdErrFile)) { Remove-Item $stdErrFile -Force -ErrorAction SilentlyContinue }
        Remove-DirectoryRecursive -Path $SourceContentPath # Clean up the source files for this build
    }
}

function Process-MingwCompilation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Architecture,
        [Parameter(Mandatory = $true)]
        [string]$AssetPattern,
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$WinLibsReleaseInfo, # This is already passed
        [Parameter(Mandatory = $true)] # Changed from $false, as it's needed for versioning
        [string]$ProjectLatestTag,
        [Parameter(Mandatory = $true)]
        [string]$SevenZipExePath,
        [Parameter(Mandatory = $true)]
        [string]$InnoSetupExePath,
        [Parameter(Mandatory = $true)]
        [string]$FinalOutputPath,
        [Parameter(Mandatory = $true)]
        [string]$TempDirectory, # This is the $baseTempDir from Builder.ps1
        [Parameter(Mandatory = $true)]
        [string]$InnoSetupScriptPath,
        [Parameter(Mandatory = $false)]
        [switch]$SkipIfVersionMatchesTag, # This logic remains here per-architecture
        [Parameter(Mandatory = $false)]
        [switch]$GenerateLogsAlways,
        [Parameter(Mandatory = $false)]
        [switch]$IsTestMode,
        [Parameter(Mandatory = $false)] # New parameter
        [switch]$IsPrimaryArchForChangelogInfo,
        [Parameter(Mandatory = $true)] # New parameter for the release version string
        [string]$CurrentReleaseVersionString
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


    # $releaseVersion is now passed in as $CurrentReleaseVersionString
    # $winlibsPublishedDateForInfoFile is still needed for the content of current_build_info.txt
    $winlibsPublishedDateForInfoFile = ""
    if ($IsTestMode) {
        $winlibsPublishedDateForInfoFile = (Get-Date).ToString("yyyy-MM-dd")
    } elseif ($WinLibsReleaseInfo) {
        $winlibsPublishedDateForInfoFile = ($WinLibsReleaseInfo.published_at | Get-Date).ToString("yyyy-MM-dd")
    } # else it remains empty, placeholder will use it if needed


    # REMOVED: Tag file creation for GitHub Actions (moved to Builder.ps1)

    $proceedWithBuild = $true
    if ($SkipIfVersionMatchesTag -and -not $IsTestMode) {
        if (-not $ProjectLatestTag) {
            Write-WarningMessage -Type "Version Check" -Message "Project's latest tag not available. Proceeding with build."
        } elseif ($ProjectLatestTag -eq $CurrentReleaseVersionString) { # Use passed-in version
            Write-StatusInfo -Type "Version Check" -Message "Current release version $CurrentReleaseVersionString matches project tag. Skipping build for $Architecture-bit."
            $proceedWithBuild = $false
        } else {
            Write-StatusInfo -Type "Version Check" -Message "New version $CurrentReleaseVersionString available (Project tag: $ProjectLatestTag)."
        }
    }
    
    $archTempDir = Join-Path -Path $TempDirectory -ChildPath "mingw$Architecture" 
    $sourcePathForInstaller = Join-Path -Path $archTempDir -ChildPath "mingw$Architecture" 
    $currentBuildInfoFilePathLocal = Join-Path -Path $archTempDir -ChildPath "current_build_info.txt" 
    
    try {
        if (Test-Path $archTempDir) { Remove-DirectoryRecursive -Path $archTempDir } 
        New-Item -ItemType Directory -Path $archTempDir -Force | Out-Null

        if ($IsTestMode) {
            # ... (Test mode setup for $currentBuildInfoFilePathLocal)
            Write-WarningMessage -Type "Test Mode" -Message "Skipping download and extraction for $Architecture-bit."
            New-Item -Path $sourcePathForInstaller -ItemType Directory -Force | Out-Null
            $dummyInfoContent = @"
winlibs personal build version gcc-TEST.0-mingw-w64ucrt-TEST.0-r0
This is the winlibs Intel/AMD $Architecture-bit standalone build of:
- GCC TEST.0
- GDB TEST.0
Thread model: POSIX
Runtime library: UCRT (Test Mode)
This build was compiled with GCC TEST.0 and packaged on $winlibsPublishedDateForInfoFile.
"@
            Set-Content -Path $currentBuildInfoFilePathLocal -Value $dummyInfoContent -Encoding UTF8
            Set-Content -Path (Join-Path $sourcePathForInstaller "version_info.txt") -Value "Test Mode - GCC for $Architecture-bit" # Dummy version_info.txt
        } else {
            # ... (Download and extraction logic remains the same)
            $downloadedFilePath = Join-Path -Path $archTempDir -ChildPath $selectedAsset.name
            if (-not (Invoke-DownloadFile -Url $selectedAsset.browser_download_url -DestinationFile $downloadedFilePath)) {
                throw "Download failed for $($selectedAsset.name)"
            }
            if (-not (Start-SevenZipExtraction -ArchivePath $downloadedFilePath -DestinationPath $archTempDir -SevenZipExePath $SevenZipExePath)) {
                throw "Extraction failed for $($selectedAsset.name)"
            }
            
            $extractedDirs = Get-ChildItem -Path $archTempDir -Directory | Where-Object {$_.Name -like "mingw*"}
            if ($extractedDirs.Count -eq 1) { $sourcePathForInstaller = $extractedDirs[0].FullName }
            # ... (error handling for $extractedDirs)

            $winlibsInfoFileSource = Join-Path -Path $sourcePathForInstaller -ChildPath "version_info.txt" 
            if (Test-Path $winlibsInfoFileSource -PathType Leaf) {
                $fileContent = Get-Content -Path $winlibsInfoFileSource -Raw -Encoding UTF8
                if ($fileContent -notmatch "packaged on" -and $winlibsPublishedDateForInfoFile) {
                    $fileContent += "`nThis build was compiled with GCC (Version from file) and packaged on $winlibsPublishedDateForInfoFile."
                }
                Set-Content -Path $currentBuildInfoFilePathLocal -Value $fileContent -Encoding UTF8
            } else {
                # ... (Placeholder logic for $currentBuildInfoFilePathLocal)
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
                Set-Content -Path $currentBuildInfoFilePathLocal -Value $placeholderInfoContent -Encoding UTF8
            }
        }

        # If this is the primary architecture, copy its build info for global changelog generation
        if ($IsPrimaryArchForChangelogInfo.IsPresent -and (Test-Path $currentBuildInfoFilePathLocal)) {
            $masterBuildInfoForChangelog = Join-Path -Path $TempDirectory -ChildPath "master_build_info_for_changelog.txt"
            Copy-Item -Path $currentBuildInfoFilePathLocal -Destination $masterBuildInfoForChangelog -Force
            Write-StatusInfo -Type "Changelog Info" -Message "Copied $Architecture build info to $masterBuildInfoForChangelog"
        }

        if ($proceedWithBuild) {
            return Build-InnoSetupInstaller -InstallerName "EasyMinGW" `
                                     -Version $CurrentReleaseVersionString ` # Use passed-in version
                                     -Architecture $Architecture `
                                     -SourceContentPath $sourcePathForInstaller `
                                     -InnoSetupExePath $InnoSetupExePath `
                                     -OutputDirectory $FinalOutputPath `
                                     -InnoSetupScriptPath $InnoSetupScriptPath `
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
    # The $currentBuildInfoFilePathLocal will be cleaned up when $archTempDir is cleaned,
    # or by Build-InnoSetupInstaller's finally block if $sourcePathForInstaller is $archTempDir.
    # The copied master_build_info_for_changelog.txt in $TempDirectory ($baseTempDir) will persist.
}
