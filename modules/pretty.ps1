<#
.SYNOPSIS
    Logging and formatted output module for Easy MinGW Installer.

.DESCRIPTION
    This module provides consistent, colored console output throughout the build
    process. It handles both local terminal output and GitHub Actions workflow
    integration with proper annotations.
    
    ═══════════════════════════════════════════════════════════════════════════════
    OUTPUT FORMATTING CONVENTIONS
    ═══════════════════════════════════════════════════════════════════════════════
    
    All output follows a consistent format: INDICATOR TYPE: MESSAGE
    
    ┌──────────────┬────────────┬─────────────────────────────────────────────────┐
    │  Indicator   │  Function  │  Purpose                                        │
    ├──────────────┼────────────┼─────────────────────────────────────────────────┤
    │  ->          │ LogEntry   │ General log messages (blue indicator)           │
    │  >>          │ StatusInfo │ Status/progress updates (magenta indicator)     │
    │  ++          │ Success    │ Successful operations (green indicator)         │
    │  !!          │ Warning    │ Warnings and cautions (red indicator)           │
    │  **          │ Error      │ Error messages (dark red indicator)             │
    └──────────────┴────────────┴─────────────────────────────────────────────────┘
    
    ═══════════════════════════════════════════════════════════════════════════════
    FUNCTION CATEGORIES
    ═══════════════════════════════════════════════════════════════════════════════
    
    BASIC OUTPUT:
    - Write-ColoredHost      : Write text with specified foreground color
    - Write-FormattedLine    : Write indicator + type + message format
    - Write-SeparatorLine    : Write horizontal separator (----)
    
    MESSAGE TYPES:
    - Write-LogEntry         : Standard log message (-> Type: Message)
    - Write-StatusInfo       : Status/progress (>> Type: Message)
    - Write-SuccessMessage   : Success notification (++ Type: Message)
    - Write-WarningMessage   : Warning notification (!! Type: Message)
    - Write-ErrorMessage     : Error notification (** Type: Message)
    DYNAMIC OUTPUT:
    - Write-UpdatingLine     : Updates current line (for progress display)
    - End-UpdatingLine       : Ends an updating line with newline
    
    GITHUB ACTIONS INTEGRATION:
    - Write-GitHubActionsError   : Write error annotation
    
    BUILD INFORMATION:
    - Write-BuildHeader      : Display script banner/title
    - Write-BuildInfo        : Display build configuration summary
    - Write-BuildInfoLine    : Single line in build info display
    - Write-BuildSummary     : Final build status summary
    
    VERBOSE (respects LogLevel):
    - Write-VerboseLog       : Only shown when LogLevel is 'Verbose'

.NOTES
    File Name      : pretty.ps1
    Location       : modules/pretty.ps1
    
    SCRIPT-SCOPED VARIABLES:
    - $script:IsGitHubActions: Boolean, true when running in GitHub Actions
    
    GITHUB ACTIONS DETECTION:
    The module automatically detects GitHub Actions environment via
    $env:GITHUB_ACTIONS and adjusts output accordingly:
    - Uses workflow command syntax (::group::, ::error::, etc.)
    - Disables carriage return updates (no console refresh)

.EXAMPLE
    # Basic usage
    Write-StatusInfo -Type 'Download' -Message 'Starting file download...'
    Write-SuccessMessage -Type 'Downloaded' -Message 'file.zip (15.2 MB)'
    Write-ErrorMessage -ErrorType 'FATAL' -Message 'Build failed'
    
.EXAMPLE
    # Progress with updating line
    for ($i = 1; $i -le 100; $i++) {
        Write-UpdatingLine -Text "Progress: $i%"
        Start-Sleep -Milliseconds 50
    }
    End-UpdatingLine
    
.EXAMPLE
    # Build summary
    Write-BuildSummary -Success $true -Version '2024.01.15' `
        -Architectures @('64', '32') -OutputPath './output'
#>

# ============================================================================
# Easy MinGW Installer - Logging & Output Module
# ============================================================================
# Provides formatted, colored console output with GitHub Actions compatibility.
# ============================================================================

# Detect GitHub Actions environment
$script:IsGitHubActions = $env:GITHUB_ACTIONS -eq 'true'

# Function to print colored output
function Write-ColoredHost {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [System.ConsoleColor]$ForegroundColor,
        [switch]$NoNewline
    )
    if ($NoNewline) {
        Write-Host -Object $Text -ForegroundColor $ForegroundColor -NoNewline
    } else {
        Write-Host -Object $Text -ForegroundColor $ForegroundColor
    }
}

function Write-FormattedLine {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Indicator,
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $true)]
        [System.ConsoleColor]$IndicatorColor,
        [Parameter(Mandatory = $true)]
        [System.ConsoleColor]$TypeColor,
        [Parameter(Mandatory = $true)]
        [System.ConsoleColor]$MessageColor
    )
    Write-ColoredHost -Text " $Indicator " -ForegroundColor $IndicatorColor -NoNewline
    Write-ColoredHost -Text "$($Type): " -ForegroundColor $TypeColor -NoNewline
    Write-ColoredHost -Text $Message -ForegroundColor $MessageColor
}

function Write-LogEntry {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [System.ConsoleColor]$TypeColor = 'White',
        [System.ConsoleColor]$MessageColor = 'DarkCyan'
    )
    Write-FormattedLine -Indicator "->" -Type $Type -Message $Message -IndicatorColor 'Blue' -TypeColor $TypeColor -MessageColor $MessageColor
}

function Write-StatusInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [System.ConsoleColor]$TypeColor = 'White',
        [System.ConsoleColor]$MessageColor = 'Yellow'
    )
    Write-FormattedLine -Indicator ">>" -Type $Type -Message $Message -IndicatorColor 'Magenta' -TypeColor $TypeColor -MessageColor $MessageColor
}

function Write-SuccessMessage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [System.ConsoleColor]$TypeColor = 'White',
        [System.ConsoleColor]$MessageColor = 'Green'
    )
    Write-FormattedLine -Indicator "++" -Type $Type -Message $Message -IndicatorColor 'Green' -TypeColor $TypeColor -MessageColor $MessageColor
}

function Write-WarningMessage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [System.ConsoleColor]$TypeColor = 'DarkYellow',
        [System.ConsoleColor]$MessageColor = 'DarkRed'
    )
    Write-FormattedLine -Indicator "!!" -Type $Type -Message $Message -IndicatorColor 'Red' -TypeColor $TypeColor -MessageColor $MessageColor
}


function Write-ErrorMessage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ErrorType, # e.g., "ERROR", "CRITICAL"
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$LogFilePath,
        [int]$AssociatedExitCode = 0,
        [System.ConsoleColor]$TypeColor = 'DarkRed',
        [System.ConsoleColor]$MessageColor = 'Red'
    )
    Write-ColoredHost -Text " !! $($ErrorType): " -ForegroundColor $TypeColor -NoNewline
    Write-ColoredHost -Text $Message -ForegroundColor $MessageColor

    if ($AssociatedExitCode -ne 0) {
        Write-ColoredHost -Text "    Associated Exit Code: " -ForegroundColor 'DarkRed' -NoNewline
        Write-ColoredHost -Text $AssociatedExitCode -ForegroundColor 'Cyan'
    }
    if ($LogFilePath) {
        Write-ColoredHost -Text " >> " -ForegroundColor 'DarkYellow' -NoNewline
        Write-ColoredHost -Text "Log: " -ForegroundColor 'Yellow' -NoNewline
        Write-ColoredHost -Text $LogFilePath -ForegroundColor 'Cyan'
    }
}

function Write-SeparatorLine {
    [CmdletBinding()]
    param(
        [string]$Character = "-",
        [int]$Length = 50,
        [System.ConsoleColor]$Color = 'DarkGray'
    )
    Write-ColoredHost -Text ($Character * $Length) -ForegroundColor $Color
}

function Write-UpdatingLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $false)]
        [System.ConsoleColor]$ForegroundColor = 'Yellow',
        [Parameter(Mandatory = $false)]
        [int]$LineClearLength = 78
    )
    
    if ($script:IsGitHubActions) {
        # GitHub Actions doesn't support carriage return updates
        Write-Host $Text -ForegroundColor $ForegroundColor
    }
    else {
        $lineContent = "`r$($Text.PadRight($LineClearLength))"
        Write-Host -Object $lineContent -NoNewline -ForegroundColor $ForegroundColor
    }
}

function End-UpdatingLine {
    [CmdletBinding()]
    param()
    
    if (-not $script:IsGitHubActions) {
        Write-Host ''
    }
}

# ============================================================================
# GitHub Actions Integration
# ============================================================================

function Write-GitHubActionsError {
    <#
    .SYNOPSIS
        Writes an error annotation in GitHub Actions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$File,
        [int]$Line,
        [int]$Column
    )

    if (-not $script:IsGitHubActions) {
        Write-ErrorMessage -ErrorType 'ERROR' -Message $Message
        return
    }

    $annotation = '::error'
    $params = @()
    if ($File) { $params += "file=$File" }
    if ($Line -gt 0) { $params += "line=$Line" }
    if ($Column -gt 0) { $params += "col=$Column" }
    
    if ($params.Count -gt 0) {
        $annotation += " $($params -join ',')"
    }
    $annotation += "::$Message"
    
    Write-Host $annotation
}

# ============================================================================
# Build Info Display
# ============================================================================

function Write-BuildHeader {
    <#
    .SYNOPSIS
        Writes the build script header/banner.
    .PARAMETER Title
        The title to display (e.g., 'Easy MinGW Installer Builder').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title
    )

    Write-Host ''
    Write-SeparatorLine -Character '=' -Length 60
    Write-ColoredHost -Text "  $Title" -ForegroundColor 'Cyan'
    Write-SeparatorLine -Character '=' -Length 60
}

function Write-BuildInfo {
    <#
    .SYNOPSIS
        Displays comprehensive build configuration info at startup.
    .DESCRIPTION
        Shows mode, active flags, tool paths, directories, and other
        relevant configuration in a nicely formatted table.
    .PARAMETER Config
        The build configuration object from Get-BuildConfig.
    .PARAMETER Architectures
        Array of architectures being built (e.g., @('64', '32')).
    .PARAMETER OutputPath
        Path where build outputs will be saved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Config,
        
        [Parameter()]
        [string[]]$Architectures,
        
        [Parameter()]
        [string]$OutputPath
    )

    Write-Host ''
    Write-SeparatorLine -Character '-' -Length 50
    Write-ColoredHost -Text '  BUILD CONFIGURATION' -ForegroundColor 'White'
    Write-SeparatorLine -Character '-' -Length 50

    # Mode Information
    Write-BuildInfoLine -Label 'Mode' -Value $(
        if ($Config.IsTestMode) { 'TEST MODE' }
        elseif ($Config.IsGitHubActions) { 'GitHub Actions' }
        else { 'Normal' }
    ) -ValueColor $(if ($Config.IsTestMode) { 'Yellow' } else { 'Green' })

    # Active Flags
    $flags = @()
    if ($Config.SkipDownload) { $flags += 'SkipDownload' }
    if ($Config.SkipBuild) { $flags += 'SkipBuild' }
    if ($Config.SkipChangelog) { $flags += 'SkipChangelog' }
    
    if ($flags.Count -gt 0) {
        Write-BuildInfoLine -Label 'Active Flags' -Value ($flags -join ', ') -ValueColor 'DarkYellow'
    }

    # Log Level
    Write-BuildInfoLine -Label 'Log Level' -Value $Config.LogLevel

    Write-Host ''

    # Tool Paths
    Write-ColoredHost -Text '  Tools:' -ForegroundColor 'Gray'
    Write-BuildInfoLine -Label '7-Zip' -Value $(
        if ($Config.SevenZipPath) { $Config.SevenZipPath } else { '(not found)' }
    ) -ValueColor $(if ($Config.SevenZipPath) { 'Cyan' } else { 'Red' })
    
    Write-BuildInfoLine -Label 'Inno Setup' -Value $(
        if ($Config.InnoSetupPath) { $Config.InnoSetupPath } else { '(not found)' }
    ) -ValueColor $(if ($Config.InnoSetupPath) { 'Cyan' } else { 'Red' })

    Write-Host ''

    # Directories
    Write-ColoredHost -Text '  Directories:' -ForegroundColor 'Gray'
    Write-BuildInfoLine -Label 'Temp' -Value $Config.TempDirectory
    if ($OutputPath) {
        Write-BuildInfoLine -Label 'Output' -Value $OutputPath
    }

    # Architectures
    if ($Architectures -and $Architectures.Count -gt 0) {
        Write-Host ''
        Write-ColoredHost -Text '  Build Targets:' -ForegroundColor 'Gray'
        Write-BuildInfoLine -Label 'Architectures' -Value (($Architectures | ForEach-Object { "$_-bit" }) -join ', ')
    }

    Write-SeparatorLine -Character '-' -Length 50
    Write-Host ''
}

function Write-BuildInfoLine {
    <#
    .SYNOPSIS
        Writes a single line of build info with consistent formatting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,
        
        [Parameter(Mandatory)]
        [string]$Value,
        
        [System.ConsoleColor]$LabelColor = 'DarkGray',
        [System.ConsoleColor]$ValueColor = 'Cyan'
    )

    $paddedLabel = $Label.PadLeft(15)
    Write-ColoredHost -Text "    $paddedLabel : " -ForegroundColor $LabelColor -NoNewline
    Write-ColoredHost -Text $Value -ForegroundColor $ValueColor
}

# ============================================================================
# Verbose/Debug Logging (respects LogLevel)
# ============================================================================

function Write-VerboseLog {
    <#
    .SYNOPSIS
        Writes a verbose log message (only shown when LogLevel is 'Verbose').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    # Check if we have access to config
    $logLevel = 'Normal'
    if (Get-Command Get-BuildConfig -ErrorAction SilentlyContinue) {
        $cfg = Get-BuildConfig
        if ($cfg -and $cfg.LogLevel) {
            $logLevel = $cfg.LogLevel
        }
    }

    if ($logLevel -eq 'Verbose') {
        Write-ColoredHost -Text "    [VERBOSE] $Message" -ForegroundColor 'DarkGray'
    }
}

# ============================================================================
# Build Summary
# ============================================================================

function Write-BuildSummary {
    <#
    .SYNOPSIS
        Writes a formatted build summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Success,
        
        [Parameter()]
        [switch]$Cancelled,
        
        [string]$Version,
        [string[]]$Architectures,
        [string]$OutputPath,
        [TimeSpan]$Duration
    )

    Write-SeparatorLine -Character '=' -Length 60
    
    if ($Cancelled) {
        Write-WarningMessage -Type 'BUILD CANCELLED' -Message 'Operation was interrupted by user'
    }
    elseif ($Success) {
        Write-SuccessMessage -Type 'BUILD COMPLETE' -Message 'All operations succeeded'
    }
    else {
        Write-ErrorMessage -ErrorType 'BUILD FAILED' -Message 'One or more operations failed'
    }

    if ($Version) {
        Write-StatusInfo -Type 'Version' -Message $Version
    }

    if ($Architectures) {
        Write-StatusInfo -Type 'Architectures' -Message ($Architectures -join ', ')
    }

    if ($OutputPath) {
        Write-StatusInfo -Type 'Output' -Message $OutputPath
    }

    if ($Duration) {
        $durationStr = '{0:mm}m {0:ss}s' -f $Duration
        Write-StatusInfo -Type 'Duration' -Message $durationStr
    }

    Write-SeparatorLine -Character '=' -Length 60
}