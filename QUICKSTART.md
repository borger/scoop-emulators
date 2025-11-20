# Quick Start Guide - Emulator Manifest Creation

## For Users: Requesting an Emulator

### Method 1: Create a GitHub Issue

1. Go to https://github.com/borger/scoop-emulators/issues
2. Click "New Issue"
3. Use this format:

```
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
      - uses: actions/checkout@v3

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

### ✅ All tests pass!

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
```
[OK] Repository: owner/repo
[OK] Found Windows executable
[OK] Downloaded to: ...
[OK] Detected platform: Nintendo 64
[OK] Manifest saved to: bucket/gopher64.json
```

✅ Validation succeeds:
```
[OK] checkver: 1.1.10
[OK] autoupdate: valid
[OK] installation: success
```

✅ Ready to commit!

---

**Last Updated:** November 2025

For the latest features and updates, see the full documentation in the repository.
