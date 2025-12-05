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
        Searches for a tool in Program Files directories.
    .PARAMETER SubPath
        Relative path under Program Files (e.g., '7-Zip\7z.exe').
    .RETURNS
        Full path if found, $null otherwise.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SubPath
    )

    $searchPaths = @(
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        'C:\Program Files'
        'C:\Program Files (x86)'
    ) | Where-Object { $_ } | Select-Object -Unique

    foreach ($basePath in $searchPaths) {
        $fullPath = Join-Path $basePath $SubPath
        if (Test-Path $fullPath -PathType Leaf) {
            return $fullPath
        }
    }

    return $null
}

function Find-SevenZip {
    <#
    .SYNOPSIS
        Locates 7-Zip executable.
    .DESCRIPTION
        Checks environment variable first, then searches Program Files.
    #>
    
    # Check environment variable
    $envPath = Get-EnvOrDefault 'EMI_7ZIP_PATH'
    if ($envPath -and (Test-Path $envPath)) {
        return $envPath
    }

    # Search common locations
    return Find-Tool '7-Zip\7z.exe'
}

function Find-InnoSetup {
    <#
    .SYNOPSIS
        Locates Inno Setup compiler (ISCC.exe).
    .DESCRIPTION
        Checks environment variable first, then searches for v6 and v5.
    #>
    
    # Check environment variable
    $envPath = Get-EnvOrDefault 'EMI_INNOSETUP_PATH'
    if ($envPath -and (Test-Path $envPath)) {
        return $envPath
    }

    # Try Inno Setup 6 first, then 5
    $path = Find-Tool 'Inno Setup 6\ISCC.exe'
    if ($path) { return $path }
    
    return Find-Tool 'Inno Setup 5\ISCC.exe'
}

function Get-BuildConfig {
    <#
    .SYNOPSIS
        Returns the centralized build configuration object.
    .DESCRIPTION
        Creates and caches a configuration object with all build settings.
        Values can be overridden via environment variables prefixed with EMI_.
    .OUTPUTS
        PSCustomObject with all configuration properties.
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
        # Test Mode Settings
        # ========================
        TestModeVersion   = '2099.01.01'

        # ========================
        # Tool Paths
        # ========================
        # Auto-detected during initialization, can be overridden
        SevenZipPath      = $null
        InnoSetupPath     = $null

        # ========================
        # Directories
        # ========================
        TempDirectory     = Join-Path ([System.IO.Path]::GetTempPath()) 'EasyMinGW_Build'

        # ========================
        # API Settings
        # ========================
        GitHubApiBase     = 'https://api.github.com'
        GitHubUserAgent   = 'easy-mingw-installer-builder'
        ApiTimeoutSeconds = 30
        ApiMaxRetries     = 3
        ApiRetryDelaySeconds = 5

        # ========================
        # Download Settings
        # ========================
        DownloadRetries   = 3
        DownloadRetryDelaySeconds = 10
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
        IsTestMode        = $false
        ValidateAssets    = $false
        GenerateChangelog = $false
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
    .PARAMETER Overrides
        Hashtable of property overrides (e.g., @{ IsTestMode = $true }).
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
        $cfg.SevenZipPath = Find-SevenZip
    }

    if ($Overrides.ContainsKey('InnoSetupPath') -and $Overrides.InnoSetupPath) {
        $cfg.InnoSetupPath = $Overrides.InnoSetupPath
    }
    else {
        $cfg.InnoSetupPath = Find-InnoSetup
    }

    # ========================
    # Mode Flags
    # ========================
    if ($Overrides.ContainsKey('IsTestMode')) {
        $cfg.IsTestMode = [bool]$Overrides.IsTestMode
    }
    if ($Overrides.ContainsKey('OfflineMode')) {
        $cfg.OfflineMode = [bool]$Overrides.OfflineMode
    }
    if ($Overrides.ContainsKey('CleanFirst')) {
        $cfg.CleanFirst = [bool]$Overrides.CleanFirst
    }
    if ($Overrides.ContainsKey('ValidateAssets')) {
        $cfg.ValidateAssets = [bool]$Overrides.ValidateAssets
    }
    if ($Overrides.ContainsKey('GenerateChangelog')) {
        $cfg.GenerateChangelog = [bool]$Overrides.GenerateChangelog
    }

    # Test mode implies skip download and changelog (but NOT build)
    if ($cfg.IsTestMode) {
        $cfg.SkipDownload = $true
        $cfg.SkipChangelog = $true
    }

    # Offline mode implies skip download and changelog (handled in Builder.ps1, but also enforce here)
    if ($cfg.OfflineMode) {
        $cfg.SkipDownload = $true
        $cfg.SkipChangelog = $true
    }

    # Allow explicit overrides of skip flags
    if ($Overrides.ContainsKey('SkipDownload')) {
        $cfg.SkipDownload = [bool]$Overrides.SkipDownload
    }
    if ($Overrides.ContainsKey('SkipBuild')) {
        $cfg.SkipBuild = [bool]$Overrides.SkipBuild
    }
    if ($Overrides.ContainsKey('SkipChangelog')) {
        $cfg.SkipChangelog = [bool]$Overrides.SkipChangelog
    }
    if ($Overrides.ContainsKey('SkipHashes')) {
        $cfg.SkipHashes = [bool]$Overrides.SkipHashes
    }
    
    # GenerateChangelog overrides SkipChangelog (must come after SkipChangelog handling)
    if ($cfg.GenerateChangelog) {
        $cfg.SkipChangelog = $false
    }
    
    if ($Overrides.ContainsKey('GenerateLogsAlways')) {
        $cfg.GenerateLogsAlways = [bool]$Overrides.GenerateLogsAlways
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
    .OUTPUTS
        Hashtable with Success (bool) and Errors (string[]).
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

function Reset-BuildConfig {
    <#
    .SYNOPSIS
        Resets the configuration cache (useful for testing).
    #>
    $script:Config = $null
}
