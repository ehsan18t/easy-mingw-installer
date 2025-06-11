[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$FilePath,

    [Parameter(Mandatory=$false)]
    [string]$SevenZipExePath = "C:\Program Files\7-Zip\7z.exe" # Assumes 7z.exe is in PATH or provide full path
)

# Validate FilePath
if (-not (Test-Path $FilePath -PathType Leaf)) {
    Write-Error "File not found or is not a file: $FilePath"
    exit 1
}

# Validate 7-Zip Path
if (-not (Get-Command $SevenZipExePath -ErrorAction SilentlyContinue)) {
    Write-Error "7-Zip executable not found at '$SevenZipExePath'. Ensure it's in your PATH or provide the correct path."
    exit 1
}

$fileName = [System.IO.Path]::GetFileName($FilePath)
$fileSizeBytes = ""
$fileSizeHuman = ""

$hashes = [ordered]@{
    "CRC32"    = ""
    "CRC64"    = ""
    "SHA256"   = ""
    "SHA1"     = ""
    "BLAKE2sp" = ""
    "MD5"      = ""
    "XXH64"    = ""
    "SHA384"   = ""
    "SHA512"   = ""
    "SHA3-256" = ""
}

try {
    # Execute 7-Zip and capture output
    # The -scrc* switch is crucial for getting all hash types if supported by your 7z version.
    $sevenZipOutput = & $SevenZipExePath h -scrc* $FilePath 2>&1
}
catch {
    Write-Error "Error executing 7-Zip: $($_.Exception.Message)"
    exit 1
}

# Process each line of the 7-Zip output
foreach ($line in $sevenZipOutput) {
    # Extract file size information
    # Example line: "1 file, 706412 bytes (689 KiB)"
    if ($line -match '^\d+\s+file(?:s)?,\s*(\d+)\s*bytes\s*\(([^)]+)\)') {
        $fileSizeBytes = $matches[1]
        $fileSizeHuman = $matches[2]
    }

    # Extract hashes
    # Example line: "CRC32  for data:              4E068660"
    if ($line -match '^([A-Z0-9-]+)\s+for data:\s+([A-Fa-f0-9]+)') {
        $hashName = $matches[1].ToUpper()
        $hashValue = $matches[2]
        if ($hashes.Contains($hashName)) {
            $hashes[$hashName] = $hashValue
        }
    }
}

# Output in the desired format using Write-Output (which can be captured)
Write-Output "Name: $fileName"
if ($fileSizeBytes -and $fileSizeHuman) {
    Write-Output "Size: $fileSizeBytes bytes : $fileSizeHuman"
} elseif ($fileSizeBytes) { # Fallback if human readable size wasn't parsed
    Write-Output "Size: $fileSizeBytes bytes"
}

Write-Output "CRC32: $($hashes['CRC32'])"
Write-Output "CRC64: $($hashes['CRC64'])"
Write-Output "SHA256: $($hashes['SHA256'])"
Write-Output "SHA1: $($hashes['SHA1'])"
Write-Output "BLAKE2sp: $($hashes['BLAKE2sp'])"
Write-Output "MD5: $($hashes['MD5'])"
Write-Output "XXH64: $($hashes['XXH64'])"
Write-Output "SHA384: $($hashes['SHA384'])"
Write-Output "SHA512: $($hashes['SHA512'])"
Write-Output "SHA3-256: $($hashes['SHA3-256'])"