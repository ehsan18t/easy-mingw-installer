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
    [switch]$generateLogsAlways,

    [Parameter(Mandatory = $false)]
    [switch]$testMode
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
    $latestTag = ""
    if ($testMode) {
        $latestTag = "v2030.01.01"
    } else {
        $latestTag = Get-LatestTag -Owner "ehsan18t" -Repo "easy-mingw-installer"
    }

    # Set the GitHub repository details
    $owner = "brechtsanders"
    $repo = "winlibs_mingw"

    # Filter releases based on the regular expression pattern in the title
    $selectedRelease = $null
    if (!$testMode) {
        $selectedRelease = Get-Release -Owner $owner -Repo $repo -TitlePattern $titlePattern
    }

    # for loop to iterate over the archs
    if ($archs.Length -eq $namePatterns.Length) {
        for ($i = 0; $i -lt $archs.Length; $i++) {
            Build-Binary -Arch $archs[$i] -Pattern $namePatterns[$i]
        }

        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force
        }
    } else {
        Write-Host " -> ERROR: Arrays are not of the same length."
        Exit 1
    }
}

main
