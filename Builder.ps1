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
    [switch]$generateLogsAlways
)

if ($archs.Count -eq 1) { $archs = $archs.Split(',') }
if ($namePatterns.Count -eq 1) { $namePatterns = $namePatterns.Split(',') }

$tempDir = [System.IO.Path]::GetTempPath() + "EasyMinGWInstaller"
if (Test-Path $tempDir) {
    Remove-Item -Path $tempDir -Recurse -Force
}

New-Item -ItemType Directory -Path $tempDir | Out-Null
Write-Host " -> Temp Directory: $tempDir"
Write-Host " -> Output Directory: $outputPath `n"

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

        [System.Console]::CursorLeft = 0
        [System.Console]::Write("    >> Downloaded {0}K of {1}K ({2}%) <<   ", [System.Math]::Floor($downloadedBytes / 1024), $totalLength, [System.Math]::Floor(($downloadedBytes / $response.ContentLength) * 100))
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

    if (-NOT (Test-Path $SourcePath)) {
        Write-Host " -> Building $Name Failed!"
        Exit 1
    }

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

function main {
    # Set the GitHub repository details
    $owner = "brechtsanders"
    $repo = "winlibs_mingw"

    # Get the releases information
    $releasesUrl = "https://api.github.com/repos/$owner/$repo/releases"
    $releasesInfo = Invoke-RestMethod -Uri $releasesUrl

    # Filter releases based on the regular expression pattern in the title
    $selectedRelease = $null
    foreach ($release in $releasesInfo) {
        if ($release.name -like $titlePattern -and !$release.prerelease) {
            if ($null -eq $selectedRelease -or $release.published_at -gt $selectedRelease.published_at) {
                $selectedRelease = $release
            }
        }
    }

    Write-Host " -> Selected Release: $($selectedRelease.name)"
    $parsedTime = Get-Date -Date $selectedRelease.published_at -Format "dd-MMM-yyyy HH:mm:ss"
    Write-Host " -> Release date: $parsedTime"

    # for loop to iterate over the archs
    if ($archs.Length -eq $namePatterns.Length) {
        for ($i = 0; $i -lt $archs.Length; $i++) {
            # Set the regular expression pattern for the varying portion of the file name
            $pattern = $namePatterns[$i]
            $arch = $archs[$i]
            $arrSize = $archs.Length

            Write-Host "`n -> Arch: $arch-bit"
            # Write-Host " -> Pattern: $pattern"

            $selectedAsset = $null
            if ($selectedRelease) {
                $selectedAsset = $selectedRelease.assets | Where-Object { $_.name -match $pattern }
                Write-Host " -> Selected Asset: $($selectedAsset.name)"
            } else {
                Write-Host " ERROR: No release found that match the filter criteria."
                Exit 1
            }

            if ($selectedAsset) {
                # Set the variables for Inno Setup
                $name = "Easy MinGW Installer"
                $version = Get-Date -Date $selectedRelease.published_at -Format "yyyy.MM.dd"

                # Check if new release is available
                if ($checkNewRelease) {
                    $latestTag = Get-LatestTag -Owner "ehsan18t" -Repo "easy-mingw-installer"

                    if ($latestTag -eq $version) {
                        Write-Host " -> NO NEW RELEASE AVAILABLE.`n"
                        Exit 0
                    }
                }

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
                $extractedFolderPath = "\mingw$arch"

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

        Remove-Item -Path $tempDir -Recurse -Force
    } else {
        Write-Host " -> ERROR: Arrays are not of the same length."
        Exit 1
    }
}

main
