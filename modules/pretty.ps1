$colors = @{
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
function Write-Color($Text, $Color, [switch]$NoNewline) {
    if ($NoNewline) {
        Write-Host -NoNewline $Text -ForegroundColor $Color
    } else {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Write-Text {
    param (
        [string]$Indicator = ">>",
        [string]$Type,
        [string]$Message,
        $IndicatorColor = $colors.White,
        $TypeColor = $colors.White,
        $MessageColor = $colors.DarkCyan
    )

    Write-Color " $Indicator " $IndicatorColor -NoNewline
    Write-Color "$($Type): " $TypeColor -NoNewline
    Write-Color "$Message" $MessageColor
}

function Write-Log {
    param (
        [string]$Type,
        [string]$Message,
        $TypeColor = $colors.White,
        $MessageColor = $colors.DarkCyan
    )

    Write-Text "->" $Type $Message $colors.Blue $TypeColor $MessageColor
}

function Write-Info {
    param (
        [string]$Type,
        [string]$Message,
        $TypeColor = $colors.White,
        $MessageColor = $colors.Yellow
    )

    Write-Text ">>" $Type $Message $colors.Magenta $TypeColor $MessageColor
}

function Write-Warnings {
    param (
        [string]$Type,
        [string]$Message,
        $TypeColor = $colors.DarkYellow,
        $MessageColor = $colors.DarkRed
    )

    Write-Text ">>" $Type $Message $colors.Red $TypeColor $MessageColor
}

function Write-Actions {
    param (
        [string]$Type,
        [string]$Message,
        $TypeColor = $colors.White,
        $MessageColor = $colors.Yellow
    )

    Write-Color " >> " $colors.DarkYellow -NoNewline
    Write-Color "$($Type) " $TypeColor -NoNewline
    Write-Color "$Message" $MessageColor
}

function Write-Error {
    param (
        [string]$Type,
        [string]$Message,
        [string]$logs,
        [int]$exitCode = 0,
        $TypeColor = $colors.DarkRed,
        $MessageColor = $colors.Red
    )

    Write-Color " >> $($Type): " $TypeColor -NoNewline
    Write-Color "$Message" $MessageColor

    if ($exitCode -ne 0) {
        Write-Color "    EXIT CODE: " $colors.DarkRed -NoNewline
        Write-Color $exitCode $colors.Cyan
    }

    if ($logs) {
        Write-Color " >> " $colors.DarkYellow -NoNewline
        Write-Color "Check the log file for details: " $colors.Yellow -NoNewline
        Write-Color $logs $colors.Cyan
    }
}