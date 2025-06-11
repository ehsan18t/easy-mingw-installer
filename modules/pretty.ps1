$script:colors = @{ # Using script scope explicitly for clarity
    Black        = "Black"
    DarkBlue     = "DarkBlue"
    DarkGreen    = "DarkGreen"
    DarkCyan     = "DarkCyan"
    DarkRed      = "DarkRed"
    DarkMagenta  = "DarkMagenta"
    DarkYellow   = "DarkYellow"
    Gray         = "Gray"
    DarkGray     = "DarkGray"
    Blue         = "Blue"
    Green        = "Green"
    Cyan         = "Cyan"
    Red          = "Red"
    Magenta      = "Magenta"
    Yellow       = "Yellow"
    White        = "White"
}

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
        # This length is used to pad the string with spaces, ensuring that
        # shorter subsequent messages clear out longer previous messages on the same line.
        # Adjust if your typical progress messages are longer.
        [int]$LineClearLength = 78 # One less than typical 80-char width to be safe
    )
    # Prepend carriage return, then the text padded with spaces to clear the previous line.
    $lineContent = "`r$($Text.PadRight($LineClearLength))"
    Write-Host -Object $lineContent -NoNewline -ForegroundColor $ForegroundColor
}

function End-UpdatingLine {
    [CmdletBinding()]
    param()
    Write-Host "" # Just print a newline to move to the next line
}