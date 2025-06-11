function Download-File {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    try {
        $uri = New-Object "System.Uri" -ArgumentList $Url
        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.Timeout = 30000 # Increased timeout

        Write-Color "    Attempting to download from: $Url" $colors.DarkGray # Uses pretty.ps1

        $response = $request.GetResponse()
        $totalLength = $response.ContentLength # Keep as raw bytes for more accurate percentage
        $totalLengthKB = [System.Math]::Floor($totalLength / 1024)
        $responseStream = $response.GetResponseStream()

        $targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $FileName, 'Create'
        $buffer = New-Object byte[] 10KB # 10KB buffer
        $downloadedBytes = 0
        $lastReportedProgressPercent = -1 # For periodic updates

        while ($true) {
            $count = $responseStream.Read($buffer, 0, $buffer.Length)
            if ($count -eq 0) { break }

            $targetStream.Write($buffer, 0, $count)
            $downloadedBytes += $count

            if ($env:GITHUB_ACTIONS -ne "true" -and $totalLength -gt 0) {
                $currentProgressPercent = [System.Math]::Floor(($downloadedBytes / $totalLength) * 100)
                # Report progress periodically (e.g., every 5%)
                if ($currentProgressPercent -ne $lastReportedProgressPercent -and ($currentProgressPercent % 5 -eq 0 -or $currentProgressPercent -eq 100)) {
                    Write-Actions "Downloading" "$([System.Math]::Floor($downloadedBytes / 1024))K / $($totalLengthKB)K ($currentProgressPercent%)" # Uses pretty.ps1
                    $lastReportedProgressPercent = $currentProgressPercent
                }
            }
        }
        # The Write-Host "" previously here is removed; Write-Color below handles the next line.
        Write-Color "    Download Completed!" $colors.Green # Uses pretty.ps1
    }
    catch {
        Write-Error -Type "DOWNLOAD ERROR" -Message "Failed to download '$Url': $($_.Exception.Message)" # Uses pretty.ps1
        throw "Download failed for $Url"
    }
    finally {
        if ($targetStream) { $targetStream.Dispose() }
        if ($responseStream) { $responseStream.Dispose() }
        if ($response) { $response.Close() }
    }
}

function Extract-7z {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [string]$SevenZipPath
    )

    if (-not (Test-Path $SevenZipPath -PathType Leaf)) {
        Write-Error -Type "7ZIP ERROR" -Message "7-Zip executable not found at '$SevenZipPath'."
        throw "7-Zip not found"
    }

    $arguments = "x `"$ArchivePath`" -o`"$DestinationPath`" -y"
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $SevenZipPath
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    # $startInfo.RedirectStandardOutput = $true # Optional: if you need to capture output
    # $startInfo.RedirectStandardError = $true  # Optional: if you need to capture error

    try {
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        $process.Start() | Out-Null
        $process.WaitForExit()

        if ($process.ExitCode -eq 0) {
            Write-Color "    Extraction Completed!" $colors.Green # Uses pretty.ps1
        }
        else {
            Write-Error -Type "EXTRACTION ERROR" -Message "7-Zip extraction failed for '$ArchivePath' with exit code $($process.ExitCode)." # Uses pretty.ps1
            throw "Extraction failed"
        }
    }
    catch {
        Write-Error -Type "PROCESS ERROR" -Message "Error during 7-Zip execution: $($_.Exception.Message)" # Uses pretty.ps1
        throw "7-Zip process error"
    }
}

function Remove-Folder {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    if (Test-Path $FolderPath) {
        try {
            Remove-Item -Path $FolderPath -Recurse -Force -ErrorAction Stop
            Write-Color "     Removed '$FolderPath'!" $colors.Green # Uses pretty.ps1
        }
        catch {
            Write-Warnings -Type "CLEANUP" -Message "Failed to remove folder '$FolderPath': $($_.Exception.Message)" # Uses pretty.ps1
        }
    }
    else {
        Write-Log "Cleanup" "Folder '$FolderPath' not found, no removal needed." $colors.Gray # Uses pretty.ps1
    }
}

function Build-Installer {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [Parameter(Mandatory = $true)]
        [string]$Arch,
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$InnoSetupPath,
        [Parameter(Mandatory = $true)]
        [string]$BaseOutputPath, # Renamed from outputPath to avoid conflict if this module is dot sourced elsewhere
        [Parameter(Mandatory = $false)]
        [bool]$GenerateLogsAlways = $false
    )

    $installerScript = Join-Path -Path $PSScriptRoot -ChildPath "..\MinGW_Installer.iss" # Assuming it's one level up from modules

    # Ensure BaseOutputPath exists
    if (-not (Test-Path $BaseOutputPath)) {
        New-Item -Path $BaseOutputPath -ItemType Directory -Force | Out-Null
    }

    $arguments = "/DMyAppName=`"$Name`" /DMyAppVersion=`"$Version`" /DArch=`"$Arch`" /DSourcePath=`"$SourcePath`" /DOutputPath=`"$BaseOutputPath`""

    $tempStdOutFile = [System.IO.Path]::GetTempFileName()
    $tempStdErrFile = [System.IO.Path]::GetTempFileName()
    $logFile = Join-Path -Path $PSScriptRoot -ChildPath "..\build${Arch}.log" # Log in the root folder

    try {
        Write-Color "    Starting Inno Setup build for $Arch..." $colors.Cyan # Uses pretty.ps1
        $process = Start-Process -FilePath $InnoSetupPath -ArgumentList $installerScript, $arguments `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tempStdOutFile `
            -RedirectStandardError $tempStdErrFile

        $exitCode = $process.ExitCode
        $stdOutContent = Get-Content $tempStdOutFile -ErrorAction SilentlyContinue
        $stdErrContent = Get-Content $tempStdErrFile -ErrorAction SilentlyContinue

        if ($exitCode -ne 0 -or $GenerateLogsAlways) {
            $logContent = "Standard Output:`n$stdOutContent`n`nStandard Error:`n$stdErrContent"
            Set-Content -Path $logFile -Value $logContent -Encoding UTF8

            if ($exitCode -ne 0) {
                Write-Error -Type "BUILD ERROR" -Message "Building $Name ($Arch) Failed!" -logs $logFile -exitCode $exitCode # Uses pretty.ps1
                throw "Inno Setup build failed"
            } else {
                Write-Color "    Building $Name ($Arch) Succeeded!" $colors.Green # Uses pretty.ps1
                Write-Color " >> Check the log file for details: " $colors.Yellow -NoNewline # Uses pretty.ps1
                Write-Color $logFile $colors.Cyan # Uses pretty.ps1
            }
        } else {
            Write-Color "    Building $Name ($Arch) Succeeded!" $colors.Green # Uses pretty.ps1
        }
    }
    catch {
        Write-Error -Type "INNOSETUP ERROR" -Message "Exception during Inno Setup execution for $Arch : $($_.Exception.Message)" -logs $logFile # Uses pretty.ps1
        throw "Inno Setup execution failed" # Re-throw to be caught by Build-Binary or Main
    }
    finally {
        Remove-Item -Path $tempStdOutFile, $tempStdErrFile -ErrorAction SilentlyContinue
        Write-Actions "Cleanup" "Removing source path: $SourcePath"
        Remove-Folder -FolderPath $SourcePath # Use the robust Remove-Folder
    }
}

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
        [string]$DestinationFile
    )
    Write-ActionProgress -ActionName "Downloading" -Details $Url
    try {
        $webRequest = [System.Net.HttpWebRequest]::Create($Url)
        $webRequest.Timeout = 60000 # 60 seconds timeout

        $response = $webRequest.GetResponse()
        $totalLength = $response.ContentLength
        $totalLengthKB = [System.Math]::Floor($totalLength / 1024)
        $responseStream = $response.GetResponseStream()

        $targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $DestinationFile, 'Create'
        $buffer = New-Object byte[] 40KB # Increased buffer
        $downloadedBytes = 0
        $lastReportedProgress = -1

        while ($true) {
            $bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -eq 0) { break }

            $targetStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead

            if ($totalLength -gt 0) {
                $progressPercentage = [System.Math]::Floor(($downloadedBytes / $totalLength) * 100)
                if ($progressPercentage -gt $lastReportedProgress -and ($progressPercentage % 5 -eq 0 -or $progressPercentage -eq 100)) {
                    Write-ActionProgress -ActionName "Progress" -Details "$([System.Math]::Floor($downloadedBytes / 1024))KB / ${totalLengthKB}KB ($progressPercentage%)"
                    $lastReportedProgress = $progressPercentage
                }
            }
        }
        Write-ColoredHost -Text "    Download complete: $DestinationFile" -ForegroundColor $script:colors.Green
        return $true
    }
    catch {
        Write-ErrorMessage -ErrorType "Download Failed" -Message "Error downloading '$Url': $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($targetStream) { $targetStream.Dispose() }
        if ($responseStream) { $responseStream.Dispose() }
        if ($response) { $response.Close() }
    }
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