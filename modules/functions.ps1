function Download-File {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $uri = New-Object "System.Uri" "$Url"
    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Timeout = 15000

    $response = $request.GetResponse()
    $totalLength = [System.Math]::Floor($response.ContentLength / 1024)
    $responseStream = $response.GetResponseStream()

    $targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $FileName, 'Create'
    $buffer = New-Object byte[] 10KB
    $downloadedBytes = 0

    while ($true) {
        $count = $responseStream.Read($buffer, 0, $buffer.Length)

        if ($count -eq 0) {
            break
        }

        $targetStream.Write($buffer, 0, $count)
        $downloadedBytes += $count

        if ($env:GITHUB_ACTIONS -ne "true") {
            [System.Console]::CursorLeft = 0
            [System.Console]::Write("    >> Downloaded {0}K of {1}K ({2}%) <<   ", [System.Math]::Floor($downloadedBytes / 1024), $totalLength, [System.Math]::Floor(($downloadedBytes / $response.ContentLength) * 100))
        }
    }

    $targetStream.Flush()
    $targetStream.Close()
    $targetStream.Dispose()
    $responseStream.Dispose()

    Write-Host "`n    *** Download completed ***"
}

function Extract-7z {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    if (-not (Test-Path $7ZipPath)) {
        Write-Host " -> ERROR: 7-Zip executable not found at '$7ZipPath'. Please make sure 7-Zip is installed or update the path to the 7z.exe file."
        return
    }

    $arguments = "x `"$ArchivePath`" -o`"$DestinationPath`" -y"
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $7ZipPath
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.Start() | Out-Null
    $process.WaitForExit()

    if ($process.ExitCode -eq 0) {
        Write-Host "    *** Extraction Completed ***"
    }
    else {
        Write-Host " -> ERROR: Error occurred during extraction."
    }
}

function Remove-Folder {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderPath
    )

    # Check if the folder exists
    if (Test-Path $FolderPath) {
        # Remove the folder and its contents recursively
        Remove-Item -Path $FolderPath -Recurse -Force
        Write-Host "     *** Removed '$FolderPath' ***"
    }
    else {
        Write-Host " -> ERROR: Folder '$FolderPath' not found."
    }
}

function Build-Installer {
    param (
        [string]$Name,
        [string]$Version,
        [string]$SourcePath
    )

    $installerScript = "MinGW_Installer.iss"

    $arguments = "/DMyAppName=`"$Name`" /DMyAppVersion=`"$Version`" /DArch=`"$arch`" /DSourcePath=`"$SourcePath`" /DOutputPath=`"$outputPath`""

    $tempStdOutFile = [System.IO.Path]::GetTempFileName()
    $tempStdErrFile = [System.IO.Path]::GetTempFileName()

    # Start the process and wait for it to complete
    $process = Start-Process -FilePath $InnoSetupPath -ArgumentList $installerScript, $arguments `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tempStdOutFile `
        -RedirectStandardError $tempStdErrFile

    # Get the exit code of the process
    $exitCode = $process.ExitCode

    # Read the content of the temp files
    $stdOutContent = Get-Content $tempStdOutFile
    $stdErrContent = Get-Content $tempStdErrFile

    if ($exitCode -ne 0 -or $generateLogsAlways) {
        $logFile = "build$arch.log"
        $stdOutContent + $stdErrContent | Out-File -FilePath $logFile

        if ($exitCode -ne 0) {
            Write-Host " -> ERROR: Building $Name Failed! Check the log file for details: $logFile"
            Exit 1
        } else {
            Write-Host "    *** Building $Name Succeeded! ***"
            Write-Host " -> Check the log file for details: $logFile"
        }
    } else {
        Write-Host "    *** Building $Name Succeeded! ***"
    }

    Remove-Item -Path $tempStdOutFile, $tempStdErrFile
    Remove-Item -Path $SourcePath -Recurse -Force
}

function Get-LatestTag {
    param (
        [string]$Owner,
        [string]$Repo
    )

    $tagsUrl = "https://api.github.com/repos/$Owner/$Repo/tags"
    $tagsInfo = Invoke-RestMethod -Uri $tagsUrl

    $latestTag = $tagsInfo[0].name
    Write-Host " -> Latest EMI Tag: $latestTag"
    return $latestTag
}

function Format-Date {
    param (
        [string]$Date,
        [switch]$asVersion
    )

    if ($asVersion) {
        return Get-Date -Date $Date -Format "yyyy.MM.dd"
    }

    return Get-Date -Date $Date -Format "dd-MMM-yyyy HH:mm:ss"
}

function Get-Release {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Owner,
        [Parameter(Mandatory = $true)]
        [string]$Repo,
        [Parameter(Mandatory = $true)]
        [string]$TitlePattern
    )

    # Get the releases information
    $releasesUrl = "https://api.github.com/repos/$Owner/$Repo/releases"
    $releasesInfo = Invoke-RestMethod -Uri $releasesUrl

    $selectedRelease = $null
    foreach ($release in $releasesInfo) {
        if ($release.name -like $TitlePattern -and !$release.prerelease) {
            if ($null -eq $selectedRelease -or $release.published_at -gt $selectedRelease.published_at) {
                $selectedRelease = $release
            }
        }
    }

    Write-Host " -> Selected Release: $($selectedRelease.name)"
    $parsedTime = Format-Date -Date $selectedRelease.published_at
    Write-Host " -> Release date: $parsedTime"

    return $selectedRelease
}

function Build-Binary {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Arch,
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    Write-Host "`n -> Arch: $Arch-bit"
    # Write-Host " -> Pattern: $pattern"

    $selectedAsset = $null
    if ($testMode) {
        $selectedAsset = @{ name = "mingw-w64-$Arch-Test.7z" }
    } elseif ($selectedRelease) {
        $selectedAsset = $selectedRelease.assets | Where-Object { $_.name -match $Pattern }
        Write-Host " -> Selected Asset: $($selectedAsset.name)"
    } else {
        Write-Host " ERROR: No release found that match the filter criteria."
        Exit 1
    }

    if ($selectedAsset) {
        # Set the variables for Inno Setup
        $name = "Easy MinGW Installer"
        $version = $null
        if ($testMode) {
            $version = "v2030.10.10"
        } else {
            $version = Format-Date -Date $selectedRelease.published_at -asVersion
        }

        # Set Tag in ENV for GitHub Actions
        if ($env:GITHUB_ACTIONS -eq "true") {
            echo "tag=$version" >> $GITHUB_ENV
        }

        # Check if new release is available
        if ($checkNewRelease) {
            if ($latestTag -eq $version) {
                Write-Host " -> NO NEW RELEASE AVAILABLE.`n"
                Exit 0
            }
        }

        if ($testMode) {
            Write-Host " -> TEST MODE: Skipping download and extraction."
            # make directory at "\mingw$Arch" with a dummy file
            $dummyFilePath = Join-Path -Path $tempDir -ChildPath "\mingw$Arch\dummy.txt"
            $dummyVersionInfoPath = Join-Path -Path $tempDir -ChildPath "\version_info.txt"
            New-Item -Path $dummyFilePath -ItemType File -Force | Out-Null
            New-Item -Path $dummyVersionInfoPath -ItemType File -Force | Out-Null
        } else {
            # Get the asset download URL, name, and size
            $assetUrl = $selectedAsset.browser_download_url
            $assetName = $selectedAsset.name

            # Set the destination path for the downloaded asset in the current directory
            $destinationPath = Join-Path -Path $tempDir -ChildPath $assetName

            # Download the asset
            Write-Host " -> Downloading {TEMP_DIR}/$assetName"
            Download-File -Url $assetUrl -FileName $destinationPath
            $downloadedFilePath = $tempDir + "\$assetName"

            # Extract the downloaded file
            Write-Host " -> Extracting {TEMP_DIR}/$assetName"
            $unzipDestination = $tempDir
            Extract-7z -ArchivePath $downloadedFilePath -DestinationPath $unzipDestination
            $extractedFolderPath = "\mingw$Arch"
        }

        # Set the SourcePath for Inno Setup
        $sourcePath = Join-Path -Path $tempDir -ChildPath $extractedFolderPath

        # Build the installer
        Write-Host " -> Building $name"
        Build-Installer -Name $name -Version $version -SourcePath $sourcePath
    } else {
        Write-Host " -> ERROR: No asset matching the pattern was found."
        Exit 1
    }
}