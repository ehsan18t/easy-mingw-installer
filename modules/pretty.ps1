# ============================================================================
# Easy MinGW Installer - Logging & Output Module
# ============================================================================
# Provides formatted, colored console output with GitHub Actions compatibility.
# ============================================================================

# Console colors
$script:colors = @{
    Black       = 'Black'
    DarkBlue    = 'DarkBlue'
    DarkGreen   = 'DarkGreen'
    DarkCyan    = 'DarkCyan'
    DarkRed     = 'DarkRed'
    DarkMagenta = 'DarkMagenta'
    DarkYellow  = 'DarkYellow'
    Gray        = 'Gray'
    DarkGray    = 'DarkGray'
    Blue        = 'Blue'
    Green       = 'Green'
    Cyan        = 'Cyan'
    Red         = 'Red'
    Magenta     = 'Magenta'
    Yellow      = 'Yellow'
    White       = 'White'
}

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
        [System.ConsoleColor]$TypeColor = $script:colors.White,
        [System.ConsoleColor]$MessageColor = $script:colors.DarkCyan
    )
    Write-FormattedLine -Indicator "->" -Type $Type -Message $Message -IndicatorColor $script:colors.Blue -TypeColor $TypeColor -MessageColor $MessageColor
}

function Write-StatusInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [System.ConsoleColor]$TypeColor = $script:colors.White,
        [System.ConsoleColor]$MessageColor = $script:colors.Yellow
    )
    Write-FormattedLine -Indicator ">>" -Type $Type -Message $Message -IndicatorColor $script:colors.Magenta -TypeColor $TypeColor -MessageColor $MessageColor
}

function Write-SuccessMessage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [System.ConsoleColor]$TypeColor = $script:colors.White, # Or $script:colors.Green
        [System.ConsoleColor]$MessageColor = $script:colors.Green
    )
    Write-FormattedLine -Indicator "++" -Type $Type -Message $Message -IndicatorColor $script:colors.Green -TypeColor $TypeColor -MessageColor $MessageColor
}

function Write-WarningMessage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [System.ConsoleColor]$TypeColor = $script:colors.DarkYellow,
        [System.ConsoleColor]$MessageColor = $script:colors.DarkRed
    )
    Write-FormattedLine -Indicator "!!" -Type $Type -Message $Message -IndicatorColor $script:colors.Red -TypeColor $TypeColor -MessageColor $MessageColor
}

function Write-ActionProgress {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ActionName, # e.g., "Downloading", "Extracting"
        [Parameter(Mandatory = $true)]
        [string]$Details,    # e.g., "filename.zip" or progress info
        [System.ConsoleColor]$ActionColor = $script:colors.White,
        [System.ConsoleColor]$DetailsColor = $script:colors.Yellow
    )
    Write-ColoredHost -Text " >> " -ForegroundColor $script:colors.DarkYellow -NoNewline
    Write-ColoredHost -Text "$($ActionName) " -ForegroundColor $ActionColor -NoNewline
    Write-ColoredHost -Text $Details -ForegroundColor $DetailsColor
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
        [System.ConsoleColor]$TypeColor = $script:colors.DarkRed,
        [System.ConsoleColor]$MessageColor = $script:colors.Red
    )
    Write-ColoredHost -Text " !! $($ErrorType): " -ForegroundColor $TypeColor -NoNewline
    Write-ColoredHost -Text $Message -ForegroundColor $MessageColor

    if ($AssociatedExitCode -ne 0) {
        Write-ColoredHost -Text "    Associated Exit Code: " -ForegroundColor $script:colors.DarkRed -NoNewline
        Write-ColoredHost -Text $AssociatedExitCode -ForegroundColor $script:colors.Cyan
    }
    if ($LogFilePath) {
        Write-ColoredHost -Text " >> " -ForegroundColor $script:colors.DarkYellow -NoNewline
        Write-ColoredHost -Text "Log: " -ForegroundColor $script:colors.Yellow -NoNewline
        Write-ColoredHost -Text $LogFilePath -ForegroundColor $script:colors.Cyan
    }
}

function Write-SeparatorLine {
    [CmdletBinding()]
    param(
        [string]$Character = "-",
        [int]$Length = 50,
        [System.ConsoleColor]$Color = $script:colors.DarkGray
    )
    Write-ColoredHost -Text ($Character * $Length) -ForegroundColor $Color
}

function Write-UpdatingLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $false)]
        [System.ConsoleColor]$ForegroundColor = $script:colors.Yellow,
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

function Write-GitHubActionsGroup {
    <#
    .SYNOPSIS
        Starts or ends a collapsible group in GitHub Actions logs.
    #>
    [CmdletBinding()]
    param(
        [switch]$Start,
        [switch]$End,
        [string]$Name
    )

    if (-not $script:IsGitHubActions) { return }

    if ($Start -and $Name) {
        Write-Host "::group::$Name"
    }
    elseif ($End) {
        Write-Host '::endgroup::'
    }
}

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

function Write-GitHubActionsWarning {
    <#
    .SYNOPSIS
        Writes a warning annotation in GitHub Actions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $script:IsGitHubActions) {
        Write-WarningMessage -Type 'WARNING' -Message $Message
        return
    }

    Write-Host "::warning::$Message"
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
    Write-ColoredHost -Text "  $Title" -ForegroundColor $script:colors.Cyan
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
    Write-ColoredHost -Text '  BUILD CONFIGURATION' -ForegroundColor $script:colors.White
    Write-SeparatorLine -Character '-' -Length 50

    # Mode Information
    Write-BuildInfoLine -Label 'Mode' -Value $(
        if ($Config.IsTestMode) { 'TEST MODE' }
        elseif ($Config.IsGitHubActions) { 'GitHub Actions' }
        else { 'Normal' }
    ) -ValueColor $(if ($Config.IsTestMode) { $script:colors.Yellow } else { $script:colors.Green })

    # Active Flags
    $flags = @()
    if ($Config.SkipDownload) { $flags += 'SkipDownload' }
    if ($Config.SkipBuild) { $flags += 'SkipBuild' }
    if ($Config.SkipChangelog) { $flags += 'SkipChangelog' }
    
    if ($flags.Count -gt 0) {
        Write-BuildInfoLine -Label 'Active Flags' -Value ($flags -join ', ') -ValueColor $script:colors.DarkYellow
    }

    # Log Level
    Write-BuildInfoLine -Label 'Log Level' -Value $Config.LogLevel

    Write-Host ''

    # Tool Paths
    Write-ColoredHost -Text '  Tools:' -ForegroundColor $script:colors.Gray
    Write-BuildInfoLine -Label '7-Zip' -Value $(
        if ($Config.SevenZipPath) { $Config.SevenZipPath } else { '(not found)' }
    ) -ValueColor $(if ($Config.SevenZipPath) { $script:colors.Cyan } else { $script:colors.Red })
    
    Write-BuildInfoLine -Label 'Inno Setup' -Value $(
        if ($Config.InnoSetupPath) { $Config.InnoSetupPath } else { '(not found)' }
    ) -ValueColor $(if ($Config.InnoSetupPath) { $script:colors.Cyan } else { $script:colors.Red })

    Write-Host ''

    # Directories
    Write-ColoredHost -Text '  Directories:' -ForegroundColor $script:colors.Gray
    Write-BuildInfoLine -Label 'Temp' -Value $Config.TempDirectory
    if ($OutputPath) {
        Write-BuildInfoLine -Label 'Output' -Value $OutputPath
    }

    # Architectures
    if ($Architectures -and $Architectures.Count -gt 0) {
        Write-Host ''
        Write-ColoredHost -Text '  Build Targets:' -ForegroundColor $script:colors.Gray
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
        
        [System.ConsoleColor]$LabelColor = $script:colors.DarkGray,
        [System.ConsoleColor]$ValueColor = $script:colors.Cyan
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
        Write-ColoredHost -Text "    [VERBOSE] $Message" -ForegroundColor $script:colors.DarkGray
    }
}

function Write-DebugLog {
    <#
    .SYNOPSIS
        Writes a debug log message (only shown when LogLevel is 'Verbose').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $logLevel = 'Normal'
    if (Get-Command Get-BuildConfig -ErrorAction SilentlyContinue) {
        $cfg = Get-BuildConfig
        if ($cfg -and $cfg.LogLevel) {
            $logLevel = $cfg.LogLevel
        }
    }

    if ($logLevel -eq 'Verbose') {
        Write-ColoredHost -Text "    [DEBUG] $Message" -ForegroundColor $script:colors.DarkMagenta
    }
}

function Test-ShouldLog {
    <#
    .SYNOPSIS
        Returns whether logging should occur based on current log level.
    .PARAMETER Level
        The minimum level required ('Verbose', 'Normal', 'Quiet').
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Verbose', 'Normal', 'Quiet')]
        [string]$Level
    )

    $currentLevel = 'Normal'
    if (Get-Command Get-BuildConfig -ErrorAction SilentlyContinue) {
        $cfg = Get-BuildConfig
        if ($cfg -and $cfg.LogLevel) {
            $currentLevel = $cfg.LogLevel
        }
    }

    $levelOrder = @{ 'Verbose' = 0; 'Normal' = 1; 'Quiet' = 2 }
    
    return $levelOrder[$currentLevel] -le $levelOrder[$Level]
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