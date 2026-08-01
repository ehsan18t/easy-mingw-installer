<#
.SYNOPSIS
    Centralized configuration module for Easy MinGW Installer build system.

.DESCRIPTION
    This module provides a single source of truth for all configurable settings
    used throughout the build process. It implements a layered configuration
    approach:
    
    CONFIGURATION HIERARCHY (highest to lowest priority):
    1. Runtime parameter overrides (passed to Initialize-BuildConfig)
    2. Environment variables (prefixed with EMI_)
    3. Default values defined in this module
    
    KEY CONCEPTS:
    
    - LAZY INITIALIZATION: The configuration object is created on first access
      via Get-BuildConfig and cached for subsequent calls.
    
    - ENVIRONMENT OVERRIDES: Most settings can be overridden via environment
      variables prefixed with EMI_ (e.g., EMI_LOG_LEVEL, EMI_7ZIP_PATH).
    
    - TOOL AUTO-DETECTION: 7-Zip and Inno Setup paths are automatically
      discovered from common Program Files locations.
    
    - MODE FLAGS: Two flags control how the build sources its payload:
      * SkipDownload - Use generated fixtures instead of downloading; everything
                       else, including the changelog, runs normally
      * OfflineMode  - No network requests at all; implies SkipDownload and
                       SkipChangelog
      Plus SkipBuild, SkipChangelog, SkipHashes for granular step control.
    
    USAGE:
    
    1. Call Initialize-BuildConfig once at script startup with any overrides
    2. Use Get-BuildConfig throughout the codebase to access settings

.NOTES
    File Name      : config.ps1
    Location       : modules/config.ps1
    
    EXPORTED FUNCTIONS:
    - Get-BuildConfig        : Returns the configuration object
    - Initialize-BuildConfig : Initializes config with runtime overrides
    - Test-BuildDependencies : Validates required tools are available
    INTERNAL FUNCTIONS:
    - Get-EnvOrDefault       : Gets env var or returns default
    - Find-Tool              : Locates an executable via env var or Program Files
    - Find-Python            : Locates a working Python interpreter

.EXAMPLE
    # Basic usage in a script
    . "$PSScriptRoot\modules\config.ps1"
    Initialize-BuildConfig -Overrides @{ SkipDownload = $true }
    $cfg = Get-BuildConfig
    Write-Host "Using 7-Zip at: $($cfg.SevenZipPath)"

.EXAMPLE
    # Environment variable override
    $env:EMI_LOG_LEVEL = 'Verbose'
    $env:EMI_7ZIP_PATH = 'D:\Tools\7-Zip\7z.exe'
    $cfg = Get-BuildConfig
#>

# ============================================================================
# Easy MinGW Installer - Configuration Module
# ============================================================================
# Centralized configuration with environment variable overrides.
# All configurable values should be defined here for easy maintenance.
# ============================================================================

# Script-scoped configuration object (cached after first initialization)
$script:Config = $null

# ============================================================================
# Logging Levels
# ============================================================================
# Controls the verbosity of output throughout the build process.
# Can be overridden via EMI_LOG_LEVEL environment variable.
#
# Values: 'Verbose', 'Normal', 'Quiet'
#   Verbose - Show all messages including debug info
#   Normal  - Show standard progress and status messages (default)
#   Quiet   - Show only errors and final status
# ============================================================================

$script:ValidLogLevels = @('Verbose', 'Normal', 'Quiet')

function Get-EnvOrDefault {
    <#
    .SYNOPSIS
        Returns environment variable value or default.
    .PARAMETER Name
        Environment variable name.
    .PARAMETER Default
        Default value if not set.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Default = ''
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value
}

function Find-Tool {
    <#
    .SYNOPSIS
        Locates an executable, preferring an environment-variable override.

    .DESCRIPTION
        Resolution order:
        1. The environment variable named by -EnvVar, if set and pointing at a file.
        2. Each -SubPaths candidate under each Program Files location, in the order
           given. Candidates are tried outer-first, so an earlier candidate found in
           any Program Files directory beats a later candidate found in the first
           one. That is what makes Inno Setup 6 win over Inno Setup 5.

        Program Files locations searched: %ProgramFiles%, %ProgramFiles(x86)%, and
        the literal C: paths as a fallback for a 32-bit host process where the
        environment variables resolve unexpectedly.

    .PARAMETER SubPaths
        One or more paths relative to a Program Files directory, in priority order.
        Example: 'Inno Setup 6\ISCC.exe', 'Inno Setup 5\ISCC.exe'

    .PARAMETER EnvVar
        Name of an environment variable holding an explicit full path.
        Example: 'EMI_7ZIP_PATH'

    .OUTPUTS
        [string] Full path to the executable, or $null if not found.

    .EXAMPLE
        $sevenZip = Find-Tool -SubPaths '7-Zip\7z.exe' -EnvVar 'EMI_7ZIP_PATH'

    .EXAMPLE
        # Prefer Inno Setup 6, fall back to 5
        $iscc = Find-Tool -SubPaths 'Inno Setup 6\ISCC.exe', 'Inno Setup 5\ISCC.exe' `
                          -EnvVar 'EMI_INNOSETUP_PATH'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$SubPaths,

        [Parameter()]
        [string]$EnvVar
    )

    if ($EnvVar) {
        # -PathType Leaf is deliberate. The old Find-SevenZip accepted any existing
        # path, so a directory in EMI_7ZIP_PATH passed here and failed later at
        # process start with a much worse message.
        $envPath = Get-EnvOrDefault $EnvVar
        if ($envPath -and (Test-Path $envPath -PathType Leaf)) {
            return $envPath
        }
    }

    $searchPaths = @(
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        'C:\Program Files'
        'C:\Program Files (x86)'
    ) | Where-Object { $_ } | Select-Object -Unique

    foreach ($subPath in $SubPaths) {
        foreach ($basePath in $searchPaths) {
            $fullPath = Join-Path $basePath $subPath
            if (Test-Path $fullPath -PathType Leaf) {
                return $fullPath
            }
        }
    }

    return $null
}

function Find-Python {
    <#
    .SYNOPSIS
        Locates a working Python interpreter.
    .DESCRIPTION
        Checks EMI_PYTHON_PATH first, then tries 'python' and finally the 'py'
        launcher.

        Both are needed on Windows: the official Python installer leaves "Add
        python.exe to PATH" unchecked by default, so a stock install provides 'py'
        but not 'python'. GitHub Actions runners with actions/setup-python provide
        'python'. Hardcoding either one breaks half the cases.

        Each candidate is executed with --version rather than merely resolved,
        because Windows ships App Execution Aliases named python.exe that exist on
        PATH but only open the Microsoft Store.
    .OUTPUTS
        [string] Command to invoke Python with, or $null if none works.
    .EXAMPLE
        $python = Find-Python
        if (-not $python) { throw 'Python not available' }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $envPath = Get-EnvOrDefault 'EMI_PYTHON_PATH'
    $candidates = @()
    if ($envPath) { $candidates += $envPath }
    $candidates += @('python', 'py')

    foreach ($candidate in $candidates) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        $null = & $cmd.Source '--version' 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $cmd.Source
        }
    }

    return $null
}

function Get-BuildConfig {
    <#
    .SYNOPSIS
        Returns the centralized build configuration object.
    
    .DESCRIPTION
        Creates and caches a configuration object with all build settings.
        Values can be overridden via environment variables prefixed with EMI_.
        
        The returned object contains the following property groups:
        
        REPOSITORY SETTINGS:
        - ProjectOwner    : GitHub owner of this project (ehsan18t)
        - ProjectRepo     : This repository name (easy-mingw-installer)
        - WinLibsOwner    : WinLibs GitHub owner (brechtsanders)
        - WinLibsRepo     : WinLibs repository name (winlibs_mingw)
        
        BUILD NAMING:
        - InstallerName     : Display name in installer UI
        - InstallerBaseName : Base filename for output files
        
        TOOL PATHS:
        - SevenZipPath   : Path to 7z.exe (auto-detected or override)
        - InnoSetupPath  : Path to ISCC.exe (auto-detected or override)
        - PythonPath     : Python command, 'python' or the 'py' launcher
                           (auto-detected, override with EMI_PYTHON_PATH)
        
        DIRECTORIES:
        - TempDirectory  : Temp folder for downloads and extraction
        - LogDirectory   : Folder for Inno Setup build logs (never inside OutputPath)
        
        API SETTINGS:
        - GitHubApiBase         : GitHub API URL
        - GitHubUserAgent       : User agent for API requests
        - ApiTimeoutSeconds     : Request timeout
        - ApiMaxRetries         : Max retry attempts
        - ApiRetryDelaySeconds  : Delay between retries
        
        DOWNLOAD SETTINGS:
        - DownloadRetries            : Max download retry attempts
        - DownloadRetryDelaySeconds  : Delay between download retries
        - DownloadBufferSize         : Buffer size for progress updates
        
        LOGGING:
        - LogLevel : Verbosity level (Verbose, Normal, Quiet)
        
        RUNTIME STATE (set via Initialize-BuildConfig):
        - IsGitHubActions    : True if running in GitHub Actions
        - OfflineMode        : No network requests at all
        - CleanFirst         : Clean temp before starting
        - SkipDownload       : Skip download phase
        - SkipBuild          : Skip Inno Setup compilation
        - SkipChangelog      : Skip changelog generation
        - SkipHashes         : Skip hash generation
        - GenerateLogsAlways : Always write Inno Setup logs
    
    .OUTPUTS
        PSCustomObject with all configuration properties.
    
    .EXAMPLE
        $cfg = Get-BuildConfig
        if ($cfg.OfflineMode) {
            Write-Host "Running with no network access"
        }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    if ($null -ne $script:Config) {
        return $script:Config
    }

    # Determine log level from environment
    $logLevel = Get-EnvOrDefault 'EMI_LOG_LEVEL' 'Normal'
    if ($logLevel -notin $script:ValidLogLevels) {
        $logLevel = 'Normal'
    }

    $script:Config = [PSCustomObject]@{
        # ========================
        # Repository Settings
        # ========================
        # Can be overridden via EMI_PROJECT_OWNER, EMI_PROJECT_REPO
        ProjectOwner      = Get-EnvOrDefault 'EMI_PROJECT_OWNER' 'ehsan18t'
        ProjectRepo       = Get-EnvOrDefault 'EMI_PROJECT_REPO' 'easy-mingw-installer'
        WinLibsOwner      = Get-EnvOrDefault 'EMI_WINLIBS_OWNER' 'brechtsanders'
        WinLibsRepo       = Get-EnvOrDefault 'EMI_WINLIBS_REPO' 'winlibs_mingw'

        # ========================
        # Build Naming
        # ========================
        InstallerName     = 'EasyMinGW Installer'
        InstallerBaseName = 'EasyMinGW.Installer'

        # ========================
        # Tool Paths
        # ========================
        # Auto-detected during initialization, can be overridden
        SevenZipPath      = $null
        InnoSetupPath     = $null
        PythonPath        = $null

        # ========================
        # Directories
        # ========================
        TempDirectory     = Join-Path ([System.IO.Path]::GetTempPath()) 'EasyMinGW_Build'
        # Build logs live outside OutputPath so they are never published as release
        # assets. $PSScriptRoot here is <repo>/modules, so the parent is the repo root.
        LogDirectory      = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'

        # ========================
        # API Settings
        # ========================
        GitHubApiBase     = 'https://api.github.com'
        GitHubUserAgent   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36'
        ApiTimeoutSeconds = 30
        ApiMaxRetries     = 3
        ApiRetryDelaySeconds = 5

        # ========================
        # Download Settings
        # ========================
        DownloadRetries   = 3
        DownloadRetryDelaySeconds = 10
        DownloadTimeoutSeconds = 600  # 10 minutes for large archive downloads
        DownloadBufferSize = 80KB  # Buffer size for download progress updates

        # ========================
        # Logging
        # ========================
        # Values: 'Verbose', 'Normal', 'Quiet'
        LogLevel          = $logLevel

        # ========================
        # Runtime State
        # ========================
        # These are set during initialization based on parameters/environment
        IsGitHubActions   = $env:GITHUB_ACTIONS -eq 'true'
        OfflineMode       = $false
        CleanFirst        = $false
        SkipDownload      = $false
        SkipBuild         = $false
        SkipChangelog     = $false
        SkipHashes        = $false
        GenerateLogsAlways = $false
    }

    return $script:Config
}

function Initialize-BuildConfig {
    <#
    .SYNOPSIS
        Initializes the build configuration with runtime overrides.
    
    .DESCRIPTION
        Should be called once at script startup to configure tool paths
        and runtime flags based on parameters and environment.
        
        This function performs the following:
        
        1. TOOL DETECTION
           Finds 7-Zip and Inno Setup executables in order of priority:
           - Parameter override (in $Overrides hashtable)
           - Environment variable (EMI_7ZIP_PATH, EMI_INNOSETUP_PATH)
           - Auto-detection from Program Files
        
        2. MODE FLAG CONFIGURATION
           - OfflineMode implies SkipDownload and SkipChangelog
           - SkipDownload on its own implies nothing else, so the changelog runs

        3. SKIP FLAG PROCESSING
           Explicit skip flags override the implications above:
           - SkipDownload, SkipBuild, SkipChangelog, SkipHashes
    
    .PARAMETER Overrides
        Hashtable of property overrides. Supported keys:
        - SevenZipPath      : Custom 7-Zip path
        - InnoSetupPath     : Custom Inno Setup path
        - OfflineMode       : Enable offline mode
        - CleanFirst        : Clean temp directory first
        - SkipDownload      : Use fixtures instead of downloading
        - SkipBuild         : Skip build phase
        - SkipChangelog     : Skip changelog generation
        - SkipHashes        : Skip hash generation
        - GenerateLogsAlways: Always generate build logs
        - LogLevel          : Override log verbosity
    
    .EXAMPLE
        Initialize-BuildConfig -Overrides @{
            SkipDownload = $true
            CleanFirst   = $true
        }
    
    .EXAMPLE
        # Override tool paths
        Initialize-BuildConfig -Overrides @{
            SevenZipPath = 'D:\Tools\7z.exe'
            InnoSetupPath = 'D:\Tools\ISCC.exe'
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [hashtable]$Overrides = @{}
    )

    $cfg = Get-BuildConfig

    # ========================
    # Tool Detection
    # ========================
    # Priority: Parameter override > Environment variable > Auto-detect
    
    if ($Overrides.ContainsKey('SevenZipPath') -and $Overrides.SevenZipPath) {
        $cfg.SevenZipPath = $Overrides.SevenZipPath
    }
    else {
        $cfg.SevenZipPath = Find-Tool -SubPaths '7-Zip\7z.exe' -EnvVar 'EMI_7ZIP_PATH'
    }

    if ($Overrides.ContainsKey('InnoSetupPath') -and $Overrides.InnoSetupPath) {
        $cfg.InnoSetupPath = $Overrides.InnoSetupPath
    }
    else {
        $cfg.InnoSetupPath = Find-Tool -SubPaths 'Inno Setup 6\ISCC.exe', 'Inno Setup 5\ISCC.exe' `
                                       -EnvVar 'EMI_INNOSETUP_PATH'
    }

    # Python is only needed for changelog generation, so a null here is not fatal;
    # Invoke-ChangelogGeneration reports it.
    $cfg.PythonPath = Find-Python

    # ========================
    # Mode Flags
    # ========================
    # Override keys match config property names, so one loop covers all of them.
    foreach ($key in @('OfflineMode', 'CleanFirst')) {
        if ($Overrides.ContainsKey($key)) {
            $cfg.$key = [bool]$Overrides[$key]
        }
    }

    # Offline mode implies both: no download, and no changelog (which needs the API).
    # -SkipDownload on its own implies neither, so the changelog still runs.
    if ($cfg.OfflineMode) {
        $cfg.SkipDownload = $true
        $cfg.SkipChangelog = $true
    }

    # Explicit skip flags win over the implication above.
    foreach ($key in @('SkipDownload', 'SkipBuild', 'SkipChangelog', 'SkipHashes', 'GenerateLogsAlways')) {
        if ($Overrides.ContainsKey($key)) {
            $cfg.$key = [bool]$Overrides[$key]
        }
    }

    # Log level override
    if ($Overrides.ContainsKey('LogLevel') -and $Overrides.LogLevel -in $script:ValidLogLevels) {
        $cfg.LogLevel = $Overrides.LogLevel
    }
}

function Test-BuildDependencies {
    <#
    .SYNOPSIS
        Validates that required build tools are available.
    
    .DESCRIPTION
        Checks that all required external tools are present and accessible:
        
        ALWAYS REQUIRED:
        - 7-Zip (7z.exe) - For extracting MinGW archives
        
        REQUIRED UNLESS SkipBuild:
        - Inno Setup (ISCC.exe) - For building Windows installers
        
        The function checks both the configured path and that the file exists.
        If a tool is missing, an appropriate error message is added to the
        Errors array with installation instructions.
    
    .OUTPUTS
        Hashtable with:
        - Success : [bool] True if all dependencies are met
        - Errors  : [string[]] Array of error messages for missing tools
    
    .EXAMPLE
        $result = Test-BuildDependencies
        if (-not $result.Success) {
            foreach ($err in $result.Errors) {
                Write-Error $err
            }
            exit 1
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $cfg = Get-BuildConfig
    $errors = @()

    # 7-Zip is always required
    if (-not $cfg.SevenZipPath) {
        $errors += '7-Zip not found. Install from https://7-zip.org or set EMI_7ZIP_PATH'
    }
    elseif (-not (Test-Path $cfg.SevenZipPath -PathType Leaf)) {
        $errors += "7-Zip path invalid: $($cfg.SevenZipPath)"
    }

    # Inno Setup required unless skipping build
    if (-not $cfg.SkipBuild) {
        if (-not $cfg.InnoSetupPath) {
            $errors += 'Inno Setup not found. Install from https://jrsoftware.org or set EMI_INNOSETUP_PATH'
        }
        elseif (-not (Test-Path $cfg.InnoSetupPath -PathType Leaf)) {
            $errors += "Inno Setup path invalid: $($cfg.InnoSetupPath)"
        }
    }

    return @{
        Success = ($errors.Count -eq 0)
        Errors  = $errors
    }
}
