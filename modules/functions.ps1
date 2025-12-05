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
        Performs cleanup when build is cancelled - kills processes and removes outputs.
    #>
    [CmdletBinding()]
    param(
        [string]$TempDirectory,
        [string]$OutputDirectory,
        [string]$ChangelogPath
    )

    Write-Host "`n" -NoNewline
    Write-Host "================================================================================" -ForegroundColor Red
    Write-Host " BUILD CANCELLED - Cleaning up..." -ForegroundColor Red
    Write-Host "================================================================================" -ForegroundColor Red

    # Kill child processes
    Write-Host "`n[Processes]" -ForegroundColor Yellow
    if ($script:ChildProcesses.Count -gt 0) {
        Stop-AllChildProcesses
        Write-Host "  All child processes terminated." -ForegroundColor Green
    }
    else {
        Write-Host "  No child processes to stop." -ForegroundColor Gray
    }

    # Clean temp directory
    Write-Host "`n[Temp Directory]" -ForegroundColor Yellow
    if ($TempDirectory -and (Test-Path $TempDirectory)) {
        try {
            Remove-Item $TempDirectory -Recurse -Force -ErrorAction Stop
            Write-Host "  Removed: $TempDirectory" -ForegroundColor Green
        }
        catch {
            Write-Host "  Failed to remove: $TempDirectory" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  Nothing to clean." -ForegroundColor Gray
    }

    # Clean output directory
    Write-Host "`n[Output Directory]" -ForegroundColor Yellow
    if ($OutputDirectory -and (Test-Path $OutputDirectory)) {
        try {
            Remove-Item $OutputDirectory -Recurse -Force -ErrorAction Stop
            Write-Host "  Removed: $OutputDirectory" -ForegroundColor Green
        }
        catch {
            Write-Host "  Failed to remove: $OutputDirectory" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  Nothing to clean." -ForegroundColor Gray
    }

    # Clean changelog
    Write-Host "`n[Changelog]" -ForegroundColor Yellow
    if ($ChangelogPath -and (Test-Path $ChangelogPath)) {
        try {
            Remove-Item $ChangelogPath -Force -ErrorAction Stop
            Write-Host "  Removed: $ChangelogPath" -ForegroundColor Green
        }
        catch {
            Write-Host "  Failed to remove: $ChangelogPath" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  Nothing to clean." -ForegroundColor Gray
    }

    # Clean log files in script root
    Write-Host "`n[Log Files]" -ForegroundColor Yellow
    $scriptRoot = Split-Path $PSScriptRoot -Parent
    $logFiles = Get-ChildItem -Path $scriptRoot -Filter "*.log" -File -ErrorAction SilentlyContinue
    if ($logFiles) {
        foreach ($log in $logFiles) {
            try {
                Remove-Item $log.FullName -Force -ErrorAction Stop
                Write-Host "  Removed: $($log.Name)" -ForegroundColor Green
            }
            catch {
                Write-Host "  Failed to remove: $($log.Name)" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "  Nothing to clean." -ForegroundColor Gray
    }

    Write-Host "`n================================================================================" -ForegroundColor Red
    Write-Host " Cleanup complete. Build was cancelled." -ForegroundColor Red
    Write-Host "================================================================================`n" -ForegroundColor Red
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
        Makes a request to the GitHub API with caching and error handling.
    .PARAMETER Uri
        The full API endpoint URL.
    .OUTPUTS
        The API response object, or $null on failure.
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
        Gets the latest tag from a GitHub repository.
    .PARAMETER Owner
        Repository owner (username or organization).
    .PARAMETER Repo
        Repository name.
    .OUTPUTS
        The tag name string, or $null if not found.
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
        Gets multiple tags from a GitHub repository.
    .PARAMETER Owner
        Repository owner (username or organization).
    .PARAMETER Repo
        Repository name.
    .PARAMETER Count
        Number of tags to return (default: 2).
    .OUTPUTS
        Array of tag name strings.
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
        Searches releases for a match, excluding prereleases,
        and returns the most recently published match.
    .PARAMETER Owner
        Repository owner.
    .PARAMETER Repo
        Repository name.
    .PARAMETER TitlePattern
        Wildcard pattern to match against release titles.
    .OUTPUTS
        The release object, or $null if not found.
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
        Downloads a file with retry logic and detailed progress display.
    .PARAMETER Url
        The URL to download from.
    .PARAMETER Destination
        The local file path to save to.
    .OUTPUTS
        $true on success, $false on failure.
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
        Extracts an archive using 7-Zip.
    .PARAMETER ArchivePath
        Path to the archive file.
    .PARAMETER DestinationPath
        Directory to extract to.
    .OUTPUTS
        $true on success, $false on failure.
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
        Creates test fixtures for test mode builds.
    .DESCRIPTION
        Generates a minimal directory structure with version info
        and a dummy executable to allow testing the build pipeline
        without downloading actual MinGW packages.
    .PARAMETER Path
        The base path where fixtures will be created.
    .PARAMETER Architecture
        The architecture (32 or 64).
    .PARAMETER Date
        The date string for version info.
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
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter()]
        [string]$VersionInfoPath
    )

    Write-WarningMessage -Type 'Changelog' -Message 'Using fallback template'

    # Extract package info if available
    $packageInfo = ''
    if ($VersionInfoPath -and (Test-Path $VersionInfoPath)) {
        $lines = Get-Content $VersionInfoPath | Where-Object { $_ -match '^- ' }
        if ($lines) {
            $packageInfo = "## Package Info`n$($lines -join "`n")`n`n"
        }
    }

    $changelogContent = @"
# Release $Version

$packageInfo## Changelog
* No automated changelog available

### File Hash
"@

    Set-Content -Path $OutputPath -Value $changelogContent -Encoding UTF8
    return $true
}

function Invoke-ChangelogGeneration {
    <#
    .SYNOPSIS
        Generates a changelog using the Python script or fallback.
    .PARAMETER VersionInfoPath
        Path to the version_info.txt file. Optional if CurrentTag is provided.
    .PARAMETER OutputPath
        Path to write the changelog.
    .PARAMETER Version
        The current version.
    .PARAMETER PreviousTag
        The previous release tag for comparison.
    .PARAMETER CurrentTag
        If provided, fetch current package info from this GitHub release tag instead of local file.
    .OUTPUTS
        $true on success, $false on failure.
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

    # Fallback if no version info and no CurrentTag
    if (-not $CurrentTag -and -not (Test-Path $VersionInfoPath)) {
        return New-FallbackChangelog -OutputPath $OutputPath -Version $Version
    }

    # Try Python script
    $pyScript = Join-Path $PSScriptRoot 'generate_changelog.py'
    if (-not (Test-Path $pyScript)) {
        return New-FallbackChangelog -OutputPath $OutputPath -Version $Version -VersionInfoPath $VersionInfoPath
    }

    try {
        # Check if Python is available
        $null = & python --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'Python not available'
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
    }
    catch {
        Write-VerboseLog "Python changelog generation failed: $($_.Exception.Message)"
    }

    # Fall back if Python failed
    return New-FallbackChangelog -OutputPath $OutputPath -Version $Version -VersionInfoPath $VersionInfoPath
}

# ============================================================================
# Build Functions
# ============================================================================

function Invoke-InstallerBuild {
    <#
    .SYNOPSIS
        Builds the installer using Inno Setup.
    .PARAMETER Name
        The installer display name.
    .PARAMETER OutputName
        The base output filename.
    .PARAMETER Version
        The version string.
    .PARAMETER Architecture
        The architecture (32 or 64).
    .PARAMETER SourcePath
        Path to the MinGW source files.
    .PARAMETER OutputDirectory
        Directory for the built installer.
    .PARAMETER IssPath
        Path to the Inno Setup script.
    .OUTPUTS
        $true on success, $false on failure.
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
        Generates SHA256 and MD5 hashes for a built installer.
    .PARAMETER FilePath
        Path to the file to hash.
    .PARAMETER OutputDirectory
        Directory to write the hash file.
    .PARAMETER BaseName
        Base name for the hash file.
    .PARAMETER Version
        Version string.
    .PARAMETER Architecture
        Architecture string.
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
        Builds a single architecture variant.
    .DESCRIPTION
        Handles the complete build process for one architecture:
        download/extract (or test fixtures), changelog, and installer build.
    .PARAMETER Architecture
        The architecture to build (32 or 64).
    .PARAMETER AssetPattern
        Regex pattern to match the download asset.
    .PARAMETER Release
        The GitHub release object.
    .PARAMETER Version
        The version string.
    .PARAMETER Date
        The release date string.
    .PARAMETER PreviousTag
        The previous release tag for changelog.
    .PARAMETER CurrentTag
        If provided, fetch current package info from this GitHub release for changelog.
    .PARAMETER OutputDirectory
        Directory for build outputs.
    .PARAMETER TempDirectory
        Temporary working directory.
    .PARAMETER IssPath
        Path to Inno Setup script.
    .PARAMETER ReleaseNotesPath
        Path to write release notes.
    .OUTPUTS
        $true on success, $false on failure.
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
        Appends hash file contents to the changelog.
    .PARAMETER ChangelogPath
        Path to the changelog file.
    .PARAMETER OutputDirectory
        Directory containing hash files.
    .PARAMETER Version
        The version string.
    .PARAMETER Architectures
        Array of architectures to add hashes for.
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
