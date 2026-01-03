<#
.SYNOPSIS
    Core functions module for Easy MinGW Installer build system.

.DESCRIPTION
    This module contains all business logic for the build process. It is organized
    into the following functional areas:
    
    ═══════════════════════════════════════════════════════════════════════════════
    PROCESS MANAGEMENT
    ═══════════════════════════════════════════════════════════════════════════════
    Functions for managing child processes during builds, enabling graceful
    cancellation when Ctrl+C is pressed.
    
    - Register-ChildProcess    : Tracks a spawned process for cleanup
    - Stop-AllChildProcesses   : Kills all tracked processes on cancellation
    - Clear-ChildProcesses     : Clears tracking list after normal completion
    - Test-BuildCancelled      : Checks if build was cancelled
    - Set-BuildCancelled       : Marks build as cancelled
    - Invoke-CancellationCleanup : Performs full cleanup on Ctrl+C
    - Wait-ProcessWithCleanup  : Waits for process with Ctrl+C support
    
    ═══════════════════════════════════════════════════════════════════════════════
    GITHUB API FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════════
    Functions for interacting with GitHub's REST API to fetch release information.
    Includes caching to avoid duplicate requests.
    
    - Invoke-GitHubApi         : Makes cached API requests with error handling
    - Get-LatestGitHubTag      : Gets the most recent tag from a repository
    - Get-GitHubTags           : Gets multiple tags for changelog comparison
    - Find-GitHubRelease       : Finds a release matching a title pattern
    
    ═══════════════════════════════════════════════════════════════════════════════
    DOWNLOAD & EXTRACTION FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════════
    Functions for downloading files with progress display and extracting archives.
    
    - Invoke-FileDownload      : Downloads a file with retry logic and progress
    - Expand-7ZipArchive       : Extracts archives using 7-Zip
    - Format-FileSize          : Formats bytes to human-readable string
    
    ═══════════════════════════════════════════════════════════════════════════════
    TEST MODE FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════════
    Functions for creating test fixtures when running in test mode.
    
    - New-TestFixtures         : Creates minimal directory structure for testing
    
    ═══════════════════════════════════════════════════════════════════════════════
    CHANGELOG FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════════
    Functions for generating release changelogs from package information.
    
    - New-FallbackChangelog    : Creates basic changelog without Python
    - Invoke-ChangelogGeneration : Runs Python changelog generator
    
    ═══════════════════════════════════════════════════════════════════════════════
    BUILD FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════════
    Functions for building installers and generating file hashes.
    
    - Invoke-InstallerBuild    : Runs Inno Setup to create installer
    - Invoke-HashGeneration    : Generates file hashes using 7-Zip
    - Add-HashesToChangelog    : Appends hash blocks to release notes
    
    ═══════════════════════════════════════════════════════════════════════════════
    MAIN BUILD PIPELINE
    ═══════════════════════════════════════════════════════════════════════════════
    The main orchestration function that coordinates the entire build for an
    architecture.
    
    - Invoke-ArchitectureBuild : Complete build pipeline for one architecture

.NOTES
    File Name      : functions.ps1
    Location       : modules/functions.ps1
    Dependencies   : modules/config.ps1, modules/pretty.ps1
    
    SCRIPT-SCOPED VARIABLES:
    - $script:ApiCache       : Hashtable caching GitHub API responses
    - $script:ChildProcesses : ArrayList tracking spawned processes
    - $script:BuildCancelled : Boolean flag for cancellation state

.EXAMPLE
    # Functions are loaded via dot-sourcing in Builder.ps1:
    . "$PSScriptRoot\modules\functions.ps1"
    
    # Then used throughout the build:
    $release = Find-GitHubRelease -Owner 'brechtsanders' -Repo 'winlibs_mingw' -TitlePattern '*UCRT*POSIX*'
#>

# ============================================================================
# Easy MinGW Installer - Core Functions Module
# ============================================================================
# Contains all business logic for the build process:
#   - GitHub API interactions
#   - File downloads and extraction
#   - Test fixture generation
#   - Changelog generation
#   - Installer building and hash generation
# ============================================================================

# API response cache to avoid duplicate requests
$script:ApiCache = @{}

# Track spawned child processes for cancellation support
$script:ChildProcesses = [System.Collections.ArrayList]::new()
$script:BuildCancelled = $false

# ============================================================================
# Process Management Functions
# ============================================================================

function Register-ChildProcess {
    <#
    .SYNOPSIS
        Registers a child process for tracking (used for cancellation).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process
    )
    [void]$script:ChildProcesses.Add($Process)
}

function Stop-AllChildProcesses {
    <#
    .SYNOPSIS
        Stops all tracked child processes. Called during cancellation.
    #>
    [CmdletBinding()]
    param()

    foreach ($proc in $script:ChildProcesses) {
        try {
            if ($proc -and -not $proc.HasExited) {
                Write-Host "  Killing: $($proc.ProcessName) (PID: $($proc.Id))" -ForegroundColor Yellow
                $proc.Kill()
                $proc.WaitForExit(5000)  # Wait up to 5 seconds
            }
        }
        catch {
            # Process may have already exited, try taskkill as fallback
            try {
                $null = & taskkill /F /PID $proc.Id 2>&1
            }
            catch { }
        }
    }
    $script:ChildProcesses.Clear()
}

function Clear-ChildProcesses {
    <#
    .SYNOPSIS
        Clears the child process list (called after successful completion).
    #>
    [CmdletBinding()]
    param()
    $script:ChildProcesses.Clear()
}

function Test-BuildCancelled {
    <#
    .SYNOPSIS
        Returns whether the build has been cancelled.
    #>
    return $script:BuildCancelled
}

function Set-BuildCancelled {
    <#
    .SYNOPSIS
        Marks the build as cancelled.
    #>
    $script:BuildCancelled = $true
}

function Invoke-CancellationCleanup {
    <#
    .SYNOPSIS
        Performs comprehensive cleanup when build is cancelled via Ctrl+C.
    
    .DESCRIPTION
        This function is called when the user interrupts the build with Ctrl+C.
        It performs a thorough cleanup to leave the system in a clean state:
        
        CLEANUP SEQUENCE:
        1. Terminates all tracked child processes (7-Zip, Inno Setup, Python)
        2. Removes the temporary directory with downloaded/extracted files
        3. Removes the output directory with partial installer builds
        4. Removes the changelog file if it was being generated
        5. Removes any .log files created in the script root
        6. Displays a cancellation summary with elapsed time
        
        This ensures no partial or corrupted files are left behind after
        an interrupted build.
    
    .PARAMETER TempDirectory
        Path to the temporary build directory (e.g., %TEMP%\EasyMinGW_Build).
        Contains downloaded archives and extracted MinGW files.
    
    .PARAMETER OutputDirectory
        Path to the output directory (e.g., ./output).
        Contains built installers and hash files.
    
    .PARAMETER ChangelogPath
        Path to the release notes markdown file (e.g., ./release_notes_body.md).
    
    .PARAMETER StartTime
        The DateTime when the build started. Used to calculate total duration.
    
    .EXAMPLE
        Invoke-CancellationCleanup `
            -TempDirectory 'C:\Temp\EasyMinGW_Build' `
            -OutputDirectory '.\output' `
            -ChangelogPath '.\release_notes_body.md' `
            -StartTime $buildStartTime
    #>
    [CmdletBinding()]
    param(
        [string]$TempDirectory,
        [string]$OutputDirectory,
        [string]$ChangelogPath,
        [DateTime]$StartTime
    )

    Write-Host ""
    Write-SeparatorLine -Character '=' -Length 60
    Write-WarningMessage -Type 'CANCELLED' -Message 'Build interrupted - cleaning up...'
    Write-SeparatorLine -Character '-' -Length 60

    # Kill child processes
    Write-Host ""
    Write-StatusInfo -Type 'Processes' -Message 'Terminating child processes...'
    if ($script:ChildProcesses.Count -gt 0) {
        Stop-AllChildProcesses
        Write-SuccessMessage -Type 'Processes' -Message 'All child processes terminated'
    }
    else {
        Write-StatusInfo -Type 'Processes' -Message 'No child processes to stop'
    }

    # Clean temp directory
    if ($TempDirectory -and (Test-Path $TempDirectory)) {
        try {
            Remove-Item $TempDirectory -Recurse -Force -ErrorAction Stop
            Write-SuccessMessage -Type 'Temp' -Message "Removed: $TempDirectory"
        }
        catch {
            Write-WarningMessage -Type 'Temp' -Message "Failed to remove: $TempDirectory"
        }
    }

    # Clean output directory
    if ($OutputDirectory -and (Test-Path $OutputDirectory)) {
        try {
            Remove-Item $OutputDirectory -Recurse -Force -ErrorAction Stop
            Write-SuccessMessage -Type 'Output' -Message "Removed: $OutputDirectory"
        }
        catch {
            Write-WarningMessage -Type 'Output' -Message "Failed to remove: $OutputDirectory"
        }
    }

    # Clean changelog
    if ($ChangelogPath -and (Test-Path $ChangelogPath)) {
        try {
            Remove-Item $ChangelogPath -Force -ErrorAction Stop
            Write-SuccessMessage -Type 'Changelog' -Message "Removed: $(Split-Path $ChangelogPath -Leaf)"
        }
        catch {
            Write-WarningMessage -Type 'Changelog' -Message "Failed to remove changelog"
        }
    }

    # Clean log files in script root
    $scriptRoot = Split-Path $PSScriptRoot -Parent
    $logFiles = Get-ChildItem -Path $scriptRoot -Filter "*.log" -File -ErrorAction SilentlyContinue
    if ($logFiles) {
        $removedCount = 0
        foreach ($log in $logFiles) {
            try {
                Remove-Item $log.FullName -Force -ErrorAction Stop
                $removedCount++
            }
            catch { }
        }
        if ($removedCount -gt 0) {
            Write-SuccessMessage -Type 'Logs' -Message "Removed $removedCount log file(s)"
        }
    }

    # Calculate duration if start time provided
    $duration = if ($StartTime) { (Get-Date) - $StartTime } else { $null }

    # Final summary
    Write-Host ""
    Write-BuildSummary -Success $false -Cancelled -Duration $duration
}

function Wait-ProcessWithCleanup {
    <#
    .SYNOPSIS
        Waits for a process to exit, with support for Ctrl+C cleanup.
        Uses polling to allow the finally block to execute on termination.
    .PARAMETER Process
        The process to wait for.
    .PARAMETER CleanupPaths
        Hashtable with TempDirectory, OutputDirectory, ChangelogPath for cleanup.
    .OUTPUTS
        $true if process completed, $false if interrupted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process]$Process,

        [Parameter()]
        [hashtable]$CleanupPaths
    )

    try {
        # Poll every 500ms so we can respond to Ctrl+C
        while (-not $Process.HasExited) {
            $Process.WaitForExit(500)
        }
        return $true
    }
    catch [System.Management.Automation.PipelineStoppedException] {
        # Ctrl+C was pressed
        Set-BuildCancelled
        
        if ($CleanupPaths) {
            Invoke-CancellationCleanup @CleanupPaths
        }
        else {
            Stop-AllChildProcesses
        }
        
        throw
    }
}

# ============================================================================
# GitHub API Functions
# ============================================================================

function Invoke-GitHubApi {
    <#
    .SYNOPSIS
        Makes a request to the GitHub REST API with caching and error handling.
    
    .DESCRIPTION
        Central function for all GitHub API interactions. Provides:
        
        FEATURES:
        - Response caching: Identical requests return cached results
        - Configurable timeout: Uses ApiTimeoutSeconds from config
        - Proper headers: Sets User-Agent and Accept headers for GitHub API v3
        - Error handling: Catches exceptions and returns $null on failure
        - Verbose logging: Logs requests and cache hits when in Verbose mode
        
        CACHING BEHAVIOR:
        The function maintains a script-scoped cache ($script:ApiCache) that
        stores successful responses keyed by URI. This prevents duplicate
        requests when the same endpoint is called multiple times (e.g., when
        building both 64-bit and 32-bit architectures).
        
        The cache persists for the duration of the script execution and is
        not persisted to disk.
    
    .PARAMETER Uri
        The full GitHub API endpoint URL.
        Examples:
        - https://api.github.com/repos/owner/repo/releases
        - https://api.github.com/repos/owner/repo/tags
    
    .OUTPUTS
        [PSCustomObject] The deserialized JSON response from the API.
        [null] If the request fails or times out.
    
    .EXAMPLE
        # Get all releases for a repository
        $releases = Invoke-GitHubApi 'https://api.github.com/repos/brechtsanders/winlibs_mingw/releases'
    
    .EXAMPLE
        # Get all tags for a repository
        $tags = Invoke-GitHubApi "$($cfg.GitHubApiBase)/repos/$Owner/$Repo/tags"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    # Return cached response if available
    if ($script:ApiCache.ContainsKey($Uri)) {
        Write-VerboseLog "API cache hit: $Uri"
        return $script:ApiCache[$Uri]
    }

    $cfg = Get-BuildConfig

    try {
        $headers = @{
            'User-Agent' = $cfg.GitHubUserAgent
            'Accept'     = 'application/vnd.github.v3+json'
        }

        Write-VerboseLog "API request: $Uri"
        $result = Invoke-RestMethod -Uri $Uri -Headers $headers -TimeoutSec $cfg.ApiTimeoutSeconds

        # Cache successful responses
        $script:ApiCache[$Uri] = $result
        return $result
    }
    catch {
        Write-WarningMessage -Type 'API Error' -Message "Failed: $Uri"
        Write-VerboseLog "API error details: $($_.Exception.Message)"
        return $null
    }
}

function Get-LatestGitHubTag {
    <#
    .SYNOPSIS
        Gets the most recent tag from a GitHub repository.
    
    .DESCRIPTION
        Fetches the tags list from a GitHub repository and returns the
        name of the most recent tag. This is used to:
        
        1. Get the current project version for -CheckNewRelease comparison
        2. Determine the previous version for changelog generation
        
        BEHAVIOR:
        - Calls the GitHub API: /repos/{owner}/{repo}/tags
        - Returns the first tag in the list (most recent by default)
        - Uses API caching from Invoke-GitHubApi
        - Returns $null if no tags exist or API fails
    
    .PARAMETER Owner
        The GitHub username or organization that owns the repository.
        Example: 'ehsan18t'
    
    .PARAMETER Repo
        The repository name.
        Example: 'easy-mingw-installer'
    
    .OUTPUTS
        [string] The tag name (e.g., '2024.01.15').
        [null] If no tags found or API error.
    
    .EXAMPLE
        # Check if we need to build
        $currentTag = Get-LatestGitHubTag -Owner 'ehsan18t' -Repo 'easy-mingw-installer'
        if ($currentTag -eq $newVersion) {
            Write-Host "Already up to date"
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,

        [Parameter(Mandatory)]
        [string]$Repo
    )

    $cfg = Get-BuildConfig
    $uri = "$($cfg.GitHubApiBase)/repos/$Owner/$Repo/tags"
    $tags = Invoke-GitHubApi $uri

    if ($tags -and $tags.Count -gt 0) {
        $latestTag = $tags[0].name
        Write-VerboseLog "Latest tag for $Owner/$Repo : $latestTag"
        return $latestTag
    }

    return $null
}

function Get-GitHubTags {
    <#
    .SYNOPSIS
        Gets multiple recent tags from a GitHub repository.
    
    .DESCRIPTION
        Fetches the tags list from a GitHub repository and returns
        the specified number of most recent tags. Primarily used for
        changelog generation where we need both current and previous tags.
        
        USE CASE:
        When generating a changelog in test mode with -GenerateChangelog,
        we need to know:
        - Current tag: The version we're "building"
        - Previous tag: The last released version for comparison
        
        This function returns both in a single API call.
    
    .PARAMETER Owner
        The GitHub username or organization that owns the repository.
        Example: 'ehsan18t'
    
    .PARAMETER Repo
        The repository name.
        Example: 'easy-mingw-installer'
    
    .PARAMETER Count
        Number of tags to return. Default is 2 (current + previous).
    
    .OUTPUTS
        [string[]] Array of tag names, newest first.
        Example: @('2024.01.15', '2024.01.01')
    
    .EXAMPLE
        # Get current and previous tags for changelog
        $tags = Get-GitHubTags -Owner 'ehsan18t' -Repo 'easy-mingw-installer' -Count 2
        $currentTag = $tags[0]   # '2024.01.15'
        $previousTag = $tags[1]  # '2024.01.01'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,

        [Parameter(Mandatory)]
        [string]$Repo,

        [Parameter()]
        [int]$Count = 2
    )

    $cfg = Get-BuildConfig
    $uri = "$($cfg.GitHubApiBase)/repos/$Owner/$Repo/tags"
    $tags = Invoke-GitHubApi $uri

    if ($tags -and $tags.Count -gt 0) {
        $result = $tags | Select-Object -First $Count | ForEach-Object { $_.name }
        Write-VerboseLog "Tags for $Owner/$Repo : $($result -join ', ')"
        return $result
    }

    return @()
}

function Find-GitHubRelease {
    <#
    .SYNOPSIS
        Finds a GitHub release matching a title pattern.
    
    .DESCRIPTION
        Searches through a repository's releases to find one matching
        the specified wildcard pattern. This is used to find the correct
        WinLibs release based on configuration (UCRT/MSVCRT, POSIX/Win32, etc.).
        
        SEARCH BEHAVIOR:
        1. Fetches all releases from the repository via GitHub API
        2. Filters releases by title using the wildcard pattern
        3. Excludes pre-release versions (draft or beta releases)
        4. Sorts matches by published_at date (newest first)
        5. Returns the most recent matching release
        
        RELEASE OBJECT STRUCTURE (returned):
        The returned object contains these key properties:
        - name          : Release title (e.g., "GCC 14.2.0 POSIX threads...")
        - tag_name      : Git tag for the release
        - published_at  : ISO 8601 timestamp of publication
        - prerelease    : Boolean, true if pre-release
        - assets        : Array of downloadable files with:
            - name                 : Filename (e.g., "winlibs-x86_64-posix-seh-gcc-14.2.0-...7z")
            - browser_download_url : Direct download URL
            - size                 : File size in bytes
    
    .PARAMETER Owner
        The GitHub username or organization that owns the repository.
        Default for WinLibs: 'brechtsanders'
    
    .PARAMETER Repo
        The repository name.
        Default for WinLibs: 'winlibs_mingw'
    
    .PARAMETER TitlePattern
        Wildcard pattern to match against release titles.
        Uses PowerShell's -like operator (* and ? wildcards).
        
        Common patterns:
        - '*UCRT*POSIX*'     : UCRT runtime with POSIX threads
        - '*MSVCRT*Win32*'   : MSVCRT runtime with Win32 threads
        - '*GCC 14*UCRT*'    : Specific GCC version
    
    .OUTPUTS
        [PSCustomObject] The matching release object with assets.
        [null] If no matching release is found.
    
    .EXAMPLE
        # Find latest UCRT POSIX release
        $release = Find-GitHubRelease -Owner 'brechtsanders' -Repo 'winlibs_mingw' -TitlePattern '*UCRT*POSIX*'
        Write-Host "Found: $($release.name)"
        Write-Host "Published: $($release.published_at)"
    
    .EXAMPLE
        # Find release and access download asset
        $release = Find-GitHubRelease -Owner 'brechtsanders' -Repo 'winlibs_mingw' -TitlePattern '*UCRT*POSIX*'
        $asset = $release.assets | Where-Object { $_.name -match '.*x86_64.*\.7z$' } | Select-Object -First 1
        Write-Host "Download: $($asset.browser_download_url)"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,

        [Parameter(Mandatory)]
        [string]$Repo,

        [Parameter(Mandatory)]
        [string]$TitlePattern
    )

    $cfg = Get-BuildConfig
    $uri = "$($cfg.GitHubApiBase)/repos/$Owner/$Repo/releases"
    $releases = Invoke-GitHubApi $uri

    if (-not $releases) {
        return $null
    }

    # Filter by pattern, exclude prereleases, sort by date
    $match = $releases |
        Where-Object { $_.name -like $TitlePattern -and -not $_.prerelease } |
        Sort-Object { [datetime]$_.published_at } -Descending |
        Select-Object -First 1

    if ($match) {
        Write-StatusInfo -Type 'Release Found' -Message $match.name
    }

    return $match
}

# ============================================================================
# Download & Extraction Functions
# ============================================================================

function Invoke-FileDownload {
    <#
    .SYNOPSIS
        Downloads a file from URL with retry logic and real-time progress display.
    
    .DESCRIPTION
        Downloads a file from the specified URL to the local filesystem with:
        
        FEATURES:
        - Automatic retry on failure (configurable via DownloadRetries)
        - Real-time progress display with percentage and KB transferred
        - Automatic cleanup of partial downloads on failure
        - Different behavior for GitHub Actions vs local terminal
        - Configurable timeouts and buffer sizes via config
        
        PROGRESS DISPLAY:
        In local terminal mode, shows updating progress line:
          Progress (Attempt 1): 15360KB / 150000KB (10%)
        
        In GitHub Actions, uses simple Invoke-WebRequest without progress
        to avoid log pollution.
        
        RETRY BEHAVIOR:
        1. Attempts download up to DownloadRetries times (default: 3)
        2. On failure, removes any partial file
        3. Waits DownloadRetryDelaySeconds between attempts (default: 10)
        4. Logs each attempt and failure reason
        
        IMPLEMENTATION DETAILS:
        Uses System.Net.HttpWebRequest for progress tracking with a
        configurable buffer size (DownloadBufferSize, default: 80KB).
        Progress updates every 100ms to prevent console flicker.
    
    .PARAMETER Url
        The URL to download from. Typically a GitHub release asset URL.
        Example: https://github.com/.../releases/download/.../file.7z
    
    .PARAMETER Destination
        The local file path to save the downloaded file to.
        Parent directory will be created if it doesn't exist.
    
    .OUTPUTS
        [bool] $true if download succeeded, $false if all retries failed.
    
    .EXAMPLE
        # Download a file with automatic retry
        $success = Invoke-FileDownload `
            -Url 'https://github.com/.../mingw.7z' `
            -Destination 'C:\Temp\mingw.7z'
        
        if (-not $success) {
            Write-Error "Download failed"
        }
    
    .EXAMPLE
        # Used in the build pipeline
        if (-not (Invoke-FileDownload -Url $asset.browser_download_url -Destination $archiveFile)) {
            return $false
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $cfg = Get-BuildConfig
    $fileName = Split-Path $Url -Leaf
    Write-StatusInfo -Type 'Downloading' -Message $fileName

    # Ensure destination directory exists
    $destDir = Split-Path $Destination -Parent
    if ($destDir -and -not (Test-Path $destDir)) {
        New-Item $destDir -ItemType Directory -Force | Out-Null
    }

    # Retry loop
    for ($attempt = 1; $attempt -le $cfg.DownloadRetries; $attempt++) {
        try {
            # Use HttpWebRequest for progress tracking in console, Invoke-WebRequest in GitHub Actions
            if ($cfg.IsGitHubActions) {
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
            }
            else {
                # HttpWebRequest with progress display
                $webRequest = [System.Net.HttpWebRequest]::Create($Url)
                $webRequest.UserAgent = $cfg.GitHubUserAgent
                $webRequest.Timeout = $cfg.ApiTimeoutSeconds * 1000
                
                $response = $webRequest.GetResponse()
                $totalLength = $response.ContentLength
                $totalLengthKB = [math]::Round($totalLength / 1KB, 0)
                
                $responseStream = $response.GetResponseStream()
                $fileStream = [System.IO.FileStream]::new($Destination, [System.IO.FileMode]::Create)
                
                $buffer = New-Object byte[] $cfg.DownloadBufferSize
                $downloadedBytes = 0
                $lastProgressUpdate = [DateTime]::MinValue
                
                try {
                    while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $fileStream.Write($buffer, 0, $bytesRead)
                        $downloadedBytes += $bytesRead
                        
                        # Update progress every 100ms to avoid console flicker
                        $now = [DateTime]::Now
                        if (($now - $lastProgressUpdate).TotalMilliseconds -ge 100) {
                            $downloadedKB = [math]::Round($downloadedBytes / 1KB, 0)
                            $percentage = if ($totalLength -gt 0) { [math]::Round(($downloadedBytes / $totalLength) * 100, 0) } else { 0 }
                            Write-UpdatingLine -Text "  Progress (Attempt $attempt): ${downloadedKB}KB / ${totalLengthKB}KB ($percentage%)"
                            $lastProgressUpdate = $now
                        }
                    }
                }
                finally {
                    $fileStream.Close()
                    $responseStream.Close()
                    $response.Close()
                }
                
                End-UpdatingLine
            }

            if (Test-Path $Destination) {
                $fileSize = (Get-Item $Destination).Length
                $sizeDisplay = Format-FileSize $fileSize
                Write-SuccessMessage -Type 'Downloaded' -Message "$fileName ($sizeDisplay)"
                return $true
            }
        }
        catch {
            # Clean up partial download
            if (Test-Path $Destination) {
                Remove-Item $Destination -Force -ErrorAction SilentlyContinue
            }
            
            Write-WarningMessage -Type "Attempt $attempt" -Message $_.Exception.Message

            if ($attempt -lt $cfg.DownloadRetries) {
                Write-VerboseLog "Retrying in $($cfg.DownloadRetryDelaySeconds) seconds..."
                Start-Sleep -Seconds $cfg.DownloadRetryDelaySeconds
            }
        }
    }

    Write-ErrorMessage -ErrorType 'Download Failed' -Message "Failed after $($cfg.DownloadRetries) attempts: $fileName"
    return $false
}

function Expand-7ZipArchive {
    <#
    .SYNOPSIS
        Extracts an archive using 7-Zip command-line tool.
    
    .DESCRIPTION
        Extracts any archive format supported by 7-Zip to a specified directory.
        This function wraps 7-Zip (7z.exe) with proper process management.
        
        SUPPORTED FORMATS:
        7-Zip can extract many formats including: 7z, ZIP, GZIP, BZIP2, TAR,
        RAR, CAB, ISO, WIM, and more. WinLibs uses .7z for distribution.
        
        PROCESS MANAGEMENT:
        - Runs 7-Zip as a child process with redirected output
        - Registers the process for cancellation support (Ctrl+C cleanup)
        - Polls for exit every 500ms to allow interrupt handling
        - Suppresses verbose 7-Zip output (redirected to null)
        
        COMMAND EXECUTED:
        7z.exe x "<archive>" -o"<destination>" -y
        
        Where:
        - x     = Extract with full paths
        - -o    = Output directory
        - -y    = Yes to all prompts (overwrite)
    
    .PARAMETER ArchivePath
        Full path to the archive file to extract.
        Example: C:\Temp\mingw-ucrt-posix-seh.7z
    
    .PARAMETER DestinationPath
        Directory to extract the archive contents to.
        Will contain the extracted folder (e.g., mingw64/).
    
    .OUTPUTS
        [bool] $true if extraction succeeded (exit code 0), $false otherwise.
    
    .EXAMPLE
        $success = Expand-7ZipArchive `
            -ArchivePath 'C:\Downloads\mingw.7z' `
            -DestinationPath 'C:\Temp\extracted'
        
        # After extraction, C:\Temp\extracted\mingw64\ contains the files
    
    .NOTES
        Requires 7-Zip to be installed. Path is obtained from Get-BuildConfig.
        Exit codes: 0=Success, 1=Warning, 2=Fatal error, 7=Command line error
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ArchivePath,

        [Parameter(Mandatory)]
        [string]$DestinationPath
    )

    $cfg = Get-BuildConfig
    $archiveName = Split-Path $ArchivePath -Leaf

    Write-StatusInfo -Type 'Extracting' -Message $archiveName

    # Run 7-Zip with output redirected (suppress verbose logging)
    $arguments = "x `"$ArchivePath`" -o`"$DestinationPath`" -y"
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $cfg.SevenZipPath
    $processInfo.Arguments = $arguments
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $process.Start() | Out-Null
    Register-ChildProcess -Process $process
    
    # Poll for exit to allow Ctrl+C handling
    while (-not $process.HasExited) {
        $process.WaitForExit(500)
    }

    if ($process.ExitCode -eq 0) {
        Write-SuccessMessage -Type 'Extracted' -Message "to $DestinationPath"
        return $true
    }

    $errorOutput = $process.StandardError.ReadToEnd()
    Write-ErrorMessage -ErrorType 'Extraction Failed' -Message "7-Zip exit code: $($process.ExitCode)"
    if ($errorOutput) {
        Write-VerboseLog "7-Zip error: $errorOutput"
    }
    return $false
}

function Format-FileSize {
    <#
    .SYNOPSIS
        Formats a file size in bytes to a human-readable string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long]$Bytes
    )

    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes bytes"
}

# ============================================================================
# Test Mode Functions
# ============================================================================

function New-TestFixtures {
    <#
    .SYNOPSIS
        Creates mock MinGW directory structure for test mode builds.
    
    .DESCRIPTION
        Generates a minimal directory structure that mimics a real MinGW
        installation, allowing the build pipeline to be tested without
        downloading the actual ~500MB MinGW archive.
        
        CREATED STRUCTURE:
        <Path>/
        ├── bin/
        │   └── gcc.exe         (1KB dummy file)
        └── version_info.txt    (mock version information)
        
        The version_info.txt contains:
        - Mock GCC and GDB version entries
        - Thread model: POSIX
        - Runtime library: UCRT (Test Mode)
        - Package date from the Date parameter
        
        USE CASES:
        1. Testing the build pipeline without network access
        2. Rapid iteration during development
        3. CI/CD pipeline testing with -TestMode flag
        4. Validating Inno Setup script changes
    
    .PARAMETER Path
        The directory path where test fixtures will be created.
        Will be created if it doesn't exist.
        Example: 'C:\Temp\EasyMinGW_Build\mingw64\mingw64'
    
    .PARAMETER Architecture
        The target architecture ('32' or '64').
        Used in log messages for clarity.
    
    .PARAMETER Date
        The date string to include in version_info.txt.
        Example: '2024-01-15'
    
    .EXAMPLE
        New-TestFixtures -Path 'C:\Temp\mingw64' -Architecture '64' -Date '2024-01-15'
        # Creates test fixtures at C:\Temp\mingw64
    
    .NOTES
        The dummy gcc.exe is created using [IO.File]::WriteAllBytes for
        PowerShell 5.1 compatibility (Set-Content with -AsByteStream
        requires PS 6+).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Architecture,

        [Parameter(Mandatory)]
        [string]$Date
    )

    Write-StatusInfo -Type 'Test Mode' -Message "Creating fixtures for $Architecture-bit"

    # Create directory structure
    if (-not (Test-Path $Path)) {
        New-Item $Path -ItemType Directory -Force | Out-Null
    }

    $binDir = Join-Path $Path 'bin'
    if (-not (Test-Path $binDir)) {
        New-Item $binDir -ItemType Directory -Force | Out-Null
    }

    # Create version info file
    $versionContent = @"
winlibs personal build version gcc-TEST-mingw-w64ucrt-TEST
- GCC TEST.0
- GDB TEST.0
Thread model: POSIX
Runtime library: UCRT (Test Mode)
Packaged on $Date
"@
    $versionPath = Join-Path $Path 'version_info.txt'
    Set-Content -Path $versionPath -Value $versionContent -Encoding UTF8

    # Create dummy executable (1KB) - use WriteAllBytes for PS5.1 compatibility
    $dummyExe = Join-Path $binDir 'gcc.exe'
    [byte[]]$dummyBytes = [byte[]]::new(1024)
    [IO.File]::WriteAllBytes($dummyExe, $dummyBytes)

    Write-SuccessMessage -Type 'Fixtures' -Message "Created at $Path"
}

# ============================================================================
# Changelog Functions
# ============================================================================

function New-FallbackChangelog {
    <#
    .SYNOPSIS
        Creates a fallback changelog when the Python generator isn't available.
    .PARAMETER OutputPath
        Path to write the changelog file.
    .PARAMETER Version
        The release version.
    .PARAMETER VersionInfoPath
        Optional path to version_info.txt for package info.
    .PARAMETER PreviousTag
        Optional previous release tag for changelog link.
    .PARAMETER GitHubOwner
        GitHub repository owner.
    .PARAMETER GitHubRepo
        GitHub repository name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter()]
        [string]$VersionInfoPath,

        [Parameter()]
        [string]$PreviousTag,

        [Parameter()]
        [string]$GitHubOwner = 'ehsan18t',

        [Parameter()]
        [string]$GitHubRepo = 'easy-mingw-installer'
    )

    Write-WarningMessage -Type 'Changelog' -Message 'Using fallback template'

    $changelogLines = @()

    # Parse version_info.txt to extract all info (matching Python script behavior)
    if ($VersionInfoPath -and (Test-Path $VersionInfoPath)) {
        $fileContent = Get-Content $VersionInfoPath -Raw
        $lines = Get-Content $VersionInfoPath

        $inPackageList = $false
        $packageLines = @()
        $threadModel = ''
        $runtimeLibrary = ''
        $buildLine = ''

        foreach ($line in $lines) {
            $lineStrip = $line.Trim()

            # Start of package list
            if (-not $inPackageList -and $line -match 'This is the winlibs Intel/AMD' -and $line -match 'build of:') {
                $inPackageList = $true
                continue
            }

            if ($inPackageList) {
                if ($lineStrip -match '^- ') {
                    $packageLines += $lineStrip
                }
                elseif ($lineStrip -match '^Thread model:' -or
                        $lineStrip -match '^Runtime library:' -or
                        ($line -match 'This build was compiled with GCC' -and $line -match 'and packaged on')) {
                    $inPackageList = $false
                }
            }

            # Extract thread model
            if ($lineStrip -match '^Thread model:\s*(.+)$') {
                $threadModel = $Matches[1].Trim()
                if ($threadModel.ToLower() -eq 'posix') { $threadModel = 'POSIX' }
            }

            # Extract runtime library
            if ($lineStrip -match '^Runtime library:\s*(.+)$') {
                $runtimeLibrary = $Matches[1].Trim()
            }

            # Extract build line (with quirky dot handling matching old Python script)
            if ($line -match 'This build was compiled with GCC' -and $line -match 'and packaged on') {
                if ($lineStrip.EndsWith('.')) {
                    # Remove FIRST dot only if line ends with dot (legacy quirky behavior)
                    $buildLine = $lineStrip -replace '\.', '', 1
                } else {
                    $buildLine = $lineStrip
                }
            }
        }

        # Build Package Info section
        $changelogLines += '## Package Info'
        $changelogLines += 'This is the winlibs Intel/AMD 64-bit & 32-bit standalone build of:'
        $changelogLines += $packageLines
        $changelogLines += ''

        if ($threadModel) {
            $changelogLines += "<strong>Thread model:</strong> $threadModel"
            $changelogLines += ''
            $changelogLines += '<br>'
            $changelogLines += ''
        }

        if ($runtimeLibrary) {
            $changelogLines += "<strong>Runtime library:</strong> $runtimeLibrary<br>"
            $changelogLines += ''
        }

        if ($buildLine) {
            $changelogLines += "> $buildLine"
            $changelogLines += ''
        }
    }

    # Script/Installer Changelogs section
    $changelogLines += '## Script/Installer Changelogs'
    $changelogLines += '* None'
    $changelogLines += ''

    # Package Changelogs section
    $changelogLines += '## Package Changelogs'
    $changelogLines += "* Could not retrieve or parse previous version's package list; all current packages are listed as new if any."
    $changelogLines += ''

    # Full Changelog link
    $changelogLines += '<br>'
    $changelogLines += ''
    if ($PreviousTag -and $Version) {
        $changelogLines += "**Full Changelog**: https://github.com/$GitHubOwner/$GitHubRepo/compare/$PreviousTag...$Version"
    } else {
        $changelogLines += '**Full Changelog**: [TODO: Update link - Previous project tag missing]'
    }
    $changelogLines += ''
    $changelogLines += '<br>'
    $changelogLines += ''
    $changelogLines += '### File Hash'

    $changelogContent = $changelogLines -join "`n"
    Set-Content -Path $OutputPath -Value $changelogContent -Encoding UTF8 -NoNewline
    return $true
}

function Invoke-ChangelogGeneration {
    <#
    .SYNOPSIS
        Generates a Markdown changelog by comparing package versions.
    
    .DESCRIPTION
        Runs the Python changelog generator script (generate_changelog.py) to
        create a formatted changelog for GitHub releases. The script compares
        packages between the current and previous releases.
        
        CHANGELOG STRUCTURE:
        The generated changelog includes:
        1. Package Info section (from version_info.txt)
        2. Script/Installer Changelogs (manual entries)
        3. Package Changelogs (automated diff):
           - New packages added
           - Updated packages (version changes)
           - Removed packages
        4. Full Changelog link (GitHub compare URL)
        5. File Hash section header (hashes appended later)
        
        DATA SOURCES:
        The function can obtain current package info from:
        1. Local version_info.txt (normal build mode)
        2. GitHub release tag (test mode with -GenerateChangelog)
        
        Previous package info is always fetched from the previous GitHub
        release tag to enable version comparison.
        
        PYTHON SCRIPT ARGUMENTS:
        --output-file       : Path to write the changelog
        --current-build-tag : Version string for the current build
        --github-owner      : Repository owner (from config)
        --github-repo       : Repository name (from config)
        --prev-tag          : Previous release tag for comparison
        --input-file        : Local version_info.txt path (OR)
        --current-tag       : GitHub tag to fetch current info from
    
    .PARAMETER VersionInfoPath
        Path to the local version_info.txt file extracted from MinGW archive.
        Required unless CurrentTag is provided.
    
    .PARAMETER OutputPath
        Path where the changelog markdown file will be written.
        Example: './release_notes_body.md'
    
    .PARAMETER Version
        The current version string for changelog header and links.
        Example: '2024.01.15'
    
    .PARAMETER PreviousTag
        Git tag of the previous release for comparison.
        Used to generate diff and comparison link.
        Example: '2024.01.01'
    
    .PARAMETER CurrentTag
        If provided, fetches current package info from this GitHub release
        instead of using the local version_info.txt file.
        Used in test mode with -GenerateChangelog flag.
    
    .OUTPUTS
        [bool] $true if changelog was generated successfully, $false otherwise.
    
    .EXAMPLE
        # Generate changelog from local file
        Invoke-ChangelogGeneration `
            -VersionInfoPath 'C:\Temp\version_info.txt' `
            -OutputPath './release_notes.md' `
            -Version '2024.01.15' `
            -PreviousTag '2024.01.01'
    
    .EXAMPLE
        # Generate changelog from GitHub (test mode)
        Invoke-ChangelogGeneration `
            -OutputPath './release_notes.md' `
            -Version '2024.01.15' `
            -PreviousTag '2024.01.01' `
            -CurrentTag '2024.01.15'
    
    .NOTES
        Requires Python 3.8+ with the 'requests' package installed.
        Falls back to New-FallbackChangelog if Python is unavailable.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$VersionInfoPath,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter()]
        [string]$PreviousTag,

        [Parameter()]
        [string]$CurrentTag
    )

    # Skip if already exists
    if (Test-Path $OutputPath) {
        Write-StatusInfo -Type 'Changelog' -Message 'Already exists, skipping'
        return $true
    }

    # Require version info or CurrentTag
    if (-not $CurrentTag -and -not (Test-Path $VersionInfoPath)) {
        Write-ErrorMessage -ErrorType 'Changelog' -Message "Version info file not found: $VersionInfoPath"
        return $false
    }

    # Require Python script
    $pyScript = Join-Path $PSScriptRoot 'generate_changelog.py'
    if (-not (Test-Path $pyScript)) {
        Write-ErrorMessage -ErrorType 'Changelog' -Message "Python script not found: $pyScript"
        return $false
    }

    # Check if Python is available
    $null = & python --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorMessage -ErrorType 'Changelog' -Message 'Python is not available'
        return $false
    }

    $cfg = Get-BuildConfig

    $pyArgs = @(
        $pyScript
        '--output-file', $OutputPath
        '--current-build-tag', $Version
        '--github-owner', $cfg.ProjectOwner
        '--github-repo', $cfg.ProjectRepo
    )
    
    # Only add prev-tag if we have a valid one (not empty/null)
    if ($PreviousTag) {
        $pyArgs += '--prev-tag', $PreviousTag
    }

    # Use CurrentTag to fetch from GitHub, otherwise use local file
    if ($CurrentTag) {
        $pyArgs += '--current-tag', $CurrentTag
        Write-VerboseLog "Fetching current package info from GitHub tag: $CurrentTag"
    }
    else {
        $pyArgs += '--input-file', $VersionInfoPath
    }

    # Start Python process with tracking for cancellation
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = 'python'
    $processInfo.Arguments = ($pyArgs | ForEach-Object { 
        if ($_ -match '\s') { "`"$_`"" } else { $_ } 
    }) -join ' '
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $process.Start() | Out-Null
    Register-ChildProcess -Process $process
    
    # Poll for exit to allow Ctrl+C handling
    while (-not $process.HasExited) {
        $process.WaitForExit(500)
    }

    if ($process.ExitCode -eq 0 -and (Test-Path $OutputPath)) {
        Write-SuccessMessage -Type 'Changelog' -Message 'Generated successfully'
        return $true
    }

    # Python failed - report error and fail
    $stderr = $process.StandardError.ReadToEnd()
    Write-ErrorMessage -ErrorType 'Changelog' -Message "Python script failed with exit code $($process.ExitCode)"
    if ($stderr) {
        Write-VerboseLog "Python stderr: $stderr"
    }
    return $false
}

# ============================================================================
# Build Functions
# ============================================================================

function Invoke-InstallerBuild {
    <#
    .SYNOPSIS
        Builds a Windows installer using Inno Setup Compiler (ISCC.exe).
    
    .DESCRIPTION
        Compiles the Inno Setup script (MinGW_Installer.iss) into a Windows
        installer executable. This is the core build step that produces the
        final distributable .exe file.
        
        BUILD PROCESS:
        1. Ensures output directory exists
        2. Constructs ISCC.exe command line with define overrides
        3. Runs ISCC.exe as a child process with cancellation support
        4. Captures stdout/stderr for logging
        5. Writes build log on error or if GenerateLogsAlways is set
        6. Generates file hashes for the built installer (unless SkipHashes)
        
        INNO SETUP ARGUMENTS:
        The function passes these /D defines to ISCC.exe:
        - /DMyAppName="<Name>"           : Display name in installer
        - /DMyOutputName="<OutputName>"  : Base output filename
        - /DMyAppVersion="<Version>"     : Version string
        - /DArch="<Architecture>"        : "32" or "64"
        - /DSourcePath="<SourcePath>"    : Path to MinGW files
        - /DOutputPath="<OutputDir>"     : Output directory for .exe
        
        OUTPUT FILE NAMING:
        The built installer is named:
        <OutputName>.v<Version>.<Architecture>-bit.exe
        
        Example: EasyMinGW.Installer.v2024.01.15.64-bit.exe
    
    .PARAMETER Name
        The display name shown in the installer UI.
        Example: 'EasyMinGW Installer'
    
    .PARAMETER OutputName
        The base filename for the output (without extension).
        Example: 'EasyMinGW.Installer'
    
    .PARAMETER Version
        The version string, typically derived from release date.
        Example: '2024.01.15'
    
    .PARAMETER Architecture
        The target architecture: '32' or '64'.
        Affects both the installer name and the installation path.
    
    .PARAMETER SourcePath
        Path to the extracted MinGW directory containing bin/, lib/, etc.
        Example: 'C:\Temp\EasyMinGW_Build\mingw64\mingw64'
    
    .PARAMETER OutputDirectory
        Directory where the built .exe and .hashes.txt will be placed.
        Example: '.\output'
    
    .PARAMETER IssPath
        Full path to the Inno Setup script (.iss file).
        Example: 'C:\Project\MinGW_Installer.iss'
    
    .OUTPUTS
        [bool] $true if build succeeded, $false on failure.
    
    .EXAMPLE
        $success = Invoke-InstallerBuild `
            -Name 'EasyMinGW Installer' `
            -OutputName 'EasyMinGW.Installer' `
            -Version '2024.01.15' `
            -Architecture '64' `
            -SourcePath 'C:\Temp\mingw64' `
            -OutputDirectory '.\output' `
            -IssPath '.\MinGW_Installer.iss'
    
    .NOTES
        Requires Inno Setup 5 or 6 to be installed.
        ISCC.exe path is obtained from Get-BuildConfig.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$OutputName,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$Architecture,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [Parameter(Mandatory)]
        [string]$IssPath
    )

    $cfg = Get-BuildConfig

    Write-StatusInfo -Type 'Building' -Message "$Name v$Version ($Architecture-bit)"

    # Ensure output directory exists
    if (-not (Test-Path $OutputDirectory)) {
        New-Item $OutputDirectory -ItemType Directory -Force | Out-Null
    }

    # Build Inno Setup arguments
    $arguments = @(
        "/DMyAppName=`"$Name`""
        "/DMyOutputName=`"$OutputName`""
        "/DMyAppVersion=`"$Version`""
        "/DArch=`"$Architecture`""
        "/DSourcePath=`"$SourcePath`""
        "/DOutputPath=`"$OutputDirectory`""
        "`"$IssPath`""
    ) -join ' '

    # Run Inno Setup with output redirected (suppress verbose logging)
    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $cfg.InnoSetupPath
    $processInfo.Arguments = $arguments
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $process.Start() | Out-Null
    Register-ChildProcess -Process $process
    
    # Read output asynchronously to prevent deadlock
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    
    # Poll for exit to allow Ctrl+C handling
    while (-not $process.HasExited) {
        $process.WaitForExit(500)
    }

    $standardOutput = $stdout.Result
    $errorOutput = $stderr.Result

    # Determine if we should write log file
    $shouldWriteLog = $cfg.GenerateLogsAlways -or ($process.ExitCode -ne 0)
    
    if ($shouldWriteLog) {
        $logFileName = "build_${OutputName}_${Architecture}.log"
        $logPath = Join-Path $OutputDirectory $logFileName
        
        $logContent = @"
================================================================================
Inno Setup Build Log
================================================================================
Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Exit Code: $($process.ExitCode)
Name: $Name
Version: $Version
Architecture: $Architecture-bit
Source: $SourcePath
Output: $OutputDirectory
================================================================================

=== Standard Output ===
$standardOutput

=== Standard Error ===
$errorOutput
"@
        $logContent | Out-File -FilePath $logPath -Encoding UTF8
        Write-VerboseLog "Build log saved: $logFileName"
    }

    if ($process.ExitCode -eq 0) {
        $outputFile = "$OutputName.v$Version.$Architecture-bit.exe"
        Write-SuccessMessage -Type 'Built' -Message $outputFile

        # Generate hashes for the built installer (unless skipped)
        if (-not $cfg.SkipHashes) {
            $exePath = Join-Path $OutputDirectory $outputFile
            if (Test-Path $exePath) {
                Invoke-HashGeneration -FilePath $exePath -OutputDirectory $OutputDirectory `
                    -BaseName $OutputName -Version $Version -Architecture $Architecture
            }
        }

        return $true
    }

    # Build failed - show error details
    Write-ErrorMessage -ErrorType 'Build Failed' -Message "Inno Setup exit code: $($process.ExitCode)"
    if ($errorOutput) {
        Write-VerboseLog "Inno Setup error: $errorOutput"
    }
    return $false
}

function Invoke-HashGeneration {
    <#
    .SYNOPSIS
        Generates cryptographic hashes for a built installer file.
    
    .DESCRIPTION
        Runs the Format-7ZipHashes.ps1 script to generate multiple
        hash digests for the built installer executable. The hashes
        are saved to a text file alongside the installer.
        
        GENERATED HASHES:
        Uses 7-Zip's hash command to generate:
        - CRC32, CRC64 (fast checksums)
        - SHA256, SHA384, SHA512 (cryptographic)
        - SHA1, MD5 (legacy compatibility)
        - BLAKE2sp (fast, secure)
        - XXH64 (extremely fast)
        - SHA3-256 (latest standard)
        
        OUTPUT FILE:
        The hash file is named:
        <BaseName>.v<Version>.<Architecture>-bit.hashes.txt
        
        Example: EasyMinGW.Installer.v2024.01.15.64-bit.hashes.txt
        
        The hash content is also appended to the changelog for
        inclusion in GitHub release notes.
    
    .PARAMETER FilePath
        Full path to the installer .exe file to hash.
    
    .PARAMETER OutputDirectory
        Directory where the hash file will be written.
    
    .PARAMETER BaseName
        Base name for the hash file (matches installer base name).
    
    .PARAMETER Version
        Version string for file naming.
    
    .PARAMETER Architecture
        Architecture string ('32' or '64') for file naming.
    
    .EXAMPLE
        Invoke-HashGeneration `
            -FilePath 'C:\output\EasyMinGW.exe' `
            -OutputDirectory 'C:\output' `
            -BaseName 'EasyMinGW.Installer' `
            -Version '2024.01.15' `
            -Architecture '64'
    
    .NOTES
        Requires Format-7ZipHashes.ps1 script in the modules directory.
        Uses 7-Zip for hash generation (path from Get-BuildConfig).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [Parameter(Mandatory)]
        [string]$BaseName,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$Architecture
    )

    $cfg = Get-BuildConfig
    $hashScript = Join-Path $PSScriptRoot 'Format-7ZipHashes.ps1'

    if (-not (Test-Path $hashScript)) {
        Write-WarningMessage -Type 'Hashes' -Message 'Hash script not found, skipping'
        return
    }

    try {
        $hashFile = Join-Path $OutputDirectory "$BaseName.v$Version.$Architecture-bit.hashes.txt"

        & $hashScript -FilePath $FilePath -SevenZipExePath $cfg.SevenZipPath |
            Out-File $hashFile -Encoding utf8

        Write-SuccessMessage -Type 'Hashes' -Message (Split-Path $hashFile -Leaf)
    }
    catch {
        Write-WarningMessage -Type 'Hashes' -Message "Generation failed: $($_.Exception.Message)"
    }
}

# ============================================================================
# Main Build Pipeline
# ============================================================================

function Invoke-ArchitectureBuild {
    <#
    .SYNOPSIS
        Builds a complete installer for a single architecture (32 or 64-bit).
    
    .DESCRIPTION
        This is the main orchestration function that handles the complete build
        pipeline for one architecture. It coordinates the following stages:
        
        ┌─────────────────────────────────────────────────────────────────────┐
        │                    ARCHITECTURE BUILD PIPELINE                       │
        ├─────────────────────────────────────────────────────────────────────┤
        │                                                                      │
        │  1. ASSET DISCOVERY                                                  │
        │     ├─ In test mode: Create mock asset reference                     │
        │     └─ Normal mode: Find matching asset in GitHub release            │
        │                                                                      │
        │  2. DIRECTORY SETUP                                                  │
        │     ├─ Create architecture-specific temp directory                   │
        │     └─ Clean any existing files                                      │
        │                                                                      │
        │  3. CONTENT ACQUISITION (unless SkipDownload)                        │
        │     ├─ Test mode: Generate test fixtures with mock content           │
        │     └─ Normal mode:                                                  │
        │         ├─ Download .7z archive from GitHub                          │
        │         ├─ Extract to temp directory using 7-Zip                     │
        │         └─ Locate and copy version_info.txt                          │
        │                                                                      │
        │  4. CHANGELOG GENERATION (unless SkipChangelog)                      │
        │     ├─ Parse version_info.txt for package information                │
        │     ├─ Compare with previous release packages                        │
        │     └─ Generate Markdown changelog                                   │
        │                                                                      │
        │  5. INSTALLER BUILD (unless SkipBuild)                               │
        │     ├─ Run Inno Setup compiler (ISCC.exe)                            │
        │     ├─ Generate .exe installer                                       │
        │     └─ Generate hash files (SHA256, MD5, etc.)                       │
        │                                                                      │
        │  6. CLEANUP                                                          │
        │     └─ Remove temp directory (skipped in test mode)                  │
        │                                                                      │
        └─────────────────────────────────────────────────────────────────────┘
    
    .PARAMETER Architecture
        The architecture to build: "32" or "64".
    
    .PARAMETER AssetPattern
        Regex pattern to match the download asset filename in the release.
        Example: '.*ucrt-runtime.*posix.*without-llvm.*\.7z$'
    
    .PARAMETER Release
        The GitHub release object (from Find-GitHubRelease) containing assets.
    
    .PARAMETER Version
        The version string for the installer (e.g., "2024.01.15").
    
    .PARAMETER Date
        The release date string for display/logging.
    
    .PARAMETER PreviousTag
        The previous release tag for changelog comparison. Optional.
    
    .PARAMETER CurrentTag
        If provided, fetches current package info from this GitHub release
        instead of local version_info.txt. Used in test mode with GenerateChangelog.
    
    .PARAMETER OutputDirectory
        Directory where the built installer and hash files will be placed.
    
    .PARAMETER TempDirectory
        Base temporary directory for downloads and extraction.
    
    .PARAMETER IssPath
        Full path to the Inno Setup script (MinGW_Installer.iss).
    
    .PARAMETER ReleaseNotesPath
        Path where the release notes markdown will be written.
    
    .OUTPUTS
        [bool] $true on success, $false on failure.
    
    .EXAMPLE
        $result = Invoke-ArchitectureBuild `
            -Architecture '64' `
            -AssetPattern '.*ucrt.*posix.*\.7z$' `
            -Release $releaseObject `
            -Version '2024.01.15' `
            -Date '2024-01-15' `
            -OutputDirectory './output' `
            -TempDirectory './temp' `
            -IssPath './MinGW_Installer.iss' `
            -ReleaseNotesPath './release_notes_body.md'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Architecture,

        [Parameter(Mandatory)]
        [string]$AssetPattern,

        [Parameter(Mandatory)]
        [PSCustomObject]$Release,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$Date,

        [Parameter()]
        [string]$PreviousTag,

        [Parameter()]
        [string]$CurrentTag,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [Parameter(Mandatory)]
        [string]$TempDirectory,

        [Parameter(Mandatory)]
        [string]$IssPath,

        [Parameter(Mandatory)]
        [string]$ReleaseNotesPath
    )

    $cfg = Get-BuildConfig

    Write-SeparatorLine -Character '=' -Length 50
    Write-StatusInfo -Type 'Architecture' -Message "$Architecture-bit"

    # Find matching asset
    $asset = $null
    if ($cfg.IsTestMode -and -not $cfg.ValidateAssets) {
        # Pure test mode: use mock asset
        $asset = @{
            name                  = "mingw-test-$Architecture.7z"
            browser_download_url  = 'test://fake.7z'
        }
        Write-StatusInfo -Type 'Asset' -Message "$($asset.name) (test mode)"
    }
    else {
        # Find real asset from release
        $asset = $Release.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
        if (-not $asset) {
            Write-ErrorMessage -ErrorType 'Asset Not Found' -Message "No match for pattern: $AssetPattern"
            return $false
        }
        Write-StatusInfo -Type 'Asset' -Message $asset.name
        
        # If in test mode with ValidateAssets, just validate and continue with test fixtures
        if ($cfg.IsTestMode -and $cfg.ValidateAssets) {
            Write-SuccessMessage -Type 'Validated' -Message "Asset exists: $($asset.name)"
        }
    }

    # Set up working directories
    $archTempDir = Join-Path $TempDirectory "mingw$Architecture"
    $sourcePath = Join-Path $archTempDir "mingw$Architecture"
    $buildInfoPath = Join-Path $archTempDir 'build_info.txt'

    # Clean and create temp directory
    if (Test-Path $archTempDir) {
        Remove-Item $archTempDir -Recurse -Force
    }
    New-Item $archTempDir -ItemType Directory -Force | Out-Null

    try {
        # ========================
        # Download/Extract or Test Fixtures
        # ========================
        if ($cfg.IsTestMode -or $cfg.SkipDownload) {
            # Test mode: create fixtures
            New-TestFixtures -Path $sourcePath -Architecture $Architecture -Date $Date

            $versionInfo = Join-Path $sourcePath 'version_info.txt'
            if (Test-Path $versionInfo) {
                Copy-Item $versionInfo $buildInfoPath
            }
        }
        else {
            # Normal mode: download and extract
            $archiveFile = Join-Path $archTempDir $asset.name

            if (-not (Invoke-FileDownload -Url $asset.browser_download_url -Destination $archiveFile)) {
                return $false
            }

            if (-not (Expand-7ZipArchive -ArchivePath $archiveFile -DestinationPath $archTempDir)) {
                return $false
            }

            # Find the extracted mingw folder
            $extracted = Get-ChildItem $archTempDir -Directory |
                Where-Object { $_.Name -like 'mingw*' } |
                Select-Object -First 1

            if ($extracted) {
                $sourcePath = $extracted.FullName

                # Copy version info for changelog
                $versionInfo = Join-Path $sourcePath 'version_info.txt'
                if (Test-Path $versionInfo) {
                    Copy-Item $versionInfo $buildInfoPath
                }
            }
        }

        # ========================
        # Changelog Generation
        # ========================
        if (-not $cfg.SkipChangelog) {
            $changelogParams = @{
                OutputPath  = $ReleaseNotesPath
                Version     = $Version
                PreviousTag = $PreviousTag
            }
            
            # In test mode with GenerateChangelog, fetch from GitHub instead of local file
            if ($CurrentTag) {
                $changelogParams['CurrentTag'] = $CurrentTag
            }
            else {
                $changelogParams['VersionInfoPath'] = $buildInfoPath
            }
            
            $null = Invoke-ChangelogGeneration @changelogParams
        }

        # ========================
        # Installer Build
        # ========================
        if (-not $cfg.SkipBuild) {
            return Invoke-InstallerBuild `
                -Name $cfg.InstallerName `
                -OutputName $cfg.InstallerBaseName `
                -Version $Version `
                -Architecture $Architecture `
                -SourcePath $sourcePath `
                -OutputDirectory $OutputDirectory `
                -IssPath $IssPath
        }

        return $true
    }
    finally {
        # Cleanup temp directory (skip in test mode for inspection)
        if (-not $cfg.IsTestMode -and (Test-Path $archTempDir)) {
            Write-VerboseLog "Cleaning up: $archTempDir"
            Remove-Item $archTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-HashesToChangelog {
    <#
    .SYNOPSIS
        Appends file hashes to the changelog for each built architecture.
    
    .DESCRIPTION
        After all installers are built, this function appends the hash
        information to the release notes markdown file. This provides
        users with verification hashes in the GitHub release notes.
        
        OUTPUT FORMAT:
        For each architecture, appends a block like:
        
        **64-bit**
        ```text
        Name: EasyMinGW.Installer.v2024.01.15.64-bit.exe
        Size: 123456789 bytes : 117.7 MiB
        CRC32: 4E068660
        SHA256: ABC123...
        ... (more hashes)
        ```
        
        IDEMPOTENCY:
        The function checks if hash blocks already exist (by looking for
        the **<arch>-bit** header) and skips if already present. This
        allows safe re-runs without duplicate content.
        
        HASH FILE NAMING:
        Expects hash files named:
        <InstallerBaseName>.v<Version>.<Architecture>-bit.hashes.txt
        
        Example: EasyMinGW.Installer.v2024.01.15.64-bit.hashes.txt
    
    .PARAMETER ChangelogPath
        Path to the changelog markdown file to append to.
        Example: './release_notes_body.md'
    
    .PARAMETER OutputDirectory
        Directory containing the .hashes.txt files.
        Example: './output'
    
    .PARAMETER Version
        Version string used in hash file naming.
        Example: '2024.01.15'
    
    .PARAMETER Architectures
        Array of architectures that were built.
        Example: @('64', '32')
    
    .EXAMPLE
        Add-HashesToChangelog `
            -ChangelogPath './release_notes_body.md' `
            -OutputDirectory './output' `
            -Version '2024.01.15' `
            -Architectures @('64', '32')
    
    .NOTES
        Called at the end of the build process after all architectures
        have been built and their hash files generated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ChangelogPath,

        [Parameter(Mandatory)]
        [string]$OutputDirectory,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string[]]$Architectures
    )

    if (-not (Test-Path $ChangelogPath)) {
        Write-WarningMessage -Type 'Hash Append' -Message 'Changelog not found, skipping'
        return
    }

    $cfg = Get-BuildConfig
    $content = Get-Content $ChangelogPath -Raw

    foreach ($arch in $Architectures) {
        $hashFileName = "$($cfg.InstallerBaseName).v$Version.$arch-bit.hashes.txt"
        $hashFilePath = Join-Path $OutputDirectory $hashFileName

        if (-not (Test-Path $hashFilePath)) {
            Write-VerboseLog "Hash file not found: $hashFileName"
            continue
        }

        # Check if already appended
        $archHeader = "**$arch-bit**"
        if ($content -match [regex]::Escape($archHeader)) {
            Write-VerboseLog "Hash block already exists for $arch-bit"
            continue
        }

        # Append hash block
        $hashContent = (Get-Content $hashFilePath -Raw).TrimEnd()
        $codeBlockStart = '```text'
        $codeBlockEnd = '```'
        $hashBlock = "`n`n$archHeader`n$codeBlockStart`n$hashContent`n$codeBlockEnd"

        Add-Content -Path $ChangelogPath -Value $hashBlock -Encoding UTF8
        $content = Get-Content $ChangelogPath -Raw

        Write-StatusInfo -Type 'Hash Append' -Message "$arch-bit hashes added to changelog"
    }
}
