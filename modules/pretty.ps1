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
        [string]$Version,
        [string[]]$Architectures,
        [string]$OutputPath,
        [TimeSpan]$Duration
    )

    Write-SeparatorLine -Character '=' -Length 60
    
    if ($Success) {
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