# ============================================================================
# Easy MinGW Installer - Core Functions Module
# ============================================================================
# Contains all business logic for GitHub API, downloads, extraction, and builds.
# ============================================================================

# Module-scoped state
$script:GitHubApiCache = @{}

# ============================================================================
# GitHub API Functions
# ============================================================================

function Invoke-GitHubApi {
    <#
    .SYNOPSIS
        Makes a cached HTTP request to the GitHub API.
    .DESCRIPTION
        Performs GET requests to GitHub API with caching, proper user-agent,
        and error handling. Cached responses are returned for repeated calls.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        
        [string]$Method = 'GET',
        [hashtable]$Headers = @{ 'Accept' = 'application/vnd.github.v3+json' },
        [int]$TimeoutSec = 30
    )

    $config = Get-BuildConfig
    
    # Add user agent if not present
    if (-not $Headers.ContainsKey('User-Agent')) {
        $Headers['User-Agent'] = $config.GitHubUserAgent
    }

    # Return cached response for GET requests
    if ($Method -eq 'GET' -and $script:GitHubApiCache.ContainsKey($Uri)) {
        Write-LogEntry -Type 'GitHub API' -Message "Using cached response for $Uri"
        return $script:GitHubApiCache[$Uri]
    }

    try {
        Write-LogEntry -Type 'GitHub API' -Message "Requesting $Uri"
        $response = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        
        # Cache GET responses
        if ($Method -eq 'GET') {
            $script:GitHubApiCache[$Uri] = $response
        }
        
        return $response
    }
    catch {
        Write-ErrorMessage -ErrorType 'API Request Failed' -Message "Error fetching '$Uri': $($_.Exception.Message)"
        return $null
    }
}

function Get-LatestGitHubTag {
    <#
    .SYNOPSIS
        Gets the latest tag from a GitHub repository.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,
        
        [Parameter(Mandatory)]
        [string]$Repo
    )

    $config = Get-BuildConfig
    $tagsUrl = "$($config.GitHubApiBase)/repos/$Owner/$Repo/tags"
    $tagsInfo = Invoke-GitHubApi -Uri $tagsUrl
    
    if ($tagsInfo -and $tagsInfo.Count -gt 0) {
        $latestTag = $tagsInfo[0].name
        Write-StatusInfo -Type 'Latest Tag' -Message "$latestTag (for $Owner/$Repo)"
        return $latestTag
    }
    
    Write-WarningMessage -Type 'API Warning' -Message "No tags found for $Owner/$Repo."
    return $null
}

function Find-GitHubRelease {
    <#
    .SYNOPSIS
        Finds a GitHub release matching a title pattern.
    .DESCRIPTION
        Searches releases for a non-prerelease matching the pattern,
        returning the most recently published match.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,
        
        [Parameter(Mandatory)]
        [string]$Repo,
        
        [Parameter(Mandatory)]
        [string]$TitlePattern
    )

    $config = Get-BuildConfig
    $releasesUrl = "$($config.GitHubApiBase)/repos/$Owner/$Repo/releases"
    $releasesInfo = Invoke-GitHubApi -Uri $releasesUrl
    
    if (-not $releasesInfo) {
        Write-WarningMessage -Type 'Release Search' -Message "Could not fetch releases for $Owner/$Repo."
        return $null
    }

    # Find matching non-prerelease, sorted by date descending
    $selectedRelease = $releasesInfo |
        Where-Object { $_.name -like $TitlePattern -and -not $_.prerelease } |
        Sort-Object { Get-Date $_.published_at } -Descending |
        Select-Object -First 1

    if ($selectedRelease) {
        Write-StatusInfo -Type 'Selected Release' -Message "$($selectedRelease.name) (from $Owner/$Repo)"
        $parsedTime = ConvertTo-VersionStringFromDate -DateString $selectedRelease.published_at -FormatType Display
        Write-StatusInfo -Type 'Release Date' -Message $parsedTime
    }
    else {
        Write-WarningMessage -Type 'Release Search' -Message "No release found matching pattern '$TitlePattern' for $Owner/$Repo."
    }
    
    return $selectedRelease
}

function Get-ReleaseMetadata {
    <#
    .SYNOPSIS
        Extracts standardized metadata from a release object.
    .DESCRIPTION
        Creates a metadata object with version string, dates, and original release info.
        In test mode, returns mock metadata.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [PSCustomObject]$ReleaseInfo,
        [switch]$IsTestMode
    )

    $config = Get-BuildConfig

    if ($IsTestMode) {
        $now = Get-Date
        return [PSCustomObject]@{
            Release              = $ReleaseInfo
            Version              = $config.TestModeVersion
            PublishedDate        = $now
            PublishedDateDisplay = $now.ToString('dd-MMM-yyyy HH:mm:ss')
            PublishedDateForInfo = $now.ToString('yyyy-MM-dd')
            IsTestMode           = $true
        }
    }

    if (-not $ReleaseInfo) {
        throw 'Release information is required when not in test mode.'
    }

    $published = Get-Date -Date $ReleaseInfo.published_at
    return [PSCustomObject]@{
        Release              = $ReleaseInfo
        Version              = ConvertTo-VersionStringFromDate -DateString $ReleaseInfo.published_at -FormatType Version
        PublishedDate        = $published
        PublishedDateDisplay = ConvertTo-VersionStringFromDate -DateString $ReleaseInfo.published_at -FormatType Display
        PublishedDateForInfo = $published.ToString('yyyy-MM-dd')
        IsTestMode           = $false
    }
}

# ============================================================================
# Utility Functions
# ============================================================================

function ConvertTo-VersionStringFromDate {
    <#
    .SYNOPSIS
        Converts a date string to a version or display format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DateString,
        
        [ValidateSet('Version', 'Display')]
        [string]$FormatType = 'Display'
    )

    try {
        $dateObject = Get-Date -Date $DateString
        if ($FormatType -eq 'Version') {
            return $dateObject.ToString('yyyy.MM.dd')
        }
        return $dateObject.ToString('dd-MMM-yyyy HH:mm:ss')
    }
    catch {
        Write-WarningMessage -Type 'Date Format' -Message "Could not parse date string '$DateString': $($_.Exception.Message)"
        return $DateString
    }
}

function Ensure-Directory {
    <#
    .SYNOPSIS
        Creates a directory if it doesn't exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not (Test-Path $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Remove-DirectoryRecursive {
    <#
    .SYNOPSIS
        Removes a directory and all its contents.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path $Path) {
        Write-ActionProgress -ActionName 'Cleaning' -Details "Removing directory $Path"
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-ColoredHost -Text "    Successfully removed $Path" -ForegroundColor $script:colors.Green
        }
        catch {
            Write-WarningMessage -Type 'Cleanup Warning' -Message "Failed to remove folder '$Path': $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# Download Functions
# ============================================================================

function Invoke-FileDownload {
    <#
    .SYNOPSIS
        Downloads a file with retry logic and progress display.
    .DESCRIPTION
        Downloads from URL to destination with configurable retries,
        progress reporting, and proper error handling.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        
        [Parameter(Mandatory)]
        [string]$DestinationFile,
        
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 5,
        [int]$TimeoutSeconds = 300
    )

    $config = Get-BuildConfig
    
    Write-ActionProgress -ActionName 'Preparing Download' -Details "From: $Url"
    
    # Ensure destination directory exists
    $destinationDirectory = Split-Path -Path $DestinationFile -Parent
    if ($destinationDirectory) { 
        Ensure-Directory -Path $destinationDirectory 
    }

    $userAgent = 'Easy-MinGW-Installer-Builder-Script/1.0'
    $currentTry = 0
    $downloadSuccess = $false

    while ($currentTry -lt $MaxRetries -and -not $downloadSuccess) {
        $currentTry++
        
        if ($currentTry -gt 1) {
            Write-WarningMessage -Type 'Download Retry' -Message "Attempt $currentTry of $MaxRetries after $RetryDelaySeconds seconds..."
            Start-Sleep -Seconds $RetryDelaySeconds
        }

        if (-not $config.IsGitHubActions) {
            Write-LogEntry -Type 'Download' -Message "Starting download attempt $currentTry for $Url..."
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

            $targetStream = [System.IO.File]::Create($DestinationFile)
            $buffer = New-Object byte[] $config.DownloadBufferSize
            $downloadedBytes = 0
            $lastReportedProgressPercentage = -1

            while ($true) {
                $bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)
                if ($bytesRead -eq 0) { break }

                $targetStream.Write($buffer, 0, $bytesRead)
                $downloadedBytes += $bytesRead

                if (-not $config.IsGitHubActions -and $totalLength -gt 0) {
                    $currentProgressPercentage = [System.Math]::Floor(($downloadedBytes / $totalLength) * 100)
                    if ($currentProgressPercentage -gt $lastReportedProgressPercentage) {
                        $progressText = "    Progress (Attempt $currentTry): $([System.Math]::Floor($downloadedBytes / 1024))KB / ${totalLengthKB}KB ($currentProgressPercentage%)"
                        Write-UpdatingLine -Text $progressText
                        $lastReportedProgressPercentage = $currentProgressPercentage
                    }
                }
            }
            
            if (-not $config.IsGitHubActions) {
                End-UpdatingLine
            }

            Write-ColoredHost -Text "    Download successful: $DestinationFile (Attempt $currentTry)" -ForegroundColor $script:colors.Green
            $downloadSuccess = $true
        }
        catch [System.Net.WebException] {
            if (-not $config.IsGitHubActions) { End-UpdatingLine }
            $ex = $_.Exception
            $errorMessage = "WebException during download (Attempt $currentTry): $($ex.Message)"
            if ($ex.Response) {
                $statusCode = [int]$ex.Response.StatusCode
                $statusDescription = $ex.Response.StatusDescription
                $errorMessage += " | Status: $statusCode ($statusDescription)"
            }
            Write-ErrorMessage -ErrorType 'Download Attempt Failed' -Message $errorMessage
            if ($ex.Response) { $ex.Response.Dispose() }
        }
        catch {
            if (-not $config.IsGitHubActions) { End-UpdatingLine }
            Write-ErrorMessage -ErrorType 'Download Attempt Failed' -Message "Generic error during download (Attempt $currentTry): $($_.Exception.Message)"
        }
        finally {
            if ($targetStream) { $targetStream.Dispose() }
            if ($responseStream) { $responseStream.Dispose() }
            if ($response) { $response.Dispose() }
        }
    }

    if (-not $downloadSuccess) {
        Write-ErrorMessage -ErrorType 'Download Failed' -Message "Failed to download '$Url' after $MaxRetries attempts."
    }
    
    return $downloadSuccess
}

# ============================================================================
# Extraction Functions
# ============================================================================

function Expand-SevenZipArchive {
    <#
    .SYNOPSIS
        Extracts an archive using 7-Zip.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ArchivePath,
        
        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $config = Get-BuildConfig
    
    Write-ActionProgress -ActionName 'Extracting' -Details $ArchivePath
    
    if (-not (Test-Path $config.SevenZipPath -PathType Leaf)) {
        Write-ErrorMessage -ErrorType 'Configuration Error' -Message "7-Zip executable not found at '$($config.SevenZipPath)'."
        throw "7-Zip not found at $($config.SevenZipPath)"
    }

    $arguments = "x `"$ArchivePath`" -o`"$DestinationPath`" -y"
    
    try {
        $process = Start-Process -FilePath $config.SevenZipPath -ArgumentList $arguments -Wait -NoNewWindow -PassThru -ErrorAction Stop
        
        if ($process.ExitCode -eq 0) {
            Write-ColoredHost -Text "    Extraction complete to $DestinationPath" -ForegroundColor $script:colors.Green
            return $true
        }
        
        Write-ErrorMessage -ErrorType 'Extraction Failed' -Message "7-Zip failed for '$ArchivePath'. Exit Code: $($process.ExitCode)"
        return $false
    }
    catch {
        Write-ErrorMessage -ErrorType 'Process Error' -Message "Exception during 7-Zip execution: $($_.Exception.Message)"
        throw
    }
}

# ============================================================================
# Changelog Functions
# ============================================================================

function New-FallbackChangelog {
    <#
    .SYNOPSIS
        Creates a minimal fallback changelog when Python generation fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,
        
        [Parameter(Mandatory)]
        [string]$Version,
        
        [string]$PackageInfoPath
    )

    Write-WarningMessage -Type 'Changelog' -Message 'Using fallback changelog template'

    $packageInfo = ''
    if ($PackageInfoPath -and (Test-Path $PackageInfoPath)) {
        $content = Get-Content $PackageInfoPath -Raw -ErrorAction SilentlyContinue
        if ($content) {
            # Extract package list from version_info.txt
            $lines = $content -split "`n" | Where-Object { $_ -match '^- ' }
            if ($lines) {
                $packageInfo = "## Package Info`n$($lines -join "`n")`n`n"
            }
        }
    }

    $changelog = @"
# Release $Version

$packageInfo## Script/Installer Changelogs
* No automated changelog available

### File Hash
"@

    Set-Content -Path $OutputPath -Value $changelog -Encoding UTF8
    Write-StatusInfo -Type 'Changelog' -Message "Fallback changelog created at $OutputPath"
    return $true
}

function Invoke-ChangelogGeneration {
    <#
    .SYNOPSIS
        Generates release notes using the Python script with fallback.
    .DESCRIPTION
        Attempts to run the Python changelog generator. If it fails for any reason
        (Python not installed, API error, etc.), creates a minimal fallback changelog.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BuildInfoPath,
        
        [Parameter(Mandatory)]
        [string]$OutputPath,
        
        [Parameter(Mandatory)]
        [string]$CurrentVersion,
        
        [string]$PreviousTag,
        [string]$Owner,
        [string]$Repo
    )

    $config = Get-BuildConfig

    # Skip if changelog already exists
    if (Test-Path $OutputPath) {
        Write-StatusInfo -Type 'Changelog' -Message "Release notes already exist at $OutputPath"
        return $true
    }

    # Check if source info exists
    if (-not (Test-Path $BuildInfoPath)) {
        Write-WarningMessage -Type 'Changelog' -Message "Build info file not found: $BuildInfoPath"
        return New-FallbackChangelog -OutputPath $OutputPath -Version $CurrentVersion
    }

    # Use defaults from config if not provided
    if (-not $Owner) { $Owner = $config.ProjectOwner }
    if (-not $Repo) { $Repo = $config.ProjectRepo }
    if (-not $PreviousTag) { $PreviousTag = 'HEAD' }

    Write-StatusInfo -Type 'Changelog Generation' -Message 'Attempting to generate release notes...'

    $pythonScript = Join-Path $PSScriptRoot 'generate_changelog.py'
    
    if (-not (Test-Path $pythonScript)) {
        Write-WarningMessage -Type 'Changelog' -Message "Python script not found: $pythonScript"
        return New-FallbackChangelog -OutputPath $OutputPath -Version $CurrentVersion -PackageInfoPath $BuildInfoPath
    }

    # Check if Python is available
    try {
        $null = & python --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'Python not available'
        }
    }
    catch {
        Write-WarningMessage -Type 'Changelog' -Message 'Python not installed or not in PATH'
        return New-FallbackChangelog -OutputPath $OutputPath -Version $CurrentVersion -PackageInfoPath $BuildInfoPath
    }

    # Build Python arguments
    $pythonArgs = @(
        $pythonScript
        '--input-file', "`"$BuildInfoPath`""
        '--output-file', "`"$OutputPath`""
        '--prev-tag', "`"$PreviousTag`""
        '--current-build-tag', "`"$CurrentVersion`""
        '--github-owner', $Owner
        '--github-repo', $Repo
    )

    Write-LogEntry -Type 'Python Call' -Message "python $($pythonArgs -join ' ')"

    try {
        $processInfo = Start-Process -FilePath 'python' -ArgumentList $pythonArgs -Wait -NoNewWindow -PassThru -ErrorAction SilentlyContinue
        
        if ($processInfo.ExitCode -ne 0) {
            Write-WarningMessage -Type 'Changelog' -Message "Python script exited with code $($processInfo.ExitCode)"
            return New-FallbackChangelog -OutputPath $OutputPath -Version $CurrentVersion -PackageInfoPath $BuildInfoPath
        }
        
        if (Test-Path $OutputPath) {
            Write-SuccessMessage -Type 'Changelog Generated' -Message "Release notes created at $OutputPath"
            return $true
        }
        else {
            Write-WarningMessage -Type 'Changelog' -Message 'Python script ran but output file not found'
            return New-FallbackChangelog -OutputPath $OutputPath -Version $CurrentVersion -PackageInfoPath $BuildInfoPath
        }
    }
    catch {
        Write-WarningMessage -Type 'Changelog' -Message "Error running Python script: $($_.Exception.Message)"
        return New-FallbackChangelog -OutputPath $OutputPath -Version $CurrentVersion -PackageInfoPath $BuildInfoPath
    }
}

# ============================================================================
# Build Functions
# ============================================================================

function Invoke-InnoSetupBuild {
    <#
    .SYNOPSIS
        Builds an installer using Inno Setup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstallerName,
        
        [Parameter(Mandatory)]
        [string]$OutputName,
        
        [Parameter(Mandatory)]
        [string]$Version,
        
        [Parameter(Mandatory)]
        [string]$Architecture,
        
        [Parameter(Mandatory)]
        [string]$SourceContentPath,
        
        [Parameter(Mandatory)]
        [string]$OutputDirectory,
        
        [Parameter(Mandatory)]
        [string]$InnoSetupScriptPath,
        
        [switch]$GenerateLogsAlways
    )

    $config = Get-BuildConfig

    Write-ActionProgress -ActionName 'Building Installer' -Details "$InstallerName $Version ($Architecture)"
    
    $logFileName = "build_${OutputName}_${Architecture}.log"
    $logFilePath = Join-Path $PSScriptRoot "..\$logFileName"

    $arguments = "/DMyAppName=`"$InstallerName`" /DMyOutputName=`"$OutputName`" /DMyAppVersion=`"$Version`" /DArch=`"$Architecture`" /DSourcePath=`"$SourceContentPath`" /DOutputPath=`"$OutputDirectory`""
    
    $installerExeName = "$OutputName.v$Version.$Architecture-bit.exe"
    $installerExeFullPath = Join-Path $OutputDirectory $installerExeName
    
    $stdOutFile = $null
    $stdErrFile = $null
    $installerBuiltSuccessfully = $false

    try {
        Ensure-Directory -Path $OutputDirectory

        $stdOutFile = [System.IO.Path]::GetTempFileName()
        $stdErrFile = [System.IO.Path]::GetTempFileName()

        $process = Start-Process -FilePath $config.InnoSetupPath -ArgumentList $InnoSetupScriptPath, $arguments `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput $stdOutFile -RedirectStandardError $stdErrFile -ErrorAction Stop
        
        $exitCode = $process.ExitCode
        $stdOutContent = Get-Content $stdOutFile -Raw -ErrorAction SilentlyContinue
        $stdErrContent = Get-Content $stdErrFile -Raw -ErrorAction SilentlyContinue

        if ($exitCode -ne 0 -or $GenerateLogsAlways) {
            $logContent = "Timestamp: $(Get-Date -Format 'u')`nInno Setup Arguments: $arguments`n`nStandard Output:`n$stdOutContent`n`nStandard Error:`n$stdErrContent`nExit Code: $exitCode"
            Set-Content -Path $logFilePath -Value $logContent -Encoding UTF8
            
            if ($exitCode -ne 0) {
                Write-ErrorMessage -ErrorType 'Build Failed' -Message "$InstallerName ($Architecture) compilation failed." -LogFilePath $logFilePath -AssociatedExitCode $exitCode
                return $false
            }
            
            Write-ColoredHost -Text "    Build Succeeded (Log generated): $InstallerName ($Architecture)" -ForegroundColor $script:colors.Green
            Write-StatusInfo -Type 'Log File' -Message $logFilePath
            $installerBuiltSuccessfully = $true
        }
        else {
            Write-ColoredHost -Text "    Build Succeeded: $InstallerName ($Architecture)" -ForegroundColor $script:colors.Green
            $installerBuiltSuccessfully = $true
        }

        # Generate hashes if build succeeded
        if ($installerBuiltSuccessfully -and (Test-Path $installerExeFullPath -PathType Leaf)) {
            Invoke-HashGeneration -FilePath $installerExeFullPath -OutputName $OutputName -Version $Version -Architecture $Architecture -OutputDirectory $OutputDirectory
        }
        elseif ($installerBuiltSuccessfully) {
            Write-WarningMessage -Type 'Hash Skip' -Message "Installer EXE not found at '$installerExeFullPath'. Skipping hash generation."
        }

        return $installerBuiltSuccessfully
    }
    catch {
        Write-ErrorMessage -ErrorType 'InnoSetup Error' -Message "Exception during Inno Setup for $Architecture : $($_.Exception.Message)" -LogFilePath $logFilePath
        return $false
    }
    finally {
        if ($stdOutFile -and (Test-Path $stdOutFile)) { Remove-Item $stdOutFile -Force -ErrorAction SilentlyContinue }
        if ($stdErrFile -and (Test-Path $stdErrFile)) { Remove-Item $stdErrFile -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-HashGeneration {
    <#
    .SYNOPSIS
        Generates file hashes for an installer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        
        [Parameter(Mandatory)]
        [string]$OutputName,
        
        [Parameter(Mandatory)]
        [string]$Version,
        
        [Parameter(Mandatory)]
        [string]$Architecture,
        
        [Parameter(Mandatory)]
        [string]$OutputDirectory
    )

    $config = Get-BuildConfig
    
    Write-StatusInfo -Type 'Hash Generation' -Message "Generating hashes for $(Split-Path $FilePath -Leaf)..."
    
    $hashFileName = "$OutputName.v$Version.$Architecture-bit.hashes.txt"
    $hashOutputFilePath = Join-Path $OutputDirectory $hashFileName
    $formatHashesScriptPath = Join-Path $PSScriptRoot 'Format-7ZipHashes.ps1'

    if (-not (Test-Path $formatHashesScriptPath -PathType Leaf)) {
        Write-WarningMessage -Type 'Hash Script Missing' -Message "Format-7ZipHashes.ps1 not found at '$formatHashesScriptPath'. Skipping hash generation."
        return
    }

    try {
        & $formatHashesScriptPath -FilePath $FilePath -SevenZipExePath $config.SevenZipPath | Out-File -FilePath $hashOutputFilePath -Encoding utf8 -Force
        Write-StatusInfo -Type 'Hash File' -Message "Hashes saved to $hashOutputFilePath"
    }
    catch {
        Write-WarningMessage -Type 'Hash Gen Error' -Message "Failed to generate hashes: $($_.Exception.Message)"
    }
}

# ============================================================================
# Asset Discovery Functions
# ============================================================================

function Get-WinLibsAsset {
    <#
    .SYNOPSIS
        Finds the appropriate asset from a WinLibs release.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$ReleaseInfo,
        
        [Parameter(Mandatory)]
        [string]$AssetPattern,
        
        [Parameter(Mandatory)]
        [string]$Architecture
    )

    $selectedAsset = $ReleaseInfo.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
    
    if ($selectedAsset) {
        Write-StatusInfo -Type 'Asset Found' -Message $selectedAsset.name
        return $selectedAsset
    }
    
    Write-ErrorMessage -ErrorType 'Asset Error' -Message "No asset found in release '$($ReleaseInfo.name)' matching pattern '$AssetPattern'."
    return $null
}

function Get-TestModeAsset {
    <#
    .SYNOPSIS
        Creates a mock asset for test mode.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Architecture
    )

    $mockAsset = @{
        name                  = "mingw-w64-$Architecture-Test.7z"
        browser_download_url  = 'file:///placeholder-for-test.7z'
    }
    
    Write-StatusInfo -Type 'Asset (Test Mode)' -Message $mockAsset.name
    return [PSCustomObject]$mockAsset
}

# ============================================================================
# Test Fixtures
# ============================================================================

function Initialize-TestFixtures {
    <#
    .SYNOPSIS
        Creates minimal test fixtures for test mode builds.
    .DESCRIPTION
        Creates a minimal directory structure with dummy files so Inno Setup
        can run in test mode without requiring actual MinGW binaries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter(Mandatory)]
        [string]$Architecture,
        
        [string]$PublishedDate
    )

    Write-StatusInfo -Type 'Test Mode' -Message "Creating test fixtures for $Architecture-bit"
    
    Ensure-Directory -Path $SourcePath
    Ensure-Directory -Path (Join-Path $SourcePath 'bin')

    # Create version_info.txt
    $versionInfoContent = @"
winlibs personal build version gcc-TEST.0-mingw-w64ucrt-TEST.0-r0
This is the winlibs Intel/AMD $Architecture-bit standalone build of:
- GCC TEST.0
- GDB TEST.0
Thread model: POSIX
Runtime library: UCRT (Test Mode)
This build was compiled with GCC TEST.0 and packaged on $PublishedDate.
"@
    Set-Content -Path (Join-Path $SourcePath 'version_info.txt') -Value $versionInfoContent -Encoding UTF8

    # Create minimal dummy executable (so Inno Setup has something to package)
    $dummyExePath = Join-Path $SourcePath 'bin\gcc.exe'
    
    # Check for existing test fixture
    $fixturesPath = Join-Path $PSScriptRoot '..\test\fixtures'
    $fixtureDummyExe = Join-Path $fixturesPath 'dummy.exe'
    
    if (Test-Path $fixtureDummyExe) {
        Copy-Item $fixtureDummyExe $dummyExePath -Force
    }
    else {
        # Create a minimal file (1KB of zeros)
        $bytes = New-Object byte[] 1024
        [System.IO.File]::WriteAllBytes($dummyExePath, $bytes)
    }

    Write-StatusInfo -Type 'Test Fixtures' -Message "Created at $SourcePath"
}

# ============================================================================
# Main Compilation Function
# ============================================================================

function Invoke-MingwCompilation {
    <#
    .SYNOPSIS
        Processes a single architecture build.
    .DESCRIPTION
        Handles the complete build pipeline for one architecture:
        download, extraction, changelog generation, and installer build.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Architecture,
        
        [Parameter(Mandatory)]
        [string]$AssetPattern,
        
        [Parameter(Mandatory)]
        [PSCustomObject]$ReleaseMetadata,
        
        [PSCustomObject]$ReleaseInfo,
        
        [string]$ProjectLatestTag,
        
        [Parameter(Mandatory)]
        [string]$FinalOutputPath,
        
        [Parameter(Mandatory)]
        [string]$TempDirectory,
        
        [Parameter(Mandatory)]
        [string]$InnoSetupScriptPath,
        
        [Parameter(Mandatory)]
        [string]$ReleaseNotesPath,
        
        [switch]$SkipIfVersionMatchesTag,
        [switch]$GenerateLogsAlways
    )

    $config = Get-BuildConfig
    
    Write-SeparatorLine
    Write-StatusInfo -Type 'Processing Arch' -Message "$Architecture-bit"

    $releaseVersion = $ReleaseMetadata.Version
    $publishedDateForInfo = $ReleaseMetadata.PublishedDateForInfo

    # Get asset
    $selectedAsset = if ($config.IsTestMode) {
        Get-TestModeAsset -Architecture $Architecture
    }
    else {
        Get-WinLibsAsset -ReleaseInfo $ReleaseInfo -AssetPattern $AssetPattern -Architecture $Architecture
    }

    if (-not $selectedAsset) {
        return $false
    }

    Write-StatusInfo -Type 'Release Version' -Message $releaseVersion

    # Create tag file for GitHub Actions
    if ($config.IsGitHubActions) {
        $repoRootPath = (Get-Item $PSScriptRoot).Parent.FullName
        $tagFileDir = Join-Path $repoRootPath 'tag'
        Ensure-Directory -Path $tagFileDir
        New-Item -Path (Join-Path $tagFileDir $releaseVersion) -ItemType File -Force -ErrorAction SilentlyContinue | Out-Null
        Write-LogEntry -Type 'GitHub Actions' -Message "Tag file created for '$releaseVersion'"
    }

    # Version check
    if ($SkipIfVersionMatchesTag -and -not $config.IsTestMode) {
        if (-not $ProjectLatestTag) {
            Write-WarningMessage -Type 'Version Check' -Message "Project's latest tag not available. Proceeding with build."
        }
        elseif ($ProjectLatestTag -eq $releaseVersion) {
            Write-StatusInfo -Type 'Version Check' -Message "Version $releaseVersion matches project tag. Skipping build for $Architecture-bit."
            return $true
        }
        else {
            Write-StatusInfo -Type 'Version Check' -Message "New version $releaseVersion available (Project tag: $ProjectLatestTag)."
        }
    }

    # Setup paths
    $archTempDir = Join-Path $TempDirectory "mingw$Architecture"
    $sourcePathForInstaller = Join-Path $archTempDir "mingw$Architecture"
    $currentBuildInfoFilePath = Join-Path $archTempDir 'current_build_info.txt'

    try {
        # Clean and create temp directory
        if (Test-Path $archTempDir) {
            Remove-DirectoryRecursive -Path $archTempDir
        }
        Ensure-Directory -Path $archTempDir

        if ($config.IsTestMode -or $config.SkipDownload) {
            # Test mode: create fixtures
            Initialize-TestFixtures -SourcePath $sourcePathForInstaller -Architecture $Architecture -PublishedDate $publishedDateForInfo
            
            # Create build info file for changelog
            $versionInfoPath = Join-Path $sourcePathForInstaller 'version_info.txt'
            if (Test-Path $versionInfoPath) {
                Copy-Item $versionInfoPath $currentBuildInfoFilePath -Force
            }
        }
        else {
            # Normal mode: download and extract
            $downloadedFilePath = Join-Path $archTempDir $selectedAsset.name
            
            if (-not (Invoke-FileDownload -Url $selectedAsset.browser_download_url -DestinationFile $downloadedFilePath)) {
                throw "Download failed for $($selectedAsset.name)"
            }
            
            if (-not (Expand-SevenZipArchive -ArchivePath $downloadedFilePath -DestinationPath $archTempDir)) {
                throw "Extraction failed for $($selectedAsset.name)"
            }

            # Auto-detect extracted folder
            $extractedDirs = Get-ChildItem -Path $archTempDir -Directory | Where-Object { $_.Name -like 'mingw*' }
            
            if ($extractedDirs.Count -eq 1) {
                $sourcePathForInstaller = $extractedDirs[0].FullName
                Write-StatusInfo -Type 'Extraction Path' -Message "Source: $sourcePathForInstaller"
            }
            elseif ($extractedDirs.Count -gt 1) {
                Write-WarningMessage -Type 'Extraction' -Message "Multiple mingw* directories found. Using: $($extractedDirs[0].FullName)"
                $sourcePathForInstaller = $extractedDirs[0].FullName
            }
            else {
                throw 'Could not find extracted MinGW folder'
            }

            # Prepare changelog source file
            $winlibsInfoFileSource = Join-Path $sourcePathForInstaller 'version_info.txt'
            if (Test-Path $winlibsInfoFileSource -PathType Leaf) {
                Write-StatusInfo -Type 'Changelog Source' -Message "Using '$winlibsInfoFileSource'"
                $fileContent = Get-Content -Path $winlibsInfoFileSource -Raw -Encoding UTF8
                if ($fileContent -notmatch 'packaged on' -and $publishedDateForInfo) {
                    $fileContent += "`nThis build was compiled with GCC and packaged on $publishedDateForInfo."
                }
                Set-Content -Path $currentBuildInfoFilePath -Value $fileContent -Encoding UTF8
            }
            else {
                Write-WarningMessage -Type 'Changelog Source' -Message "version_info.txt not found. Using placeholder."
                Initialize-TestFixtures -SourcePath $sourcePathForInstaller -Architecture $Architecture -PublishedDate $publishedDateForInfo
                $versionInfoPath = Join-Path $sourcePathForInstaller 'version_info.txt'
                if (Test-Path $versionInfoPath) {
                    Copy-Item $versionInfoPath $currentBuildInfoFilePath -Force
                }
            }
        }

        # Generate changelog (only once, for first architecture)
        if (-not $config.SkipChangelog) {
            Invoke-ChangelogGeneration `
                -BuildInfoPath $currentBuildInfoFilePath `
                -OutputPath $ReleaseNotesPath `
                -CurrentVersion $releaseVersion `
                -PreviousTag $ProjectLatestTag `
                -Owner $config.ProjectOwner `
                -Repo $config.ProjectRepo
        }

        # Build installer
        if (-not $config.SkipBuild) {
            $buildResult = Invoke-InnoSetupBuild `
                -InstallerName $config.InstallerName `
                -OutputName $config.InstallerBaseName `
                -Version $releaseVersion `
                -Architecture $Architecture `
                -SourceContentPath $sourcePathForInstaller `
                -OutputDirectory $FinalOutputPath `
                -InnoSetupScriptPath $InnoSetupScriptPath `
                -GenerateLogsAlways:$GenerateLogsAlways

            return $buildResult
        }
        else {
            Write-StatusInfo -Type 'Build Skipped' -Message "Skipping Inno Setup build for $Architecture-bit (SkipBuild enabled)"
            return $true
        }
    }
    catch {
        Write-ErrorMessage -ErrorType 'Compilation Failed' -Message "Error processing $Architecture-bit MinGW: $($_.Exception.Message)"
        return $false
    }
    finally {
        # Cleanup temp directory for this architecture
        if (-not $config.IsTestMode -and (Test-Path $archTempDir)) {
            Remove-DirectoryRecursive -Path $archTempDir
        }
    }
}

# ============================================================================
# Module Initialization
# ============================================================================

function Reset-ModuleState {
    <#
    .SYNOPSIS
        Resets module-level state for fresh runs.
    #>
    [CmdletBinding()]
    param()

    $script:GitHubApiCache = @{}
}

# Initialize on module load
Reset-ModuleState
