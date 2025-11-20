# Automated Emulator Manifest Creation

This guide explains how to use the automated manifest creation system for adding new emulators to the Scoop Emulators bucket.

## Overview

The system provides two ways to create manifests:

1. **Direct URL Creation** - Run the script directly with a GitHub repository URL
2. **GitHub Issue Processing** - Create an issue requesting an emulator, and the system automatically creates the manifest

## Method 1: Direct URL Creation

### Basic Usage

```powershell
.\bin\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/owner/repo"
```

### What It Does

1. **Fetches Repository Information**
   - Extracts latest release version, assets, and metadata from GitHub API
   - Retrieves license information (SPDX identifier)

2. **Finds Windows Executable**
   - Prefers standalone .exe files
   - Falls back to .zip archives
   - Extracts and detects executables if needed

3. **Downloads and Tests**
   - Downloads the selected asset
   - Extracts archives if necessary
   - Monitors file system changes during execution to detect created directories/files

4. **Detects Platform**
   - Automatically identifies the emulator platform (N64, GameCube, PS2, etc.)
   - Uses repository name and description for detection

5. **Creates Manifest**
   - Generates JSON manifest with all required fields
   - Includes portable.txt for portable mode
   - Creates shortcuts with platform-specific names
   - Configures automatic version checking and updates
   - Sets up data migration from AppData/Documents

6. **Validates**
   - Saves manifest to `bucket/` directory
   - Provides instructions for manual validation

### Example

```powershell
# Create manifest for gopher64
.\bin\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/gopher64/gopher64"
```

### Output

The script will:
- Create `bucket/gopher64.json` with all configurations
- Provide validation commands to run
- Show the detection results (platform, version, etc.)

## Method 2: GitHub Issue Processing

### Creating a Request Issue

1. Go to https://github.com/borger/scoop-emulators/issues
2. Click "New Issue"
3. Include the GitHub repository URL in the issue title or body:
   ```
   Title: Add gopher64 emulator
   Body: Please add https://github.com/gopher64/gopher64
   ```
4. Add the label `request-manifest` or `emulator-request`
5. Submit the issue

### Automatic Processing

The system monitors for issues with specific labels and automatically:

1. Detects the GitHub URL from the issue
2. Runs the manifest creation script
3. Updates the issue with results
4. Adds "emulator-added" label on success

### For GitHub Actions

The issue handler can be integrated into GitHub Actions:

```yaml
name: Handle Manifest Requests

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

## Manifest Features

### Post-Install Script
- Automatically creates `portable.txt` to enable portable mode
- Game data stored in the application directory instead of roaming profile

### Pre-Install Script
- Migrates existing emulator data from:
  - `%APPDATA%\[emulator-name]`
  - `%USERPROFILE%\Documents\[emulator-name]`
- Copies to portable_data directory for centralized storage

### Persist Configuration
- `portable_data` - Emulator game data and settings
- Auto-detected directories from runtime monitoring
- Preserved across application updates

### Shortcuts
- Creates Start Menu shortcut with platform-specific name
- Format: `[Platform] [emu]`
- Example: `Nintendo 64 [n64][g64]`

### Version Management
- Automatic checkver configuration via GitHub API
- Autoupdate template with `$version` and `$sha256` placeholders
- Supports pre-release detection

## Platform Detection

The script auto-detects common emulator platforms:

- **Nintendo**: 64, GameCube/Wii, Wii U, Switch, 3DS, DS, Game Boy/Color, Super Nintendo
- **PlayStation**: 1, 2, 3, Portable
- **Sega**: Genesis, Dreamcast
- **Microsoft**: Xbox, Xbox 360
- **Arcade**: MAME
- **Multi-System**: RetroArch and similar

## Manual Validation

After creation, validate the manifest:

```powershell
# Test version detection
.\bin\checkver.ps1 -Dir bucket -App gopher64

# Validate autoupdate configuration
.\bin\check-autoupdate.ps1 -ManifestPath bucket\gopher64.json

# Test actual installation
.\bin\check-manifest-install.ps1 -ManifestPath bucket\gopher64.json
```

## Troubleshooting

### "No suitable Windows executable found"

The script couldn't find a Windows binary. The repository might:
- Not have Windows releases
- Use different naming convention
- Require manual build

**Solution**: Create the manifest manually or open an issue for manual review

### "No GitHub repository URL found"

When using GitHub issues, the URL couldn't be extracted.

**Solution**: Ensure the GitHub URL is formatted as `https://github.com/owner/repo`

### Application won't start for monitoring

The executable couldn't be launched during the monitoring phase.

**Solution**: Manually review the application or provide alternative download format

### Manifest validation fails

**Solution**:
1. Review the manifest at `bucket/[app-name].json`
2. Check error messages from validation scripts
3. Use `.\bin\autofix-manifest.ps1` for automatic repairs

## Advanced Usage

### Skip Confirmation Prompts

```powershell
.\bin\create-emulator-manifest.ps1 -GitHubUrl "..." -AutoApprove
```

### Dry Run Mode (GitHub Issues)

```powershell
.\bin\handle-issue.ps1 -IssueNumber 123 -GitHubToken "..." -DryRun
```

### Process Multiple Issues

The handle-issue script can automatically find and process all open request issues:

```powershell
.\bin\handle-issue.ps1 -GitHubToken "..."
```

## Generated Manifest Structure

```json
{
    "version": "1.1.10",
    "description": "Nintendo 64 Emulator",
    "homepage": "https://github.com/gopher64/gopher64",
    "license": {
        "identifier": "GPL-3.0",
        "url": "https://raw.githubusercontent.com/gopher64/gopher64/main/LICENSE"
    },
    "architecture": {
        "64bit": {
            "url": "https://github.com/.../gopher64-windows-x86_64.exe",
            "hash": "sha256:..."
        }
    },
    "post_install": [
        "Add-Content -Path \"$dir\\portable.txt\" -Value '' -Encoding UTF8"
    ],
    "bin": "gopher64-windows-x86_64.exe",
    "shortcuts": [
        ["gopher64-windows-x86_64.exe", "Nintendo 64 [n64][g64]"]
    ],
    "persist": ["portable_data"],
    "pre_install": "# Data migration script",
    "checkver": {
        "github": "https://github.com/gopher64/gopher64"
    },
    "autoupdate": {
        "architecture": {
            "64bit": {
                "url": "https://github.com/.../v$version/gopher64-windows-x86_64.exe",
                "hash": "sha256|$sha256"
            }
        }
    }
}
```

## Tips for Best Results

1. **Clean Test Environment**
   - Run on a fresh system without the emulator installed
   - Ensures proper data migration detection

2. **App Interaction**
   - Close the application when prompted
   - Allows proper file system monitoring completion

3. **Review Results**
   - Check detected platform accuracy
   - Verify persist items match actual emulator data locations

4. **Validation**
   - Always run validation tests before committing
   - Fixes issues early in the process

## Contributing

When submitting manifests created with this tool:

1. Run all validation tests
2. Review the JSON for accuracy
3. Test on a clean system if possible
4. Submit PR with proper commit message format: `feat(app-name): add manifest`

---

For issues or improvements to the automation system, open an issue on the bucket repository.
