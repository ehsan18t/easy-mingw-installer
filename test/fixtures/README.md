# Test Fixtures Directory

This directory contains minimal test fixtures used by the Easy MinGW Installer build system when running in test mode.

## Contents

- `dummy.exe` - A minimal executable file (1KB placeholder) used when Inno Setup needs actual files to package during test builds.

## Purpose

When running `Builder.ps1 -TestMode`, the build system:

1. Skips downloading actual MinGW archives from WinLibs
2. Creates test fixtures with minimal dummy files
3. Allows Inno Setup to complete without errors
4. Enables local testing of the build pipeline without network access

## Regenerating dummy.exe

If you need to regenerate the dummy executable:

```powershell
# Creates a minimal 1KB file of zeros
$bytes = New-Object byte[] 1024
[System.IO.File]::WriteAllBytes("test\fixtures\dummy.exe", $bytes)
```

## Usage

The `Initialize-TestFixtures` function in `modules/functions.ps1` automatically uses these fixtures when running in test mode.
