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

################
# Load modules #
################
. "$PSScriptRoot\modules\functions.ps1"

###############
# Prepare ENV #
###############
if ($archs.Count -eq 1) { $archs = $archs.Split(',') }
if ($namePatterns.Count -eq 1) { $namePatterns = $namePatterns.Split(',') }

$tempDir = [System.IO.Path]::GetTempPath() + "EasyMinGWInstaller"
if (Test-Path $tempDir) {
    Remove-Item -Path $tempDir -Recurse -Force
}

New-Item -ItemType Directory -Path $tempDir | Out-Null
Write-Host " -> Temp Directory: $tempDir"
Write-Host " -> Output Directory: $outputPath `n"

#################
# MAIN FUNCTION #
#################
function main {
    # Get the latest EMI tag
    $latestTag = Get-LatestTag -Owner "ehsan18t" -Repo "easy-mingw-installer"

    # Set the GitHub repository details
    $owner = "brechtsanders"
    $repo = "winlibs_mingw"

    # Filter releases based on the regular expression pattern in the title
    $selectedRelease = Get-Release -Owner $owner -Repo $repo -TitlePattern $titlePattern

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
                $version = Format-Date -Date $selectedRelease.published_at -asVersion

                # Check if new release is available
                if ($checkNewRelease) {
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
