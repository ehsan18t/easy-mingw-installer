# Contributing to Easy MinGW Installer

Thank you for your interest in contributing! This document provides an overview of the codebase architecture and guidelines for contributors.

## 📁 Project Structure

```
easy-mingw-installer/
├── Builder.ps1                 # Main entry point - orchestrates the entire build
├── MinGW_Installer.iss         # Inno Setup script - defines the Windows installer
├── run.bat                     # Batch wrapper for easy local builds
├── README.md                   # User-facing documentation
├── LICENSE                     # Project license
│
├── modules/                    # PowerShell modules
│   ├── config.ps1              # Centralized configuration management
│   ├── functions.ps1           # Core business logic (API, downloads, builds)
│   ├── pretty.ps1              # Logging and formatted console output
│   └── generate_changelog.py   # Python script for changelog generation
│
├── inno/                       # Inno Setup include files
│   └── Environment.iss         # PATH environment variable helpers
│
└── assets/                     # Static assets
    └── src/                    # Source assets (icons, etc.)
```

## 🏗️ Architecture Overview

### Build Pipeline Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           BUILD PIPELINE FLOW                               │
└─────────────────────────────────────────────────────────────────────────────┘

    run.bat (optional wrapper)
              │
              ▼
     ┌─────────────────┐
     │   Builder.ps1   │  ◄─── Entry point, parameter handling
     └────────┬────────┘
              │
    ┌─────────┴─────────┐
    │   Load Modules    │
    ├───────────────────┤
    │  • pretty.ps1     │  ◄─── Logging/output formatting
    │  • config.ps1     │  ◄─── Configuration management  
    │  • functions.ps1  │  ◄─── Core build functions
    └─────────┬─────────┘
              │
    ┌─────────┴─────────┐
    │     Initialize    │
    ├───────────────────┤
    │  • Parse params   │
    │  • Find tools     │
    │  • Validate deps  │
    └────────┬──────────┘
             │
    ┌────────┴──────────┐
    │  Version Check    │
    ├───────────────────┤
    │  • Fetch latest   │
    │    WinLibs ver    │
    │  • Compare tags   │
    └────────┬──────────┘
             │
     ┌───────┴───────┐
     │  For each     │
     │  architecture │
     └───────┬───────┘
             │
    ┌────────┴─────────┐
    │     Download     │
    ├──────────────────┤
    │  • Find asset    │
    │  • Download .7z  │
    │  • Extract       │
    └────────┬─────────┘
             │
    ┌────────┴────────┐
    │    Changelog    │
    ├─────────────────┤
    │  • Parse pkgs   │
    │  • Compare vers │
    │  • Generate MD  │
    └────────┬────────┘
             │
    ┌────────┴──────────┐
    │  Build Installer  │
    ├───────────────────┤
    │  • Run ISCC.exe   │
    │  • Generate EXE   │
    │  • Create hashes  │
    └────────┬──────────┘
             │
    ┌────────┴──────────┐
    │      Finalize     │
    ├───────────────────┤
    │  • Append hashes  │
    │  • Cleanup temp   │
    │  • Show summary   │
    └───────────────────┘
```

## 📦 Module Details

### Builder.ps1 (Entry Point)

The main script that orchestrates the build. Key responsibilities:
- Parameter parsing and validation
- Module loading
- Build mode detection (normal, test, offline)
- Architecture iteration
- Error handling and cleanup

**Key Parameters:**
- `-Archs` - Target architectures ("64", "32", or both)
- `-SkipDownload` - Use fixtures instead of downloading; the release lookup,
  changelog and installer build all still run
- `-OfflineMode` - No network requests at all; implies `-SkipDownload` and no changelog
- `-CheckNewRelease` - Skip the build if the project's latest tag already matches
- `-SkipBuild`, `-SkipChangelog`, `-SkipHashes` - Granular step control
- `-CleanFirst` - Remove the temp directory and any stale release notes
- `-GenerateLogsAlways` - Write the Inno Setup log even on success

### modules/config.ps1 (Configuration)

Centralized configuration with a layered approach:

```
Priority (highest to lowest):
1. Runtime parameter overrides
2. Environment variables (EMI_*)
3. Default values
```

**Key Functions:**
| Function                 | Purpose                                 |
| ------------------------ | --------------------------------------- |
| `Get-BuildConfig`        | Returns cached configuration object     |
| `Initialize-BuildConfig` | Sets up config with overrides           |
| `Test-BuildDependencies` | Validates 7-Zip/Inno Setup availability |
| `Find-Tool`              | Locates an executable (env var, then Program Files) |
| `Find-Python`            | Locates a working Python interpreter    |

**Environment Variables:**
| Variable             | Description                       |
| -------------------- | --------------------------------- |
| `EMI_LOG_LEVEL`      | Verbosity: Verbose, Normal, Quiet |
| `EMI_7ZIP_PATH`      | Custom 7-Zip path                 |
| `EMI_INNOSETUP_PATH` | Custom Inno Setup path            |
| `EMI_PYTHON_PATH`    | Custom Python interpreter path    |
| `EMI_PROJECT_OWNER`  | GitHub owner for this repo        |
| `EMI_PROJECT_REPO`   | GitHub repo name                  |

### modules/functions.ps1 (Core Logic)

Contains all business logic organized into categories:

#### Process Management
```powershell
Register-ChildProcess      # Track spawned process for cleanup
Stop-AllChildProcesses     # Kill all on Ctrl+C
Clear-ChildProcesses       # Clear tracking after normal completion
Test-BuildCancelled        # Query cancellation state
Set-BuildCancelled         # Mark build as cancelled
Invoke-CancellationCleanup # Full cleanup on cancellation
Invoke-Tool                # Run an external tool as a tracked child process
```

#### GitHub API
```powershell
Invoke-GitHubApi          # Cached API requests
Get-GitHubTags            # Get the N most recent tags, newest first
Find-GitHubRelease        # Find release by title pattern
```

#### Downloads & Extraction
```powershell
Invoke-FileDownload       # Download with retry and progress
Expand-7ZipArchive        # Extract using 7-Zip
```

#### Build Functions
```powershell
Invoke-InstallerBuild     # Run Inno Setup compiler
Invoke-HashGeneration     # Generate CRC32/64, SHA1/256/384/512, SHA3-256,
                          # BLAKE2sp, MD5, XXH64 via a single 7-Zip pass
Invoke-ArchitectureBuild  # Complete pipeline for one arch
```

### modules/pretty.ps1 (Output Formatting)

Provides consistent, colored console output. All five levels route through
`Write-Log`, which reads indicator, colors and CI annotation level from one table.

```
 [-] LogEntry:    Standard log message
 [>] StatusInfo:  Status/progress updates
 [+] Success:     Successful operations
 [!] Warning:     Warnings
 [X] Error:       Error messages
```

Every level has a distinct indicator, so a log can be filtered by severity without
relying on color. `modules/generate_changelog.py` uses the same prefixes, so Python
and PowerShell output are indistinguishable in a combined log.

**GitHub Actions Integration:**
- Automatically detects CI via `$env:GITHUB_ACTIONS`
- Warning and Error additionally emit `::warning::` and `::error::`, so they appear
  in the run summary and PR UI rather than only in the log body
- Disables carriage-return line updates, which CI logs do not render

### modules/generate_changelog.py (Changelog)

Python script that:
1. Parses `version_info.txt` for current packages
2. Fetches previous release from GitHub
3. Compares package versions
4. Generates Markdown changelog with:
   - Package additions/updates/removals
   - Thread model and runtime info
   - Full changelog link

## 🔧 Development Setup

### Prerequisites

1. **PowerShell 5.1+** (included in Windows 10+)
2. **7-Zip** - [Download](https://7-zip.org/)
3. **Inno Setup 6.6.0 or later** - [Download](https://jrsoftware.org/isdl.php).
   Not optional and not "6 or later": `MinGW_Installer.iss` sets
   `WizardStyle=modern dynamic`, and the `dynamic` appearance mode that follows
   the Windows light/dark setting was added in 6.6.0. The script checks this and
   fails the compile with a clear message on anything older.
4. **Python 3.8+** with `requests` (for changelog generation). Either `python` or
   the `py` launcher works; the Windows installer leaves "Add python.exe to PATH"
   unchecked by default, so a stock install provides only `py`. Install the
   dependency with `py -m pip install requests`.

### Quick Start

```powershell
# Clone the repository
git clone https://github.com/ehsan18t/easy-mingw-installer.git
cd easy-mingw-installer

# Run a build without the 200MB download
.\Builder.ps1 -SkipDownload

# Run a full build
.\Builder.ps1

# Or use the batch wrapper
.\run.bat
```

### Build Modes

Two switches control how the build sources its MinGW payload.

| Invocation | Network | Payload | Changelog | Use for |
| --- | --- | --- | --- | --- |
| `.\Builder.ps1` | full | real download | yes | a real release |
| `.\Builder.ps1 -SkipDownload` | full | fixtures | yes | everything except the 200MB transfer |
| `.\Builder.ps1 -OfflineMode` | none | fixtures | no | verifying the Inno Setup script offline |

`-SkipDownload` is the normal development mode. It resolves a real WinLibs release,
matches the real asset name (so a broken `-NamePatterns` still fails), generates a
real changelog against the previous tag, and compiles a real installer around
generated fixture files. Only the transfer is skipped.

Both fixture modes keep the temp directory so the generated tree can be inspected.
The resulting installer is a structural test artifact, not a usable toolchain.

## 📝 Coding Guidelines

### PowerShell Style

1. **Use comment-based help** for all functions:
   ```powershell
   function Do-Something {
       <#
       .SYNOPSIS
           Brief description.
       .DESCRIPTION
           Detailed description.
       .PARAMETER Name
           Parameter description.
       .EXAMPLE
           Usage example.
       #>
       [CmdletBinding()]
       param(...)
   }
   ```

2. **Use approved verbs** for function names (Get-, Set-, Invoke-, New-, etc.)

3. **Always use `[CmdletBinding()]`** for advanced function features

4. **Handle errors gracefully** with try/catch and meaningful messages

5. **Use the logging functions** from pretty.ps1:
   ```powershell
   Write-StatusInfo -Type 'Action' -Message 'Doing something...'
   Write-SuccessMessage -Type 'Done' -Message 'Operation completed'
   Write-ErrorMessage -ErrorType 'FATAL' -Message 'Something failed'
   ```

### Configuration

- Add new settings to `config.ps1` with sensible defaults
- Support environment variable overrides where appropriate
- Document all configuration properties
- Build logs go to `$cfg.LogDirectory` (`<repo>/logs`), never inside `OutputPath`.
  Everything in `OutputPath` is uploaded as a GitHub Release asset.

### Testing Changes

1. Always test with `-SkipDownload` first
2. Test both 32-bit and 64-bit builds
3. Verify GitHub Actions compatibility by checking CI runs
4. Test cancellation (Ctrl+C) to ensure cleanup works

## 🔄 Pull Request Process

1. **Fork** the repository
2. Create a **feature branch** from `main`
3. Make your changes with clear commits
4. Update documentation if needed
5. Test thoroughly
6. Submit a **pull request** with:
   - Clear description of changes
   - Any breaking changes noted
   - Screenshots if UI-related

## 🐛 Reporting Issues

When reporting bugs, please include:
- PowerShell version (`$PSVersionTable.PSVersion`)
- Windows version
- 7-Zip version
- Inno Setup version
- Full error output
- Steps to reproduce

## 📚 Additional Resources

- [WinLibs Project](https://github.com/brechtsanders/winlibs_mingw) - Source of MinGW packages
- [Inno Setup Documentation](https://jrsoftware.org/ishelp/)
- [PowerShell Documentation](https://docs.microsoft.com/powershell/)
- [7-Zip Command Line](https://www.7-zip.org/7z.html)

## 📄 License

By contributing, you agree that your contributions will be licensed under the same license as the project.
