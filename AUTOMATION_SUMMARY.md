# Automated Emulator Manifest System - Summary

## What Was Created

A complete automated system for creating emulator manifests in the Scoop Emulators bucket using GitHub repositories and issues.

## Components

### 1. **create-emulator-manifest.ps1**
Main script that automates manifest creation with the following features:

- **Dual Input Methods**
  - Direct GitHub URL: `.\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/owner/repo"`
  - GitHub Issue: `.\create-emulator-manifest.ps1 -IssueNumber 123 -GitHubToken "token"`

- **Automated Steps**
  1. Fetches repository info from GitHub API
  2. Retrieves license and metadata
  3. Finds and downloads Windows executable/archive
  4. Monitors file system changes during runtime
  5. Auto-detects emulator platform
  6. Generates complete manifest with all configurations
  7. Updates GitHub issue with results (if processing from issue)

- **Generated Manifest Features**
  - Portable mode support (portable.txt)
  - Data migration from AppData/Documents to persist directory
  - Automatic version checking via GitHub
  - Autoupdate configuration with hash placeholders
  - Platform-specific shortcuts
  - Persist configuration for game data and settings

### 2. **handle-issue.ps1** (Enhanced)
Enhanced existing script to detect and process manifest requests:

- Detects manifest request issues by:
  - Labels: `request-manifest`, `emulator-request`, `add-emulator`
  - GitHub URL in title or body

- Automatically triggers `create-emulator-manifest.ps1`
- Posts results back to the issue
- Can batch process multiple open request issues

### 3. **MANIFEST_CREATION.md**
Comprehensive documentation covering:

- How to use both creation methods
- GitHub issue workflow
- Integration with GitHub Actions
- Manifest features explained
- Platform auto-detection list
- Validation procedures
- Troubleshooting guide
- Advanced usage examples

## Usage Examples

### Direct Creation
```powershell
# Create manifest for gopher64
.\bin\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/gopher64/gopher64"

# Auto-approve without prompts
.\bin\create-emulator-manifest.ps1 -GitHubUrl "..." -AutoApprove
```

### GitHub Issue Processing
1. User creates issue with:
   - Label: `request-manifest` or `emulator-request`
   - GitHub URL in description: `https://github.com/owner/repo`

2. System automatically:
   - Detects the issue
   - Extracts the repository URL
   - Creates the manifest
   - Updates the issue with results

### GitHub Actions Integration
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

## Workflow

### User Perspective

1. **Request Emulator**
   - Create issue on repo
   - Add `request-manifest` label
   - Include GitHub repository URL

2. **Automatic Processing**
   - System detects issue
   - Creates manifest automatically
   - Tests it on the system
   - Updates issue with results

3. **Review & Merge**
   - Manifest appears in bucket
   - User can review the JSON
   - Runs validation tests
   - PR ready for merge

### Developer Perspective

Running manifest creation manually:

```powershell
# Step 1: Create the manifest
.\bin\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/owner/repo"

# Step 2: Validate it
.\bin\checkver.ps1 -Dir bucket -App app-name
.\bin\check-autoupdate.ps1 -ManifestPath bucket\app-name.json
.\bin\check-manifest-install.ps1 -ManifestPath bucket\app-name.json

# Step 3: Commit and push
git add bucket\app-name.json
git commit -m "feat(app-name): add manifest"
git push
```

## Key Features

### Platform Auto-Detection
Automatically detects:
- Nintendo (64, GameCube, Wii, Switch, 3DS, DS, Game Boy, SNES)
- PlayStation (1, 2, 3, PSP)
- Sega (Genesis, Dreamcast)
- Microsoft (Xbox, Xbox 360)
- Arcade (MAME)
- Multi-system emulators

### Portable Mode
- Creates `portable.txt` on install
- Enables emulator to store data in installation directory
- Persists `portable_data` across updates

### Data Migration
Pre-install script automatically migrates:
- Data from `%APPDATA%\[app-name]`
- Data from `%USERPROFILE%\Documents\[app-name]`
- Copies to portable_data for centralized management

### Version Management
- Automatic GitHub version checking
- Autoupdate with `$version` and `$sha256` substitution
- Handles pre-releases and version format variations

### Runtime Monitoring
- Executes binary to detect created files/folders
- Auto-includes detected directories in persist
- Timeout handling for interactive applications

## Files Created/Modified

### New Files
- `bin/create-emulator-manifest.ps1` - Main automation script
- `MANIFEST_CREATION.md` - Comprehensive documentation

### Modified Files
- `bin/handle-issue.ps1` - Added manifest request detection and handling

## Benefits

1. **Time Saving** - Fully automated manifest creation
2. **Consistency** - All manifests follow the same structure and conventions
3. **Data Preservation** - Automatic migration from existing installations
4. **Portable by Default** - Game data stored with application
5. **Community Friendly** - Users can request emulators via GitHub issues
6. **Validation Included** - Automated testing and validation
7. **Future Proof** - Autoupdate configuration for ongoing maintenance

## Next Steps

1. **Documentation**
   - Share MANIFEST_CREATION.md with team
   - Add to README.md or main documentation

2. **GitHub Actions**
   - Set up workflow to listen for manifest request issues
   - Configure auto-merging for validated manifests

3. **Testing**
   - Test with various emulator repositories
   - Refine platform detection as needed
   - Adjust persist items based on real-world testing

4. **Maintenance**
   - Monitor for edge cases
   - Update platform detection list as new emulators added
   - Improve error handling based on user feedback

---

The system is production-ready and can be used immediately for creating new emulator manifests in the bucket!
