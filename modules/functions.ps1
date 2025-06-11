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
        [string]$Architecture, # e.g., "64" or "32"
        [Parameter(Mandatory = $true)]
        [string]$AssetPattern, # Regex pattern for the asset name
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$WinLibsReleaseInfo, # Output from Find-GitHubRelease
        [Parameter(Mandatory = $true)]
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
        if ($selectedAsset) {
            Write-StatusInfo -Type "Asset Found" -Message $selectedAsset.name
        } else {
            Write-ErrorMessage -ErrorType "Asset Error" -Message "No asset found in release '$($WinLibsReleaseInfo.name)' matching pattern '$AssetPattern'."
            return $false # Stop processing this architecture
        }
    } else {
        Write-ErrorMessage -ErrorType "Configuration Error" -Message "WinLibs release information not provided and not in test mode."
        return $false
    }

    $releaseVersion = $null
    if ($IsTestMode) {
        $releaseVersion = "2030.10.10" # Test version
    } elseif ($WinLibsReleaseInfo) {
        $releaseVersion = ConvertTo-VersionStringFromDate -DateString $WinLibsReleaseInfo.published_at -FormatType Version
    } else {
        Write-ErrorMessage -ErrorType "Version Error" -Message "Cannot determine release version."
        return $false
    }
    Write-StatusInfo -Type "Release Version" -Message $releaseVersion

    # Create tag file for GitHub Actions
    if ($env:GITHUB_ACTIONS -eq "true") {
        $tagFilePath = Join-Path -Path $PSScriptRoot -ChildPath "..\tag" # Create tag file in project root
        New-Item -Path $tagFilePath -Name $releaseVersion -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
        Write-LogEntry -Type "GitHub Actions" -Message "Tag file for '$releaseVersion' created/updated."
    }

    if ($SkipIfVersionMatchesTag -and -not $IsTestMode) {
        if (-not $ProjectLatestTag) {
            Write-WarningMessage -Type "Version Check" -Message "Project's latest tag not available. Proceeding with build."
        } elseif ($ProjectLatestTag -eq $releaseVersion) {
            Write-StatusInfo -Type "Version Check" -Message "Current release version $releaseVersion matches project tag. Skipping build for $Architecture-bit."
            return $true # Successfully skipped
        } else {
            Write-StatusInfo -Type "Version Check" -Message "New version $releaseVersion available (Project tag: $ProjectLatestTag)."
        }
    }
    
    $archTempDir = Join-Path -Path $TempDirectory -ChildPath "mingw$Architecture" # Specific temp dir for this arch
    $sourcePathForInstaller = Join-Path -Path $archTempDir -ChildPath "mingw$Architecture" # Expected extracted folder name

    try {
        if (Test-Path $archTempDir) { Remove-DirectoryRecursive -Path $archTempDir } # Clean previous run for this arch
        New-Item -ItemType Directory -Path $archTempDir -Force | Out-Null

        if ($IsTestMode) {
            Write-WarningMessage -Type "Test Mode" -Message "Skipping download and extraction for $Architecture-bit."
            # Create dummy structure for Inno Setup test
            New-Item -Path $sourcePathForInstaller -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path $sourcePathForInstaller "version_info.txt") -Value "Test Mode - GCC for $Architecture-bit"
        } else {
            $downloadedFilePath = Join-Path -Path $archTempDir -ChildPath $selectedAsset.name
            if (-not (Invoke-DownloadFile -Url $selectedAsset.browser_download_url -DestinationFile $downloadedFilePath)) {
                throw "Download failed for $($selectedAsset.name)"
            }
            if (-not (Start-SevenZipExtraction -ArchivePath $downloadedFilePath -DestinationPath $archTempDir -SevenZipExePath $SevenZipExePath)) {
                throw "Extraction failed for $($selectedAsset.name)"
            }
            # Verify expected extraction path
            if (-not (Test-Path $sourcePathForInstaller -PathType Container)) {
                 # Attempt to find the actual extracted folder if default name "mingw$Architecture" is not used by winlibs
                $extractedDirs = Get-ChildItem -Path $archTempDir -Directory | Where-Object {$_.Name -like "mingw*"}
                if ($extractedDirs.Count -eq 1) {
                    $sourcePathForInstaller = $extractedDirs[0].FullName
                    Write-WarningMessage -Type "Extraction Path" -Message "Auto-detected extracted folder: $sourcePathForInstaller"
                } else {
                    Write-ErrorMessage -ErrorType "Extraction Error" -Message "Could not determine extracted MinGW folder in $archTempDir."
                    throw "Extracted MinGW folder not found"
                }
            }
        }

        return Build-InnoSetupInstaller -InstallerName "EasyMinGW" `
                                 -Version $releaseVersion `
                                 -Architecture $Architecture `
                                 -SourceContentPath $sourcePathForInstaller `
                                 -InnoSetupExePath $InnoSetupExePath `
                                 -OutputDirectory $FinalOutputPath `
                                 -InnoSetupScriptPath $InnoSetupScriptPath `
                                 -GenerateLogsAlways:$GenerateLogsAlways
    }
    catch {
        Write-ErrorMessage -ErrorType "Compilation Failed" -Message "Error processing $Architecture-bit MinGW: $($_.Exception.Message)"
        return $false
    }
    # Note: $archTempDir (e.g. Temp\EasyMinGWInstaller\mingw64) is cleaned up by Build-InnoSetupInstaller's finally block for its $SourceContentPath
}