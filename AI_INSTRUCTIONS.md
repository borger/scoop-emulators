# Scoop Emulators Bucket - AI Assistant Instructions

## Overview
This is a Scoop bucket containing manifests for various emulators (MAME, Dolphin, RetroArch, shadps4, visualboyadvance-m, etc.). The bucket includes custom PowerShell scripts for validation and maintenance with advanced GitHub Copilot integration for automated fixes.

## Automated PR Validation & Auto-Merge Workflow

### Complete Pipeline

When Copilot submits a fix PR, an automated validation pipeline runs:

```
Copilot PR Created (conventional commit)
         ↓
validate-and-merge.ps1 Triggered
         ↓
Run Validation Scripts (in sequence)
  1. checkver: Detects latest version
  2. check-autoupdate: Validates autoupdate section
  3. check-manifest-install: Tests Scoop installation
         ↓
Post Results to PR Comment
         ↓
Decision Point
  ├─ ✅ All 3 Pass → Auto-merge with squash
  ├─ ❌ Any Fail → Request Copilot fix
  │   ├─ Retry Loop (up to 3 attempts)
  │   └─ Each attempt follows same pipeline
  └─ After 3 Failures → Create GitHub issue with @beyondmeat escalation
```

### Validation Pipeline Details

**Script 1: checkver**
- Detects latest version from GitHub releases or configured source
- Returns exit code 0 with version on success
- Returns exit code -1 on failure

**Script 2: check-autoupdate**
- Validates manifest has valid `autoupdate` section
- Tests URL placeholders can be substituted
- Returns exit code 0 if valid, -1 if invalid

**Script 3: check-manifest-install**
- Attempts to install manifest via `scoop install`
- Auto-cleans up test installation
- Returns exit code 0 if successful, -1 if failed

**All Three Must Pass** for auto-merge to proceed.

### Merge Behavior

When all validations pass:
1. Performs **squash merge** (combines all PR commits)
2. Uses **conventional commit** format: `fix(bucket): <description>`
3. Preserves original PR description in commit body
4. Closes PR with auto-merge

### Copilot Fix Loop

If any validation fails:
1. Posts validation failure details to PR comment
2. Posts @copilot fix request in PR comment
3. Copilot attempts to fix (up to 3 times total)
4. Each fix attempt re-runs full validation pipeline

### Escalation Process

After 3 failed fix attempts by Copilot:
1. Creates GitHub issue automatically
2. Includes:
   - Full validation failure details
   - All attempted fixes and their results
   - Link to PR
   - Manifest content that failed
3. Tags with labels: `needs-review`, `auto-fix-failed`, `@beyondmeat`
4. Awaits manual human review and fix

### Local Testing

To test validation locally before PR:
```powershell
# Test single manifest validation
.\bin\validate-and-merge.ps1 -ManifestPath bucket/app.json -BucketPath bucket
```

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

### 4. `./bin/validate-and-merge.ps1` (NEW)
**Purpose**: Validates all checks pass on a PR and automatically merges if successful

**Usage:**
```powershell
# Run validation on PR
.\bin\validate-and-merge.ps1 `
  -ManifestPath bucket/shadps4.json `
  -BucketPath bucket `
  -PullRequestNumber 123 `
  -GitHubToken $env:GITHUB_TOKEN `
  -GitHubRepo "username/emulators"

# Test locally without merging
.\bin\validate-and-merge.ps1 -ManifestPath bucket/app.json -BucketPath bucket
```

**Parameters:**
- `ManifestPath`: Path to manifest JSON file
- `BucketPath`: Path to bucket directory
- `PullRequestNumber`: GitHub PR number (if running in workflow)
- `GitHubToken`: GitHub personal access token (if running in workflow)
- `GitHubRepo`: Repository in format "owner/repo" (if running in workflow)
- `MaxRetries`: Maximum Copilot fix attempts (default: 3)

**Features:**
- Runs all three validation scripts in sequence
- Posts validation results to PR as comment
- Auto-merges PR if all validations pass (squash merge with conventional commit)
- Posts fix request to @copilot if any validation fails
- Implements retry loop (up to 3 attempts)
- Auto-escalates to @beyondmeat after max retries
- Uses conventional commit format: `fix(bucket): app-name: description`

**Validation Steps:**
1. Runs `checkver` to detect latest version
2. Runs `check-autoupdate` to validate autoupdate section
3. Runs `check-manifest-install` to test Scoop installation
4. All three must pass for auto-merge

**Exit Codes:**
- `0`: All validations passed and PR merged
- `1`: Validation failed (requires manual fix or Copilot retry)
- `-1`: Error in validation process

**Auto-Merge Behavior:**
- Uses GitHub API to merge with squash option
- Commit message: `fix(bucket): <app>: <description>`
- Preserves PR description in commit body
- Auto-closes PR after merge

**Copilot Integration:**
- Posts comment: `@copilot fix this manifest`
- Waits for Copilot to submit fix PR
- Re-runs validate-and-merge on the fix PR
- Up to 3 retry attempts before escalation

**Escalation:**
- After 3 failed attempts, creates GitHub issue
- Tags with `@beyondmeat` and `needs-review`
- Includes full validation failure logs
- Includes all attempted fixes and results

---

## Common Workflow

### Manual Testing Workflow
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

### Automated PR Validation Workflow
```powershell
# Run full validation on PR (called from GitHub Actions)
.\bin\validate-and-merge.ps1 `
  -ManifestPath bucket/app.json `
  -BucketPath bucket `
  -PullRequestNumber 123 `
  -GitHubToken $env:GITHUB_TOKEN `
  -GitHubRepo "owner/emulators"

# If validation passes → auto-merge with conventional commit
# If validation fails → request @copilot fix with retry loop
# If retries exceeded → escalate to @beyondmeat
```

### GitHub Actions Workflow (excavator.yml)
The excavator workflow automatically:
1. Runs Scoop's excavator for standard updates
2. Runs `autofix-manifest.ps1` on all non-nightly manifests
3. Auto-commits successful fixes
4. Validates with `validate-and-merge.ps1` on Copilot PRs
5. Auto-merges when all tests pass
6. Escalates failures to @beyondmeat

---

### Intelligent Manifest Repair
The autofix-manifest.ps1 script includes advanced features:
- **Checkver Pattern Fixing**: Analyzes release tags to suggest corrected regex patterns
- **Multi-Platform Support**: GitHub, GitLab, and Gitea repositories
- **Hash Verification**: Detects and auto-fixes mismatched hashes
- **Structure Validation**: Validates and repairs manifest JSON structure
- **Issue Tracking**: Logs problems with severity for manual review

### GitHub Copilot Integration
When auto-fix encounters unfixable issues:
1. **Auto-creates GitHub issue** with detailed problem description
2. **Tags @copilot** for AI-assisted PR creation
3. Copilot analyzes and submits a fix PR
4. If PR succeeds → merged automatically
5. If PR fails → **auto-escalates to @beyondmeat** for manual review

**Usage:**
```powershell
.\bin\autofix-manifest.ps1 `
  -ManifestPath bucket/app.json `
  -AutoCreateIssues `
  -GitHubToken $env:GITHUB_TOKEN `
  -GitHubRepo $env:GITHUB_REPOSITORY
```

### Escalation Workflow
Smart escalation process:
- **Level 1**: Auto-fix attempts standard fixes
- **Level 2**: Creates Copilot issue for AI-assisted fixes
- **Level 3**: Copilot submits PR attempt
- **Level 4**: Auto-escalates to @beyondmeat if PR fails
- **Checkver failures** treated as critical and go straight to escalation

### Notification System
Issues requiring manual review are tracked with:
- Issue title and detailed description
- Severity level (error/warning/critical)
- Affected app name
- Automatic GitHub labels: `auto-fix`, `@copilot`, `needs-review`, `@beyondmeat`
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
