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
    
    ┌──────────────┬────────────┬──────────────────────────────┬─────────────────┐
    │  Indicator   │  Function  │  Purpose                     │  CI annotation  │
    ├──────────────┼────────────┼──────────────────────────────┼─────────────────┤
    │  [-]         │ LogEntry   │ General log messages         │  none           │
    │  [>]         │ StatusInfo │ Status/progress updates      │  none           │
    │  [+]         │ Success    │ Successful operations        │  none           │
    │  [!]         │ Warning    │ Warnings and cautions        │  ::warning::    │
    │  [X]         │ Error      │ Error messages               │  ::error::      │
    └──────────────┴────────────┴──────────────────────────────┴─────────────────┘

    Every level has a distinct indicator, so a plain-text log can be filtered by
    severity without relying on color: `Select-String '\[X\]'` finds errors only.
    modules/generate_changelog.py uses the same set, so Python and PowerShell output
    are indistinguishable in a combined log.

    Under GitHub Actions, Warning and Error additionally emit a workflow command so
    they appear in the run summary and PR UI rather than only in the log body.
    
    ═══════════════════════════════════════════════════════════════════════════════
    FUNCTION CATEGORIES
    ═══════════════════════════════════════════════════════════════════════════════
    
    BASIC OUTPUT:
    - Write-ColoredHost      : Write text with specified foreground color
    - Write-Log              : The single primitive all message types route through
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
    Warning and Error levels emit ::warning:: and ::error:: workflow commands
    automatically when $env:GITHUB_ACTIONS is 'true'. See Write-Log.
    - ConvertTo-GitHubAnnotationText : Escapes a message for a workflow command
    
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

# ============================================================================
# Message Styles
# ============================================================================
# One row per message level. Adding a level means adding a row here and a
# one-line wrapper below, nothing else.
#
# Annotation is the GitHub Actions workflow command emitted alongside the console
# line when running in CI, or $null for levels that should not clutter the run
# summary. Keeping it in this table is what stops the console severity and the CI
# severity from drifting apart.
# ============================================================================

$script:LogStyles = @{
    Log     = @{ Indicator = '[-]'; IndicatorColor = 'Blue';    TypeColor = 'White';      MessageColor = 'DarkCyan'; Annotation = $null }
    Status  = @{ Indicator = '[>]'; IndicatorColor = 'Magenta'; TypeColor = 'White';      MessageColor = 'Yellow';   Annotation = $null }
    Success = @{ Indicator = '[+]'; IndicatorColor = 'Green';   TypeColor = 'White';      MessageColor = 'Green';    Annotation = $null }
    Warning = @{ Indicator = '[!]'; IndicatorColor = 'Red';     TypeColor = 'DarkYellow'; MessageColor = 'DarkRed';  Annotation = 'warning' }
    Error   = @{ Indicator = '[X]'; IndicatorColor = 'DarkRed'; TypeColor = 'DarkRed';    MessageColor = 'Red';      Annotation = 'error' }
}

function ConvertTo-GitHubAnnotationText {
    <#
    .SYNOPSIS
        Escapes a string for use inside a GitHub Actions workflow command.
    .DESCRIPTION
        Workflow commands are line-based, so a literal newline ends the annotation
        early and everything after it is printed as plain log text. A literal percent
        sign is ambiguous with the escape sequences themselves, so it is escaped
        first. See "Setting an error message" in the GitHub Actions documentation.
    .PARAMETER Text
        The raw message.
    .OUTPUTS
        [string] The escaped message.
    .EXAMPLE
        ConvertTo-GitHubAnnotationText "Line one<newline>Line two"
        # Line one%0ALine two
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )
    # Percent must be escaped before the others, or their '%' would be double-escaped.
    return $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
}

function Write-ColoredHost {
    <#
    .SYNOPSIS
        Writes text in a given console color.
    .PARAMETER Text
        The text to write.
    .PARAMETER ForegroundColor
        Console color for the text.
    .PARAMETER NoNewline
        Suppress the trailing newline so the next write continues the same line.
    .EXAMPLE
        Write-ColoredHost -Text 'Building...' -ForegroundColor 'Cyan'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Text,
        [Parameter(Mandatory)]
        [System.ConsoleColor]$ForegroundColor,
        [switch]$NoNewline
    )
    Write-Host -Object $Text -ForegroundColor $ForegroundColor -NoNewline:$NoNewline
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a formatted, colored log line: " <indicator> <Type>: <Message>".

    .DESCRIPTION
        The single output primitive for the build. Write-LogEntry, Write-StatusInfo,
        Write-SuccessMessage, Write-WarningMessage and Write-ErrorMessage all route
        here; those five exist so call sites read naturally and so the level cannot be
        misspelled at the call site.

        Indicator, colors and CI annotation level all come from $script:LogStyles,
        keyed by -Level.

        Under GitHub Actions, levels whose style row carries an Annotation value also
        emit the matching workflow command, so warnings and errors appear in the run
        summary and PR UI rather than only in the log body. Local runs are unaffected.

    .PARAMETER Level
        One of: Log, Status, Success, Warning, Error.

    .PARAMETER Type
        Short label before the colon, for example 'Downloading' or 'FATAL'.

    .PARAMETER Message
        The message body.

    .EXAMPLE
        Write-Log -Level Status -Type 'Downloading' -Message 'mingw64.7z'
        # [>] Downloading: mingw64.7z

    .EXAMPLE
        Write-Log -Level Error -Type 'FATAL' -Message 'Inno Setup not found'
        # [X] FATAL: Inno Setup not found
        # and, in CI, also: ::error::FATAL: Inno Setup not found
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Log', 'Status', 'Success', 'Warning', 'Error')]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Type,
        [Parameter(Mandatory)]
        [string]$Message
    )

    $style = $script:LogStyles[$Level]

    Write-ColoredHost -Text " $($style.Indicator) " -ForegroundColor $style.IndicatorColor -NoNewline
    Write-ColoredHost -Text "$($Type): " -ForegroundColor $style.TypeColor -NoNewline
    Write-ColoredHost -Text $Message -ForegroundColor $style.MessageColor

    if ($script:IsGitHubActions -and $style.Annotation) {
        $annotationText = ConvertTo-GitHubAnnotationText "$($Type): $Message"
        Write-Host "::$($style.Annotation)::$annotationText"
    }
}

function Write-LogEntry {
    <#
    .SYNOPSIS
        Writes a general log line (" [-] Type: Message").
    .PARAMETER Type
        Short label before the colon.
    .PARAMETER Message
        The message body.
    .EXAMPLE
        Write-LogEntry -Type '7-Zip Path' -Message 'C:\Program Files\7-Zip\7z.exe'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Message
    )
    Write-Log -Level Log -Type $Type -Message $Message
}

function Write-StatusInfo {
    <#
    .SYNOPSIS
        Writes a status or progress line (" [>] Type: Message").
    .PARAMETER Type
        Short label before the colon.
    .PARAMETER Message
        The message body.
    .EXAMPLE
        Write-StatusInfo -Type 'Building' -Message 'EasyMinGW Installer v2026.08.01 (64-bit)'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Message
    )
    Write-Log -Level Status -Type $Type -Message $Message
}

function Write-SuccessMessage {
    <#
    .SYNOPSIS
        Writes a success line (" [+] Type: Message").
    .PARAMETER Type
        Short label before the colon.
    .PARAMETER Message
        The message body.
    .EXAMPLE
        Write-SuccessMessage -Type 'Downloaded' -Message 'mingw64.7z (198.40 MB)'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Message
    )
    Write-Log -Level Success -Type $Type -Message $Message
}

function Write-WarningMessage {
    <#
    .SYNOPSIS
        Writes a warning line (" [!] Type: Message").
    .DESCRIPTION
        In GitHub Actions this also emits a ::warning:: annotation, so the message
        appears in the run summary and, for a pull request, next to the diff.
    .PARAMETER Type
        Short label before the colon.
    .PARAMETER Message
        The message body.
    .EXAMPLE
        Write-WarningMessage -Type 'Changelog' -Message 'No previous tag found for comparison'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Message
    )
    Write-Log -Level Warning -Type $Type -Message $Message
}

function Write-ErrorMessage {
    <#
    .SYNOPSIS
        Writes an error line (" [X] ErrorType: Message").
    .DESCRIPTION
        The parameter is named -ErrorType rather than -Type for historical reasons;
        every call site in the build uses that name.

        In GitHub Actions this also emits an ::error:: annotation, so a failing run
        shows the reason in its summary instead of only in the log body. This is why
        the old Write-GitHubActionsError function no longer exists.
    .PARAMETER ErrorType
        Short error label, for example 'FATAL' or 'Build Failed'.
    .PARAMETER Message
        The error text.
    .EXAMPLE
        Write-ErrorMessage -ErrorType 'FATAL' -Message 'Required dependencies are missing.'
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$ErrorType,
        [Parameter(Mandatory)][string]$Message
    )
    Write-Log -Level Error -Type $ErrorType -Message $Message
}

function Write-SeparatorLine {
    <#
    .SYNOPSIS
        Writes a horizontal rule.
    .PARAMETER Character
        Character to repeat. Defaults to '-'.
    .PARAMETER Length
        Number of characters. Defaults to 50.
    .PARAMETER Color
        Console color. Defaults to DarkGray.
    .EXAMPLE
        Write-SeparatorLine -Character '=' -Length 60
    #>
    [CmdletBinding()]
    param(
        [string]$Character = '-',
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

function Write-UpdatingStatus {
    <#
    .SYNOPSIS
        Rewrites a styled status line in place (" [>] Type: Message").

    .DESCRIPTION
        Write-UpdatingLine's styled sibling. Same carriage-return redraw, but the
        indicator, label and message are coloured from $script:LogStyles exactly
        as Write-StatusInfo would, so a live-updating line is indistinguishable
        from a normal one once it stops moving.

        That is what lets a progress readout BE the status line instead of
        sitting under a static one that repeats what the caller already printed.

        Call End-UpdatingLine when finished, or the next write lands on this line.

        Under GitHub Actions there is no carriage-return support, so the line is
        written normally; callers should throttle or skip progress updates there
        or the log fills with near-identical lines.

    .PARAMETER Type
        Short label before the colon, for example 'Downloading'.

    .PARAMETER Message
        The message body, typically a changing value.

    .PARAMETER Level
        Style row to use. Defaults to Status.

    .PARAMETER LineClearLength
        Total width to pad to, so a shorter message fully overwrites a longer
        previous one. Padding is applied to the message segment only.

    .EXAMPLE
        Write-UpdatingStatus -Type 'Downloading' -Message '512KB / 108000KB (0%)'
        Write-UpdatingStatus -Type 'Downloading' -Message '108000KB / 108000KB (100%)'
        End-UpdatingLine
        # One line that counts up, ending as: [>] Downloading: 108000KB / 108000KB (100%)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Log', 'Status', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Status',
        [int]$LineClearLength = 78
    )

    $style = $script:LogStyles[$Level]

    if ($script:IsGitHubActions) {
        Write-Host " $($style.Indicator) $($Type): $Message" -ForegroundColor $style.MessageColor
        return
    }

    # Pad the message so a shorter readout overwrites a longer previous one. The
    # prefix is a fixed width, so only the tail needs padding.
    $prefixLength = 5 + $Type.Length + 2   # ' ' + '[>]' + ' ' + Type + ': '
    $pad = $LineClearLength - $prefixLength
    if ($pad -lt 0) { $pad = 0 }

    Write-Host -Object "`r" -NoNewline
    Write-ColoredHost -Text " $($style.Indicator) " -ForegroundColor $style.IndicatorColor -NoNewline
    Write-ColoredHost -Text "$($Type): " -ForegroundColor $style.TypeColor -NoNewline
    Write-ColoredHost -Text $Message.PadRight($pad) -ForegroundColor $style.MessageColor -NoNewline
}

function End-UpdatingLine {
    [CmdletBinding()]
    param()
    
    if (-not $script:IsGitHubActions) {
        Write-Host ''
    }
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
        if ($Config.OfflineMode)         { 'OFFLINE (no network)' }
        elseif ($Config.SkipDownload)    { 'TEST (fixtures, no download)' }
        elseif ($Config.IsGitHubActions) { 'GitHub Actions' }
        else                             { 'Normal' }
    ) -ValueColor $(if ($Config.OfflineMode -or $Config.SkipDownload) { 'Yellow' } else { 'Green' })

    # Active Flags. SkipDownload is omitted: the Mode line already states it.
    $flags = @()
    if ($Config.SkipBuild) { $flags += 'SkipBuild' }
    if ($Config.SkipChangelog) { $flags += 'SkipChangelog' }
    if ($Config.SkipHashes) { $flags += 'SkipHashes' }
    if ($Config.GenerateLogsAlways) { $flags += 'GenerateLogsAlways' }

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
        # Not '{0:mm}m {0:ss}s': that drops hours and shows minutes modulo 60.
        $durationStr = if ($Duration.TotalHours -ge 1) {
            '{0}h {1:00}m {2:00}s' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds
        }
        else {
            '{0}m {1:00}s' -f $Duration.Minutes, $Duration.Seconds
        }
        Write-StatusInfo -Type 'Duration' -Message $durationStr
    }

    Write-SeparatorLine -Character '=' -Length 60
}