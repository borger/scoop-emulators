# Scoop Emulators Bucket - AI Assistant Instructions

## Overview
This is a Scoop bucket containing manifests for various emulators (MAME, Dolphin, RetroArch, shadps4, visualboyadvance-m, etc.). The bucket includes custom PowerShell scripts for validation and maintenance.

## Manifest Structure

### Basic Fields
- `version`: Current version of the emulator
- `description`: Brief description
- `homepage`: Project URL
- `license`: License information
- `architecture`: Platform-specific URLs and hashes (32bit/64bit)
- `bin`: Executable file(s)
- `shortcuts`: Windows Start Menu shortcuts
- `persist`: Directories to preserve between updates
- `checkver`: Configuration for checking latest version
- `autoupdate`: Configuration for automatic version updates

### Two Common Autoupdate Patterns

**Pattern 1: Direct Architecture URLs**
```json
"autoupdate": {
    "64bit": { "url": "..." },
    "32bit": { "url": "..." }
}
```

**Pattern 2: Nested Architecture URLs (nested under "architecture" key)**
```json
"autoupdate": {
    "architecture": {
        "64bit": { "url": "..." },
        "32bit": { "url": "..." }
    }
}
```

Both patterns can coexist with generic URLs. The update script handles both.

### Checkver Configuration
```json
"checkver": {
    "github": "https://github.com/user/repo"
    // OR other sources like regex, json, etc.
}
```

### Version Placeholders in URLs
- `$version`: Replaced with the manifest version
- Other placeholders like `$match1` from regex capture groups

## Custom Scripts Created

### 1. `./bin/check-autoupdate.ps1`
**Purpose**: Validates autoupdate configuration and verifies URLs are accessible

**Usage:**
```powershell
.\bin\check-autoupdate.ps1 -ManifestPath bucket/mame.json
.\bin\check-autoupdate.ps1 -ManifestPath bucket/shadps4.json -Verbose
```

**Features:**
- Validates manifest has `autoupdate` section
- Handles both direct and nested architecture URLs
- Skips accessibility checks for URLs with placeholder variables
- Returns 0 on success, -1 on failure

**Exit Codes:**
- `0`: Autoupdate is valid
- `-1`: Error (prints error message)

---

### 2. `./bin/check-manifest-install.ps1`
**Purpose**: Tests if a manifest can be successfully installed via Scoop

**Usage:**
```powershell
.\bin\check-manifest-install.ps1 -ManifestPath bucket/shadps4.json
.\bin\check-manifest-install.ps1 -ManifestPath bucket/visualboyadvance-m.json -Verbose
```

**Features:**
- Validates manifest JSON structure
- Extracts app name from filename automatically
- Runs `scoop install` with the manifest
- Verifies successful installation
- Automatically cleans up (uninstalls test app)
- Returns 0 on success, -1 on failure

**Exit Codes:**
- `0`: Installation successful
- `-1`: Installation failed

---

### 3. `./bin/update-manifest.ps1`
**Purpose**: Checks for latest version and optionally updates manifest with new URLs and hashes

**Usage:**
```powershell
# Check for updates (read-only)
.\bin\update-manifest.ps1 -ManifestPath bucket/visualboyadvance-m.json

# Apply the update
.\bin\update-manifest.ps1 -ManifestPath bucket/visualboyadvance-m.json -Update

# Force update even if already up-to-date
.\bin\update-manifest.ps1 -ManifestPath bucket/shadps4.json -Update -Force

# Verbose output
.\bin\update-manifest.ps1 -ManifestPath bucket/retroarch.json -Verbose
```

**Features:**
- Uses Scoop's checkver to find latest version
- Parses checkver output correctly (handles both outdated and current formats)
- Updates version field
- Substitutes `$version` placeholder in autoupdate URLs
- Downloads files and calculates SHA256 hashes
- Handles both direct and nested architecture URLs
- Gracefully handles download failures (keeps old hash as fallback)
- Returns 0 on success, -1 on failure

**Exit Codes:**
- `0`: Successfully updated (or already up-to-date)
- `-1`: Error

**Checkver Output Formats:**
- Outdated: `"shadps4: 0.12.5 (scoop version is 0.12.0) autoupdate available"`
- Current: `"shadps4: 0.12.5"`

---

## Common Workflow

```powershell
# 1. Check for latest version
.\bin\update-manifest.ps1 -ManifestPath bucket/app.json -Verbose

# 2. Validate autoupdate configuration
.\bin\check-autoupdate.ps1 -ManifestPath bucket/app.json

# 3. Update the manifest
.\bin\update-manifest.ps1 -ManifestPath bucket/app.json -Update

# 4. Test installation
.\bin\check-manifest-install.ps1 -ManifestPath bucket/app.json

# 5. Auto-fix if issues are found
.\bin\autofix-manifest.ps1 -ManifestPath bucket/app.json -NotifyOnIssues
```

## Enhanced Features (November 2025)

### Intelligent Manifest Repair
The autofix-manifest.ps1 script includes advanced features:
- **Checkver Pattern Fixing**: Analyzes release tags to suggest corrected regex patterns
- **Multi-Platform Support**: GitHub, GitLab, and Gitea repositories
- **Hash Verification**: Detects and auto-fixes mismatched hashes
- **Structure Validation**: Validates and repairs manifest JSON structure
- **Issue Tracking**: Logs problems with severity for manual review

### Notification System
Issues requiring manual review are tracked with:
- Issue title and detailed description
- Severity level (error/warning)
- Affected app name
- Timestamp for audit trail

---

## Known Issues & Notes

### visualboyadvance-m
- Successfully updated from 2.2.2 to 2.2.3
- Uses nested architecture URLs pattern
- 32-bit builds may not be available for all versions (script gracefully falls back to old hash)

### visualboyadvance-m-nightly
- Version set to "nightly" (not semantic version)
- No hashes included (nightly builds change daily)
- URLs point to `https://nightly.visualboyadvance-m.org/`
- Scoop automatically skips hash verification for nightly builds
- Version gets timestamped by Scoop (e.g., nightly-20251119)

### melonds
- Updated from 1.0 to 1.1
- Release filename format changed: includes version in filename
- Old format: `melonDS-windows-x86_64.zip`
- New format: `melonDS-1.1-windows-x86_64.zip`
- Autoupdate pattern must use `$version` placeholder in filename: `melonDS-$version-windows-x86_64.zip`

### desmume
- Fixed from broken `nightly.link` GitHub Artifacts URL
- Now uses direct GitHub releases: `https://github.com/TASEmulators/desmume/releases/download/$version/desmume-win-x64.zip`
- Version is a git commit hash (e.g., "efd7486")
- Checkver extracts 7-character commit hash from GitHub Actions page
- Autoupdate automatically substitutes `$version` with commit hash

### scummvm-nightly
- Version field set to "nightly" (not semantic)
- Fixed by adding autoupdate section with static "latest" URLs
- Daily builds are always at: `https://buildbot.scummvm.org/dailybuilds/master/windows-x86-*-master-latest.zip`
- Autoupdate section mirrors current URLs since they're always the latest build
- No hash verification needed for nightly builds

### URL Patterns
- GitHub releases: `https://github.com/user/repo/releases/download/vX.Y.Z/file.zip`
- Nightly builds: `https://nightly.project.org/file.zip` (no version parameter)
- Generic templates use `$version` placeholder which is substituted at update time
- Some projects include version in filename: `app-$version-windows.zip`

### Special Manifest Types

**Nightly/Development Builds:**
- Version field: `"nightly"`, `"dev"`, or similar (not semantic version)
- No hash fields required (Scoop skips verification)
- Autoupdate URLs typically don't use `$version` placeholder
- Example: visualboyadvance-m-nightly

**Standard Releases:**
- Version field: Semantic version (e.g., "1.0", "2.2.3")
- Hash field: Required, SHA256
- Autoupdate uses `$version` placeholder in URL
- Example: melonds, visualboyadvance-m

### Hash Verification
- The update script downloads each file and calculates SHA256 hash
- If download fails (404 or network error), old hash is preserved with warning
- This prevents broken manifests while still allowing partial updates

## Performance Notes

- Checkver relies on external sources (GitHub API, etc.)
- First time hash calculation may take time due to file downloads
- Cached downloads from previous Scoop operations are reused when available

## Script Dependencies

- **Scoop**: Must be installed and in PATH
- **PowerShell 5.0+**: Core functionality
- **pwsh**: Used by update-manifest.ps1 for reliable checkver output capture
- **Internet connectivity**: For checkver lookups and file downloads

## Error Handling

All scripts:
- Return meaningful error messages to stderr
- Use consistent exit codes (0 = success, -1 = failure)
- Support `-Verbose` flag for detailed debugging
- Handle network timeouts gracefully (10 second default)

## Implementation Summary

### Automation Framework Deployed
This bucket now has a complete automation and validation framework:

**Custom Scripts (11 total):**
1. `checkver.ps1` - Enhanced wrapper for Scoop's version detection
2. `check-autoupdate.ps1` - Validates autoupdate configurations
3. `check-manifest-install.ps1` - Tests manifest installations
4. `update-manifest.ps1` - Automated version and hash updates
5. `autofix-manifest.ps1` - Intelligent manifest repair with multi-platform support, hash verification, and issue tracking
6. `auto-pr.ps1`, `checkhashes.ps1`, `checkurls.ps1`, `formatjson.ps1`, `missing-checkver.ps1`, `test.ps1` - Support scripts

**GitHub Actions Integration:**
- `excavator.yml` workflow runs hourly
- Auto-fixes broken manifests with intelligent recovery
- Git auto-commit and push for successful updates
- Scheduled: `0 * * * *` (every hour)

**Documentation:**
- `AI_INSTRUCTIONS.md` - This guide
- `AUTOFIX_EXCAVATOR.md` - Workflow details and troubleshooting

### Validation Checklist
- [x] All manifests structurally valid
- [x] All manifests pass autoupdate validation
- [x] All scripts have UTF-8 BOM
- [x] All markdown files have UTF-8 BOM
- [x] GitHub Actions style checks passing
- [x] Scripts tested with real manifests
- [x] Installation tests verified
- [x] Autoupdate patterns validated
- [x] Intelligent checkver pattern fixing implemented
- [x] Multi-platform repository support (GitHub/GitLab/Gitea)
- [x] Hash mismatch detection and auto-fix
- [x] Manifest structure validation
- [x] Issue notification system
- [x] Manual review workflow

### Ready for Production
The bucket is fully configured for automated updates and validation with intelligent recovery from common issues. The excavator workflow will maintain the bucket automatically while preserving manual edits and handling edge cases through the issue tracking system.
