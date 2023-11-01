param(
    [Parameter(Mandatory = $true)]
    [string]$arch,

    [Parameter(Mandatory = $true)]
    [string]$titlePattern

    [Parameter(Mandatory = $true)]
    [string]$namePattern
)

$currentDirectory = $PWD.Path

function Download-File {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    Write-Host " -> Downloading $FileName..."

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
        [System.Console]::Write("  >> Downloaded {0}K of {1}K ({2}%) <<   ", [System.Math]::Floor($downloadedBytes / 1024), $totalLength, [System.Math]::Floor(($downloadedBytes / $response.ContentLength) * 100))
    }

    $targetStream.Flush()
    $targetStream.Close()
    $targetStream.Dispose()
    $responseStream.Dispose()

    Write-Host "`n -> Download completed."
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
        Write-Host " -> ERROR: 7-Zip executable not found at '$7zExe'. Please make sure 7-Zip is installed or update the path to the 7z.exe file."
        return
    }

    Write-Host " -> Extracting $ArchivePath"

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
        Write-Host " -> Extraction completed."
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
        Write-Host " -> Removed '$FolderPath'"
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
        Write-Host " -> Builing $Name Failed!"
        Exit 1
    }

    Write-Host " -> Builing $Name. Path: $SourcePath"

    $innoSetupPath = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    $installerScript = "MinGW_Installer.iss"

    $arguments = "/DMyAppName=`"$Name`" /DMyAppVersion=`"$Version`" /DArch=`"$arch`" /DSourcePath=`"$SourcePath`""

    Start-Process -FilePath $innoSetupPath -ArgumentList $installerScript, $arguments -NoNewWindow -Wait

    Remove-Folder -FolderPath $SourcePath
}

function main {
    # Set the GitHub repository details
    $owner = "brechtsanders"
    $repo = "winlibs_mingw"

    # Set the regular expression pattern for the varying portion of the file name
    $pattern = $namePattern

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

    # Check if there are any release available
    $selectedAsset = $null
    if ($selectedRelease) {
        $selectedAsset = $selectedRelease.assets | Where-Object { $_.name -match $pattern }
        Write-Host " -> Selected Asset: $($selectedAsset.name)"
    }
    else {
        Write-Host " ERROR: No release found that match the filter criteria."
        Exit 1
    }

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
        $extractedFolderPath = "\mingw$arch"

        # Set the SourcePath for Inno Setup
        $sourcePath = Join-Path -Path $currentDirectory -ChildPath $extractedFolderPath

        # Set the variables for Inno Setup
        $name = "Easy MinGW Installer"
        $version = Get-Date -Date $selectedRelease.published_at -Format "yyyy.MM.dd"

        # Build the installer
        Build-Installer -Name $name -Version $version -SourcePath $sourcePath
    }
    else {
        Write-Host " -> ERROR: No asset matching the pattern was found."
        Exit 1
    }
}

main
