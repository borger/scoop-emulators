# Automated Emulator Manifest System

## Overview

This system automates the creation of emulator manifests for the Scoop Emulators bucket. It eliminates manual configuration by:

- Automatically detecting emulator platforms (N64, PS2, GameCube, etc.)
- Creating complete JSON manifests with proper configurations
- Setting up portable mode for local game storage
- Migrating data from AppData/Documents automatically
- Handling version updates and autoupdate configurations

## Quick Start

### For Users: Request an Emulator

1. Go to [GitHub Issues](https://github.com/borger/scoop-emulators/issues)
2. Create a new issue with:
   - Label: `request-manifest`
   - Include a GitHub repository URL

The system will automatically create the manifest and update your issue!

### For Developers: Create a Manifest

```powershell
.\bin\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/gopher64/gopher64"
```

That's it! The script will:
- Download the latest release
- Test the application
- Detect the platform
- Generate a complete manifest

## Features

✅ **Automatic Platform Detection**
- Recognizes 20+ emulator types
- Generates platform-specific shortcuts

✅ **Portable Mode Support**
- Creates portable.txt on install
- Stores game data with the application

✅ **Data Migration**
- Migrates from AppData/Documents
- Centralizes data in portable_data directory

✅ **Version Management**
- Automatic version checking via GitHub
- Autoupdate with hash calculation

✅ **Runtime Monitoring**
- Detects files created during execution
- Automatically includes in persist configuration

✅ **GitHub Integration**
- Process manifest requests via issues
- Updates issues with results

## Files Included

### Scripts
- **`bin/create-emulator-manifest.ps1`** - Main automation script (588 lines)
- **`bin/handle-issue.ps1`** - Enhanced with manifest request detection

### Documentation
- **`QUICKSTART.md`** - Get started in 10 minutes
- **`MANIFEST_CREATION.md`** - Comprehensive feature guide
- **`AUTOMATION_SUMMARY.md`** - System overview
- **`IMPLEMENTATION_NOTES.md`** - Technical details
- **`DOCS_INDEX.md`** - Documentation roadmap

## Usage Examples

### Create from GitHub URL
```powershell
.\bin\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/gopher64/gopher64"
```

### Create from GitHub Issue
```powershell
.\bin\create-emulator-manifest.ps1 -IssueNumber 42 -GitHubToken "ghp_token"
```

### Skip Confirmation Prompts
```powershell
.\bin\create-emulator-manifest.ps1 -GitHubUrl "..." -AutoApprove
```

## What Gets Created

A complete manifest with:
- ✅ Version information
- ✅ Platform-specific description
- ✅ License information
- ✅ Windows executable/archive
- ✅ SHA256 hash
- ✅ Post-install portable mode setup
- ✅ Pre-install data migration
- ✅ Platform-specific shortcuts
- ✅ Automatic version checking
- ✅ Autoupdate configuration

## GitHub Actions Integration

Add to `.github/workflows/manifest-requests.yml`:

```yaml
name: Create Manifest from Issue

on:
  issues:
    types: [opened, labeled]

jobs:
  create-manifest:
    runs-on: windows-latest
    if: contains(github.event.issue.labels.*.name, 'request-manifest')

    steps:
      - uses: actions/checkout@v3

      - name: Create Manifest
        shell: pwsh
        run: |
          .\bin\create-emulator-manifest.ps1 `
            -IssueNumber ${{ github.event.issue.number }} `
            -GitHubToken ${{ secrets.GITHUB_TOKEN }}
```

## Supported Emulator Platforms

The system auto-detects:

**Nintendo**
- N64 (gopher64, mupen64)
- GameCube/Wii (dolphin)
- Wii U (cemu)
- Switch (yuzu, ryujinx)
- 3DS (citra)
- DS (melonds)
- Game Boy (sameboy, visualboyadvance)
- Super Nintendo (snes9x, bsnes)

**Sony**
- PlayStation 1 (duckstation, pcsx)
- PlayStation 2 (pcsx2)
- PlayStation 3 (rpcs3)
- PlayStation Portable (ppsspp)

**Other**
- Sega Genesis, Dreamcast (flycast, redream)
- Microsoft Xbox, Xbox 360 (xenia)
- Arcade (MAME)
- Multi-system (RetroArch)

## Next Steps

1. **Read the Docs**
   - Start with [QUICKSTART.md](QUICKSTART.md)
   - Full guide: [MANIFEST_CREATION.md](MANIFEST_CREATION.md)

2. **Set Up GitHub Actions** (optional)
   - Automatically process issues
   - Enable manifest requests

3. **Start Creating Manifests**
   - Request via issues
   - Or run script directly

4. **Validate and Deploy**
   - Run validation tests
   - Commit to main
   - Automatic merge on success

## Documentation

- 📖 [QUICKSTART.md](QUICKSTART.md) - Quick reference for all users
- 📘 [MANIFEST_CREATION.md](MANIFEST_CREATION.md) - Complete feature guide
- 📋 [AUTOMATION_SUMMARY.md](AUTOMATION_SUMMARY.md) - System overview
- 🔧 [IMPLEMENTATION_NOTES.md](IMPLEMENTATION_NOTES.md) - Technical details
- 🗺️ [DOCS_INDEX.md](DOCS_INDEX.md) - Documentation roadmap

## System Benefits

✨ **Time Saving**
- Manifest creation in 5-10 minutes
- Automatic testing and validation

📦 **Consistency**
- All manifests follow same structure
- Standard configurations across bucket

🎮 **User-Friendly**
- Portable mode by default
- Automatic data migration
- Clean installation experience

🔄 **Maintainable**
- Automatic version updates
- Hash auto-calculation
- GitHub-based change tracking

🤝 **Community Friendly**
- Users can request emulators via issues
- No need for user technical knowledge
- Transparent automation

## Requirements

- Windows 11 or later
- PowerShell 5.1 or 7.x
- GitHub API access (for GitHub-based features)
- Git (for committing manifests)

## Support

For help:

1. Check [QUICKSTART.md](QUICKSTART.md)
2. Review [DOCS_INDEX.md](DOCS_INDEX.md) for relevant documentation
3. See troubleshooting section in [MANIFEST_CREATION.md](MANIFEST_CREATION.md)
4. Open an issue on GitHub

## Status

✅ **Production Ready**

- Fully implemented and tested
- Comprehensive documentation provided
- Ready for immediate use
- Integration with GitHub Actions ready

## License

GPLv2 (same as bucket)

---

**Ready to add emulators?** Start with [QUICKSTART.md](QUICKSTART.md) 👈
