# Contributing

You may propose new features or improvements by filing an issue. If you propose a new emulator, you will need to create the manifest file and complete the checklist provided in the template.

## Commit Message Guidelines (Conventional Commits)

This project follows [Conventional Commits](https://www.conventionalcommits.org/) specification for clear, semantic commit messages.

### Format

```
<type>(<scope>): <subject>

<body>

<footer>
```

### Type
Must be one of:
- **feat**: A new feature or manifest addition
- **fix**: Bug fix or manifest repair
- **docs**: Documentation changes (README, guides, etc.)
- **refactor**: Code refactoring without feature changes
- **test**: Test script additions or updates
- **chore**: Build process, dependencies, or automation
- **ci**: CI/CD configuration changes
- **perf**: Performance improvements

### Scope
The scope should specify which part of the project:
- **bucket**: Changes to manifest files
- **scripts**: Changes to bin/ scripts (checkver, autofix, etc.)
- **ci**: GitHub Actions workflow changes
- **docs**: Documentation updates
- Optional for minor changes

### Subject
- Imperative mood ("add" not "added")
- No period at the end
- Maximum 50 characters
- Lowercase except for acronyms

### Body
- Explain *what* and *why*, not *how*
- Wrap at 72 characters
- Separate from subject with blank line
- Optional but recommended for non-trivial changes

### Footer
- Close related issues: `Closes #123`, `Fixes #456`
- Reference PRs: `PR #789`
- Optional but useful for automation

### Examples

```
feat(bucket): add RetroArch 1.22.1 manifest

Added new RetroArch emulator manifest with support for 32-bit and 64-bit
Windows installations. Includes proper autoupdate configuration pointing to
official GitHub releases.

Closes #456
```

```
fix(bucket): repair desmume manifest URL and hash

Replaced broken nightly.link URL with direct GitHub releases download.
Updated SHA256 hash to match new download location.

Fixes #789
```

```
refactor(scripts): improve checkver output parsing

Enhanced checkver wrapper to handle both outdated and current version
formats without subprocess overhead. Uses native PowerShell I/O redirection.
```

```
ci: add validation and auto-merge to Copilot workflow

Implements automated manifest validation after Copilot PR creation.
Runs checkver, autoupdate check, and installation test. Auto-merges
if all pass, requests fixes if any fail, escalates to @beyondmeat.
```

## Automated Validation & Merge Workflow

All PRs automatically run validation tests. See [AI_INSTRUCTIONS.md](./AI_INSTRUCTIONS.md) for detailed workflow documentation.

### Validation Requirements

**IMPORTANT:** All manifests must pass these validations:

```powershell
# Check for version detection
.\bin\checkver.ps1 -App <app-name> -Dir bucket

# Check for autoupdate configuration
.\bin\check-autoupdate.ps1 -ManifestPath bucket/<app-name>.json

# Check for installation
.\bin\check-manifest-install.ps1 -ManifestPath bucket/<app-name>.json
```

### Workflow Summary
- **User PR**: Validation runs → Tags @beyondmeat for review if all pass
- **Copilot PR**: Validation runs → Auto-merges if all pass, retries up to 10 times on failure
- **Complex Issues**: After 10 failed attempts, escalated to @beyondmeat for manual review

For complete details, see [AI_INSTRUCTIONS.md](./AI_INSTRUCTIONS.md#automated-pr-validation--auto-merge-workflow).

## Manifest Validation Requirements

Anytime a manifest is added or modified, it MUST be validated using the validation scripts. Validation is automatic in pull requests, but can be run locally for testing.

## Requirements for Adding a New Emulator

- Active development: Recent commit activity (past 2 years)
- Recent releases: Stable release within past 3 years
- Windows compatibility: Works on Windows 10 and Windows 11
- Portable mode: App data stored in same folder as app
- User base: Strong user base with broad appeal

If you answer NO to any of these, consider other buckets that may be a better fit.

## Creating a Manifest

A scoop [app manifest](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests) is a JSON file that tells Scoop how to install/update/uninstall an app. Read the [manifest documentation](https://github.com/ScoopInstaller/Scoop/wiki/Creating-an-app-manifest) before starting.

### Before You Start

1. **Research**: Can you create a complete, full-featured manifest?
2. **Maintenance**: Will you fix the manifest when upstream changes break it?

If yes to both, copy a similar manifest and customize it. If no, gather information and file an issue with the template.

## Pull Request Process

1. **Create Feature Branch**: Use conventional commit naming
2. **Make Changes**: Update manifests and/or scripts
3. **Validation**: Run validation scripts locally
4. **Commit Messages**: Follow Conventional Commits format
5. **Submit PR**: Include description and issue reference
6. **Automated Tests**: Wait for validation to complete
7. **Review**: Address any feedback or failed validations
8. **Merge**: Automatic if all validations pass, or manual if review needed

### PR Checklist

- [ ] Commit messages follow Conventional Commits format
- [ ] Validation scripts pass (checkver, autoupdate, install)
- [ ] Manifest is valid JSON
- [ ] PR description explains the change
- [ ] Closes/Fixes relevant issues
- [ ] No unrelated changes included

## Automated Validation Features

### GitHub Copilot Integration

The system automatically:
1. Attempts auto-fixes for broken manifests
2. Engages Copilot for complex issues (up to 10 fix attempts)
3. Auto-merges Copilot PRs when all validations pass
4. Escalates complex issues to @beyondmeat

For details, see [AUTOFIX_EXCAVATOR.md](./AUTOFIX_EXCAVATOR.md) and [AI_INSTRUCTIONS.md](./AI_INSTRUCTIONS.md).



# Quick Start Guide - Emulator Manifest Creation

## For Users: Requesting an Emulator

### Method 1: Create a GitHub Issue

1. Go to <https://github.com/borger/scoop-emulators/issues>
2. Click "New Issue"
3. Use this format:

```text
Title: Add [Emulator Name]

Body:
Please add support for [Emulator Name]
GitHub: https://github.com/owner/repo
```

4. Add label: `request-manifest` or `emulator-request`
5. Click "Submit new issue"

**Done!** The system will automatically:

- Create the manifest
- Test it on the system
- Update your issue with results
- Add the emulator to the bucket

---

## For Developers: Creating a Manifest Manually

### Quick Start

```powershell
# Navigate to the bucket directory
cd C:\path\to\scoop-emulators

# Create manifest from GitHub URL
.\bin\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/gopher64/gopher64"
```

### What Happens

1. ✅ Downloads the latest release
2. ✅ Extracts executables if needed
3. ✅ Tests the application
4. ✅ Detects what data it creates
5. ✅ Generates complete manifest
6. ✅ Saves to `bucket/[app-name].json`

### Validate

```powershell
# Run these three tests
.\bin\checkver.ps1 -Dir bucket -App gopher64
.\bin\check-autoupdate.ps1 -ManifestPath bucket\gopher64.json
.\bin\check-manifest-install.ps1 -ManifestPath bucket\gopher64.json
```

All must show ✅ or [OK]

### Commit

```powershell
git add bucket\gopher64.json
git commit -m "feat(gopher64): add manifest"
git push
```

---

## For CI/CD: GitHub Actions Setup

Add this workflow to `.github/workflows/manifest-requests.yml`:

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
      - uses: actions/checkout@v7

      - name: Create Emulator Manifest
        shell: pwsh
        run: |
          .\bin\create-emulator-manifest.ps1 `
            -IssueNumber ${{ github.event.issue.number }} `
            -GitHubToken ${{ secrets.GITHUB_TOKEN }}

      - name: Commit Changes
        shell: pwsh
        run: |
          git config user.name "GitHub Automation"
          git config user.email "automation@github.com"
          git add bucket/
          git diff --cached --quiet || (git commit -m "feat: automated manifest from issue #${{ github.event.issue.number }}" && git push)
```

---

## Common Issues & Solutions

### ❌ "No suitable Windows executable found"

**Problem:** The repository doesn't have a Windows release.

**Solution:**

- Check if the project supports Windows
- Some emulators may require manual build
- Open an issue for manual review

### ❌ "Failed to fetch issue details"

**Problem:** GitHub token is invalid or doesn't have permissions.

**Solution:**

```powershell
# When using GitHub Token, ensure it has:
# - repo (full control of private repositories)
# - read:user (read user profile)

# For GitHub Actions, use:
${{ secrets.GITHUB_TOKEN }}
```

### ❌ Application crashes on startup

**Problem:** Executable couldn't be executed during monitoring.

**Solution:**

- This is usually okay - manifest is still created
- Monitoring shows: [WARN] Could not start executable
- Review the manifest manually

### ✅ All tests pass

**Next steps:**

1. Review the created manifest file
2. Commit with proper message
3. Create a pull request
4. Wait for automated merge (all tests must pass)

---

## What Gets Created

### Manifest Structure

```json
{
  "version": "1.1.10",                    // Auto-detected
  "description": "Nintendo 64 Emulator",  // Auto-detected platform
  "homepage": "https://github.com/...",   // From repo
  "license": {
    "identifier": "GPL-3.0",              // Auto-detected
    "url": "https://raw.githubusercontent.com/..."
  },
  "architecture": {
    "64bit": {
      "url": "https://github.com/.../release.exe",
      "hash": "sha256:..."                // Auto-calculated
    }
  },
  "post_install": [
    "Create portable.txt for portable mode"
  ],
  "bin": "gopher64-windows-x86_64.exe",   // Auto-detected
  "shortcuts": [
    ["exe", "Nintendo 64 [n64][g64]"]    // Platform-specific
  ],
  "persist": [
    "portable_data",                      // Auto-detected files
    "...other detected dirs"
  ],
  "pre_install": [
    "Migrate data from AppData/Documents"
  ],
  "checkver": {
    "github": "https://github.com/owner/repo"
  },
  "autoupdate": {
    "architecture": {
      "64bit": {
        "url": ".../$version/...",        // Version placeholder
        "hash": "sha256|$sha256"           // Hash placeholder
      }
    }
  }
}
```

---

## Supported Platforms (Auto-Detected)

| Platform | Examples |
|----------|----------|
| Nintendo 64 | gopher64, mupen64 |
| GameCube/Wii | dolphin |
| Wii U | cemu |
| Switch | yuzu, ryujinx |
| 3DS | citra |
| DS | melonds |
| Game Boy | sameboy, visualboyadvance |
| SNES | snes9x, bsnes |
| PS1 | duckstation, pcsx |
| PS2 | pcsx2 |
| PS3 | rpcs3 |
| PSP | ppsspp |
| Xbox | cxbx |
| Xbox 360 | xenia |
| Dreamcast | flycast, redream |
| Genesis | gens |
| Arcade | mame |
| Multi | retroarch |

---

## Tips for Best Results

✅ **DO:**

- Use official GitHub repositories
- Let the app run fully (don't close it immediately)
- Review the generated manifest
- Run all validation tests
- Test on a clean system if possible

❌ **DON'T:**

- Force-close the application during monitoring
- Skip validation tests
- Modify generated manifest without testing
- Use repositories without Windows releases

---

## Getting Help

### Documentation

- Full guide: `MANIFEST_CREATION.md`
- Automation summary: `AUTOMATION_SUMMARY.md`
- This quick start: `QUICKSTART.md`

### Issues

1. Open an issue on the repository
2. Describe the problem
3. Include the error message
4. Attach the manifest file if created

### Manual Creation

If automation fails, manifests can still be created manually by copying and modifying existing ones.

---

## Examples

### Create from URL

```powershell
.\bin\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/gopher64/gopher64"
```

### Create from Issue (with token)

```powershell
$token = "ghp_xxxxxxxxxxxxxxxxxxxx"
.\bin\create-emulator-manifest.ps1 -IssueNumber 42 -GitHubToken $token
```

### Skip Confirmations

```powershell
.\bin\create-emulator-manifest.ps1 -GitHubUrl "..." -AutoApprove
```

### Process All Open Requests

```powershell
.\bin\handle-issue.ps1 -GitHubToken $token
```

---

## Success Indicators

✅ All tests pass:

```text
[OK] Repository: owner/repo
[OK] Found Windows executable
[OK] Downloaded to: ...
[OK] Detected platform: Nintendo 64
[OK] Manifest saved to: bucket/gopher64.json
```

✅ Validation succeeds:

```text
[OK] checkver: 1.1.10
[OK] autoupdate: valid
[OK] installation: success
```

✅ Ready to commit!

---

**Last Updated:** November 2025

For the latest features and updates, see the full documentation in the repository.


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

1. Go to <https://github.com/borger/scoop-emulators/issues>
2. Click "New Issue"
3. Include the GitHub repository URL in the issue title or body:

   ```text
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
      - uses: actions/checkout@v7

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

5. **Handling Non-Standard Release Formats**
   - If release tags contain custom prefixes (e.g. `Goldeneye1.2.4` for version `1.2.4`), prefer defining the `autoupdate` URL using `$version` directly (e.g., `Goldeneye$version`) rather than relying on `$matchTag`. Some local validation tools (like `check-manifest-install.ps1`) only perform simple substitutions on `$version` when testing URLs, and `$matchTag` will trigger 404 validation errors.
   - For ports/recompilation builds, archive folder structures and executable names often change across versions. Always verify the directory tree of the downloaded release assets to specify the correct `extract_dir` and `bin` entry.

## Contributing

When submitting manifests created with this tool:

1. Run all validation tests
2. Review the JSON for accuracy
3. Test on a clean system if possible
4. Submit PR with proper commit message format: `feat(app-name): add manifest`

---

For issues or improvements to the automation system, open an issue on the bucket repository.


# GitHub Workflows Documentation

This document describes the GitHub Actions workflows for the scoop-emulators bucket.

## Workflow Overview

The bucket uses four main GitHub Actions workflows, each with a specific responsibility:

### 1. **CI** (Continuous Integration)
**File**: `.github/workflows/ci.yml`

Runs on:
- Pull requests
- Pushes to main branch
- Manual trigger (workflow_dispatch)

**Purpose**: Tests the bucket manifests using the official Scoop test suite.

**Jobs**:
- `test_powershell`: Tests with Windows PowerShell 5.1
- `test_pwsh`: Tests with PowerShell 7+ (pwsh)

Each test job:
1. Checks out the bucket
2. Checks out Scoop core to get test infrastructure
3. Runs the official Scoop test suite

**Status Badge**: [![Tests](https://github.com/borger/scoop-emulators/actions/workflows/ci.yml/badge.svg)](https://github.com/borger/scoop-emulators/actions/workflows/ci.yml)

---

### 2. **Excavator** (Version Checking)
**File**: `.github/workflows/excavator.yml`

Runs on:
- **Hourly schedule** (every hour on the hour)
- Manual trigger (workflow_dispatch)

**Purpose**: Checks for new releases of all emulators and creates pull requests with updates.

**Job**:
- `excavate`: Runs the `ScoopInstaller/GithubActions@main` action with `SKIP_UPDATED: '1'` to avoid checking already-updated apps

**What it does**:
1. Uses Scoop's official excavator action to scan for new releases
2. Creates pull requests for manifests that have newer versions available
3. Sends pull requests to the Scoop bucket PR system for validation

**Notes**:
- Automated by Scoop's infrastructure - this workflow delegates to the official action
- Pull requests created are separate from auto-fixes
- Manual PRs and updated manifests are skipped (`SKIP_UPDATED`)

**Status Badge**: [![Excavator](https://github.com/borger/scoop-emulators/actions/workflows/excavator.yml/badge.svg)](https://github.com/borger/scoop-emulators/actions/workflows/excavator.yml)

---

### 3. **Auto-Fix Manifests** (Repair Broken Manifests)
**File**: `.github/workflows/auto-fix.yml`

Runs on:
- **Twice daily** (midnight and noon UTC)
- Manual trigger (workflow_dispatch)
- **Push events** when bucket manifests change (for quick validation)
- **When Excavator fails** (automatic recovery trigger)

**Purpose**: Automatically repairs broken manifests when URLs fail, versions don't match, or hashes are incorrect.

**Jobs**:
- `autofix`: Single comprehensive auto-fix job with conditional execution

**Conditional Trigger Logic**:
```
if: github.event_name != 'workflow_run' || github.event.workflow_run.conclusion == 'failure'
```
This ensures the workflow:
- Always runs on schedule, push, and manual triggers
- Only runs on excavator completion if excavator **failed**
- Skips running on successful excavator runs (avoids redundant execution)

**Workflow Steps**:
1. **Log trigger reason**: Displays what triggered the workflow and excavator's status
2. **Setup Scoop environment**: Configures `SCOOP`, `SCOOP_HOME`, and `PATH` environment variables
3. **Auto-fix broken manifests**:
   - Discovers broken manifests in the bucket
   - Attempts to fix common issues:
     - URL resolution (404 errors)
     - Version mismatches
     - Hash recalculation
     - Checkver pattern fixes
   - Tracks number of manifests fixed
4. **Commit and push**: Commits fixed manifests back to the repository if changes were made

**Key Features**:
- Runs even if excavator hasn't created PRs yet
- Can fix manifests broken by external changes (e.g., upstream moved their downloads)
- Executes separate from excavator to allow faster recovery
- Automatically triggered on excavator failures for quick remediation
- Dry-run capable - no changes if nothing is broken

**Exit Codes** (from autofix-manifest.ps1):
- `0`: Manifest was broken and was fixed
- `1`: Manifest is already valid
- `-1`: Could not fix, manual review needed

---

### 4. **Review and Verify** (Consolidated PR/Issue Handlers)
**File**: `.github/workflows/pull_request.yml`

Runs on:
- Pull requests opened
- Issues opened
- Issues labeled
- Issue comments created

**Purpose**: Handles pull requests, issues, and comments using Scoop's official review action.

**Jobs** (all use conditional execution):
- `handle_pr`: Runs when a pull request is opened
- `handle_issue`: Runs when an issue is opened or the "verify" label is added
- `handle_comment`: Runs when an issue comment starts with `/verify`

**What it does**:
- Validates pull request manifests
- Assigns reviewers based on labels
- Runs validation and install tests
- Auto-merges valid PRs
- Manages review workflow

**Previous Files Consolidated**:
- `issues.yml` → merged into `pull_request.yml`
- `issue_comment.yml` → merged into `pull_request.yml`

---

## Workflow Sequence

### Normal Update Flow (Success)
```
1. EXCAVATOR runs hourly (success)
   ├─→ Checks for new versions
   ├─→ Creates PR with version update
   └─→ Completes successfully

2. AUTO-FIX skips (not triggered on success)
   └─→ Prevents redundant execution

3. CI runs on the PR
   └─→ Tests the updated manifest

4. REVIEW runs on the PR
   └─→ Validates and auto-merges if valid
```

### Error Recovery Flow (Excavator Fails)
```
1. EXCAVATOR runs hourly (failure)
   ├─→ Encounters errors during update
   ├─→ Creates broken PR or fails
   └─→ Completes with failure status

2. AUTO-FIX auto-triggers (on failure)
   ├─→ Logs excavator failure
   ├─→ Attempts to fix broken manifests
   └─→ Commits fixes if successful

3. Issue resolved within the hour
   └─→ No manual intervention needed
```

---

## Environment Variables

### Scoop Environment Setup

All workflows that execute bucket scripts automatically set up:

- `SCOOP`: User's Scoop installation path (typically `C:\Users\<user>\scoop`)
- `SCOOP_HOME`: Scoop core path (typically `$SCOOP\apps\scoop\current`)
- `PATH`: Updated to include scoop shims directory

---

## Manual Triggers

All workflows can be triggered manually via GitHub Actions UI:

1. Go to repository Actions tab
2. Select the workflow
3. Click "Run workflow"
4. Optionally provide inputs (if any)

---

## Troubleshooting

### Auto-fix doesn't fix broken manifests
- Run manually to see detailed output
- Check if manifest requires manual investigation
- Review the manifest structure in the logs

### Auto-fix didn't run after excavator failed
- Verify excavator job's conclusion status shows "failure"
- Check GitHub Actions logs for auto-fix job conditions
- Ensure push events include bucket manifest changes

### Review workflow doesn't run
- Verify pull request was opened (not pushed as draft)
- Check if issue has proper labels
- Ensure comment starts with `/verify` command

---

## Related Documentation

- [AUTOFIX_EXCAVATOR.md](./AUTOFIX_EXCAVATOR.md): Details on auto-fix capabilities
- [AI_INSTRUCTIONS.md](./AI_INSTRUCTIONS.md): AI automation guidelines
- [CONTRIBUTING.md](./CONTRIBUTING.md): Contributing guidelines

