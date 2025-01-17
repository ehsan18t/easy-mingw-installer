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

function Get-Release {
    param (
        [Parameter(Mandatory = $true)]
        $ReleasesInfo,
        [Parameter(Mandatory = $true)]
        [string]$TitlePattern
    )

    $selectedRelease = $null
    foreach ($release in $ReleasesInfo) {
        if ($release.name -like $TitlePattern -and !$release.prerelease) {
            if ($null -eq $selectedRelease -or $release.published_at -gt $selectedRelease.published_at) {
                $selectedRelease = $release
            }
        }
    }

    Write-Host " -> Selected Release: $($selectedRelease.name)"
    $parsedTime = Get-Date -Date $selectedRelease.published_at -Format "dd-MMM-yyyy HH:mm:ss"
    Write-Host " -> Release date: $parsedTime"

    return $selectedRelease
}