# ============================================================================
# Easy MinGW Installer - Configuration Module
# ============================================================================
# Centralized configuration with environment variable overrides.
# All hardcoded values should be defined here.
# ============================================================================

# Script-scoped configuration object
$script:Config = $null

function Get-BuildConfig {
    <#
    .SYNOPSIS
        Returns the centralized build configuration object.
    .DESCRIPTION
        Creates and caches a configuration object with all build settings.
        Values can be overridden via environment variables.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    if ($null -ne $script:Config) {
        return $script:Config
    }

    $script:Config = [PSCustomObject]@{
        # Repository Information
        ProjectOwner      = Get-EnvOrDefault 'EMI_PROJECT_OWNER' 'ehsan18t'
        ProjectRepo       = Get-EnvOrDefault 'EMI_PROJECT_REPO' 'easy-mingw-installer'
        WinLibsOwner      = Get-EnvOrDefault 'EMI_WINLIBS_OWNER' 'brechtsanders'
        WinLibsRepo       = Get-EnvOrDefault 'EMI_WINLIBS_REPO' 'winlibs_mingw'

        # Build Metadata
        InstallerName     = 'EasyMinGW Installer'
        InstallerBaseName = 'EasyMinGW.Installer'
        
        # Version used in test mode
        TestModeVersion   = '2099.01.01'
        TestModeTag       = '2024.10.05'

        # Tool Paths (auto-detected if not specified)
        SevenZipPath      = $null  # Set during initialization
        InnoSetupPath     = $null  # Set during initialization

        # Default Tool Search Locations
        ToolSearchPaths   = @(
            $env:ProgramFiles
            ${env:ProgramFiles(x86)}
            'C:\Program Files'
            'C:\Program Files (x86)'
        ) | Where-Object { $_ }

        # Directories
        TempDirName       = 'EasyMinGWInstaller_Build'
        TempDirectory     = Join-Path ([System.IO.Path]::GetTempPath()) 'EasyMinGWInstaller_Build'

        # GitHub API
        GitHubApiBase     = 'https://api.github.com'
        GitHubUserAgent   = 'easy-mingw-installer-builder'
        ApiTimeoutSeconds = 30
        ApiMaxRetries     = 3
        ApiRetryDelay     = 5

        # Download Settings
        DownloadTimeout   = 300  # 5 minutes
        DownloadRetries   = 3
        DownloadRetryDelay = 10
        DownloadBufferSize = 81920  # 80KB

        # Runtime State (set during build)
        IsGitHubActions   = $env:GITHUB_ACTIONS -eq 'true'
        IsTestMode        = $false
        SkipDownload      = $false
        SkipBuild         = $false
        SkipChangelog     = $false
        OfflineMode       = $false
    }

    return $script:Config
}

function Get-EnvOrDefault {
    <#
    .SYNOPSIS
        Returns environment variable value or default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Default
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
        Searches for a tool executable in common locations.
    .DESCRIPTION
        Searches Program Files directories for a tool, returning the first match.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ToolName,
        
        [Parameter(Mandatory)]
        [string]$SubPath,
        
        [Parameter()]
        [string]$ExeName
    )

    $config = Get-BuildConfig
    
    foreach ($basePath in $config.ToolSearchPaths) {
        if (-not $basePath) { continue }
        
        $fullPath = Join-Path $basePath $SubPath
        if ($ExeName) {
            $fullPath = Join-Path $fullPath $ExeName
        }
        
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
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Check environment variable first
    $envPath = $env:EMI_7ZIP_PATH
    if ($envPath -and (Test-Path $envPath -PathType Leaf)) {
        return $envPath
    }

    return Find-Tool -ToolName '7-Zip' -SubPath '7-Zip' -ExeName '7z.exe'
}

function Find-InnoSetup {
    <#
    .SYNOPSIS
        Locates Inno Setup compiler executable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Check environment variable first
    $envPath = $env:EMI_INNOSETUP_PATH
    if ($envPath -and (Test-Path $envPath -PathType Leaf)) {
        return $envPath
    }

    # Try Inno Setup 6 first, then 5
    $path = Find-Tool -ToolName 'Inno Setup' -SubPath 'Inno Setup 6' -ExeName 'ISCC.exe'
    if ($path) { return $path }
    
    return Find-Tool -ToolName 'Inno Setup' -SubPath 'Inno Setup 5' -ExeName 'ISCC.exe'
}

function Initialize-BuildConfig {
    <#
    .SYNOPSIS
        Initializes build configuration with tool paths and mode settings.
    .DESCRIPTION
        Sets up the configuration object with discovered tool paths and
        applies mode-specific settings. Should be called once at script start.
    .PARAMETER Overrides
        A hashtable of configuration overrides to apply. Supports:
        - SevenZipPath, InnoSetupPath: Tool paths
        - IsTestMode, SkipDownload, SkipBuild, SkipChangelog, OfflineMode: Flags
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Overrides = @{}
    )

    $config = Get-BuildConfig

    # Extract override values
    $sevenZipPath = $Overrides['SevenZipPath']
    $innoSetupPath = $Overrides['InnoSetupPath']
    $testMode = $Overrides['IsTestMode'] -eq $true
    $skipDownload = $Overrides['SkipDownload'] -eq $true
    $skipBuild = $Overrides['SkipBuild'] -eq $true
    $skipChangelog = $Overrides['SkipChangelog'] -eq $true
    $offlineMode = $Overrides['OfflineMode'] -eq $true

    # Set tool paths (use provided or auto-detect)
    $config.SevenZipPath = if ($sevenZipPath) { $sevenZipPath } else { Find-SevenZip }
    $config.InnoSetupPath = if ($innoSetupPath) { $innoSetupPath } else { Find-InnoSetup }

    # Apply mode settings
    $config.IsTestMode = $testMode
    $config.SkipDownload = $skipDownload -or $testMode
    $config.SkipBuild = $skipBuild
    $config.SkipChangelog = $skipChangelog
    $config.OfflineMode = $offlineMode -or $testMode

    # In offline mode, skip changelog since it needs GitHub API
    if ($config.OfflineMode) {
        $config.SkipChangelog = $true
    }

    return $config
}

function Test-BuildDependencies {
    <#
    .SYNOPSIS
        Validates that all required build dependencies are available.
    .DESCRIPTION
        Checks for 7-Zip, Inno Setup, and optionally Python.
        Returns a result object with validation status and messages.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch]$RequirePython
    )

    $config = Get-BuildConfig
    $errors = @()
    $warnings = @()

    # Check 7-Zip
    if (-not $config.SevenZipPath) {
        $errors += '7-Zip not found. Install from https://www.7-zip.org/ or set EMI_7ZIP_PATH environment variable.'
    }
    elseif (-not (Test-Path $config.SevenZipPath -PathType Leaf)) {
        $errors += "7-Zip path invalid: $($config.SevenZipPath)"
    }

    # Check Inno Setup (only required if not skipping build)
    if (-not $config.SkipBuild) {
        if (-not $config.InnoSetupPath) {
            $errors += 'Inno Setup not found. Install from https://jrsoftware.org/isinfo.php or set EMI_INNOSETUP_PATH environment variable.'
        }
        elseif (-not (Test-Path $config.InnoSetupPath -PathType Leaf)) {
            $errors += "Inno Setup path invalid: $($config.InnoSetupPath)"
        }
    }

    # Check Python (for changelog generation)
    if ($RequirePython -and -not $config.SkipChangelog) {
        try {
            $pythonVersion = & python --version 2>&1
            if ($LASTEXITCODE -ne 0) {
                $warnings += 'Python not found. Changelog generation will use fallback template.'
            }
        }
        catch {
            $warnings += 'Python not available. Changelog generation will use fallback template.'
        }
    }

    return [PSCustomObject]@{
        Success  = $errors.Count -eq 0
        IsValid  = $errors.Count -eq 0
        Errors   = $errors
        Warnings = $warnings
    }
}

function Reset-BuildConfig {
    <#
    .SYNOPSIS
        Resets the configuration cache.
    .DESCRIPTION
        Clears the cached configuration object, forcing re-initialization on next access.
    #>
    [CmdletBinding()]
    param()

    $script:Config = $null
}

# Export module state for testing
function Get-ConfigDebugInfo {
    <#
    .SYNOPSIS
        Returns configuration state for debugging.
    #>
    [CmdletBinding()]
    param()

    $config = Get-BuildConfig
    return [PSCustomObject]@{
        Config           = $config
        SevenZipExists   = if ($config.SevenZipPath) { Test-Path $config.SevenZipPath } else { $false }
        InnoSetupExists  = if ($config.InnoSetupPath) { Test-Path $config.InnoSetupPath } else { $false }
        IsGitHubActions  = $config.IsGitHubActions
        WorkingDirectory = Get-Location
    }
}
