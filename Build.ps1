
$currentDirectory = $PWD.Path

function Download-File {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    Write-Output " -> Downloading $FileName..."

    $webRequest = [System.Net.WebRequest]::Create($Url)
    $webRequest.UseDefaultCredentials = $true
    $webRequest.Proxy = [System.Net.WebRequest]::DefaultWebProxy
    $webRequest.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials

    $webResponse = $webRequest.GetResponse()
    $contentLength = [System.Convert]::ToInt64($webResponse.Headers.Get("Content-Length"))

    $bufferSize = 8192
    $buffer = New-Object byte[] $bufferSize

    $fileStream = [System.IO.File]::Create($FileName)

    $responseStream = $webResponse.GetResponseStream()

    $progress = 0
    $totalBytesRead = 0
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    while ($progress -lt 100) {
        $bytesRead = $responseStream.Read($buffer, 0, $bufferSize)
        if ($bytesRead -eq 0) {
            break
        }

        $fileStream.Write($buffer, 0, $bytesRead)

        $totalBytesRead += $bytesRead
        $progress = $totalBytesRead / $contentLength * 100

        $elapsedTime = $timer.Elapsed.TotalSeconds
        if ($elapsedTime -gt 0) {
            $speed = $totalBytesRead / $elapsedTime
        } else {
            $speed = 0
        }

        Write-Progress -Activity "Downloading" -Status "Progress: $([math]::Round($progress, 2))%  Speed: $([math]::Round($speed / 1024, 2)) KB/s" -PercentComplete $progress
    }

    $fileStream.Dispose()
    $responseStream.Dispose()
    $webResponse.Dispose()

    Write-Progress -Activity "Downloading" -Status "Completed" -Completed
}

function Extract-7z {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $7zExe = "C:\Program Files\7-Zip\7z.exe"
    if (-not (Test-Path $7zExe)) {
        Write-Host "7-Zip executable not found at '$7zExe'. Please make sure 7-Zip is installed or update the path to the 7z.exe file."
        return
    }

    Write-Output " -> Extracting $ArchivePath"

    $arguments = "x `"$ArchivePath`" -o`"$DestinationPath`" -y"
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $7zExe
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $process.Start() | Out-Null
    $process.WaitForExit()

    if ($process.ExitCode -eq 0) {
        Write-Host "Extraction completed."
    } else {
        Write-Host "Error occurred during extraction."
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
        Write-Host " -> Removed '$FolderPath'"
    } else {
        Write-Host "Folder '$FolderPath' not found."
    }
}

function Build-Installer {
    param (
        [string]$Name,
        [string]$Version,
        [string]$SourcePath
    )

    if (-NOT (Test-Path $SourcePath)) {
        Write-Output " -> Builing $Name Failed!"
        Exit 1
    }

    Write-Output " -> Builing $Name. Path: $SourcePath"

    $innoSetupPath = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    $installerScript = "MinGW_Installer.iss"

    $arguments = "/DMyAppName=`"$Name`" /DMyAppVersion=`"$Version`" /DSourcePath=`"$SourcePath`""

    Start-Process -FilePath $innoSetupPath -ArgumentList $installerScript, $arguments -Wait
    Remove-Folder -FolderPath $SourcePath
}

# Set the GitHub repository details
$owner = "brechtsanders"
$repo = "winlibs_mingw"

# Set the regular expression pattern for the varying portion of the file name
$pattern = "winlibs-x86_64-posix-seh-gcc-[0-9.]+-mingw-w64ucrt-(.*?).7z$"
$versionRegex = "(?<=gcc-)\d+\.\d+\.\d+"

# Get the latest release information
$releaseUrl = "https://api.github.com/repos/$owner/$repo/releases/latest"
$releaseInfo = Invoke-RestMethod -Uri $releaseUrl

# Filter assets based on the regular expression pattern
$selectedAsset = $releaseInfo.assets | Where-Object { $_.name -match $pattern }

if ($selectedAsset) {
    # Get the asset download URL, name, and size
    $assetUrl = $selectedAsset.browser_download_url
    $assetName = $selectedAsset.name

    # Set the destination path for the downloaded asset in the current directory
    $destinationPath = Join-Path -Path $PSScriptRoot -ChildPath $assetName

    # Download the asset
    Download-File -Url $assetUrl -FileName $destinationPath
    $downloadedFilePath = $currentDirectory + "\$assetName"

    # Extract the downloaded file
    $unzipDestination = $PSScriptRoot
    Extract-7z -ArchivePath $downloadedFilePath -DestinationPath $unzipDestination
    $extractedFolderPath = "\mingw64\*"

    # Set the SourcePath for Inno Setup
    $sourcePath = Join-Path -Path $currentDirectory -ChildPath $extractedFolderPath

    # Set the variables for Inno Setup
    $name = "Easy MinGW Installer"
    $version = [regex]::Match($assetName, $versionRegex).Value

    # Build the installer
    Build-Installer -Name $name -Version $version -SourcePath $sourcePath
} else {
    Write-Host "No asset matching the pattern was found."
}
