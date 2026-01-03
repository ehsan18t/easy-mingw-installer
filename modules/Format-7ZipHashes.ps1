<#
.SYNOPSIS
    Generates multiple hash digests for a file using 7-Zip's hash command.

.DESCRIPTION
    This script leverages 7-Zip's built-in hash functionality to generate a
    comprehensive set of cryptographic hashes for a given file. The output is
    formatted in a human-readable format suitable for inclusion in release notes.
    
    7-Zip's hash command (7z h) can compute many hash algorithms simultaneously,
    which is more efficient than running multiple hash utilities.
    
    GENERATED HASHES:
    ┌────────────┬──────────────────────────────────────────────────────────────┐
    │  Algorithm │  Description                                                 │
    ├────────────┼──────────────────────────────────────────────────────────────┤
    │  CRC32     │  Standard 32-bit cyclic redundancy check                     │
    │  CRC64     │  Extended 64-bit CRC (ECMA-182 polynomial)                   │
    │  SHA256    │  SHA-2 256-bit (recommended for integrity verification)      │
    │  SHA1      │  SHA-1 160-bit (legacy, not for security)                    │
    │  BLAKE2sp  │  BLAKE2s parallel, very fast on multi-core                   │
    │  MD5       │  MD5 128-bit (legacy, not for security)                      │
    │  XXH64     │  xxHash 64-bit, extremely fast non-crypto hash               │
    │  SHA384    │  SHA-2 384-bit                                               │
    │  SHA512    │  SHA-2 512-bit                                               │
    │  SHA3-256  │  SHA-3 256-bit (Keccak)                                      │
    └────────────┴──────────────────────────────────────────────────────────────┘
    
    OUTPUT FORMAT:
    The script outputs in a simple "Key: Value" format:
    
        Name: EasyMinGW.Installer.v2024.01.15.64-bit.exe
        Size: 123456789 bytes : 117.7 MiB
        CRC32: 4E068660
        SHA256: ABC123...
        (etc.)
    
    This output is typically redirected to a .hashes.txt file alongside the
    installer, and also appended to the changelog for release notes.

.PARAMETER FilePath
    The full path to the file to hash. Must be an existing file.

.PARAMETER SevenZipExePath
    Path to the 7-Zip executable (7z.exe). Defaults to the standard
    Program Files installation location.

.OUTPUTS
    String output containing formatted hash information. Use Out-File or
    Set-Content to save to a file.

.EXAMPLE
    .\Format-7ZipHashes.ps1 -FilePath "C:\Builds\Installer.exe"
    # Outputs hash information to console

.EXAMPLE
    .\Format-7ZipHashes.ps1 -FilePath ".\output\EasyMinGW.exe" | Out-File "hashes.txt"
    # Saves hash information to a file

.EXAMPLE
    # Called from functions.ps1:
    & $hashScript -FilePath $exePath -SevenZipExePath $cfg.SevenZipPath | 
        Out-File $hashFile -Encoding utf8

.NOTES
    File Name      : Format-7ZipHashes.ps1
    Location       : modules/Format-7ZipHashes.ps1
    Prerequisite   : 7-Zip 19.00 or later (for all hash algorithms)
    
    The -scrc* switch tells 7-Zip to calculate all supported hash types.
    Older versions of 7-Zip may not support all hash algorithms.

.LINK
    https://7-zip.org/
    https://www.7-zip.org/7z.html
#>

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