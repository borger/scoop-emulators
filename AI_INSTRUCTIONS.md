# Scoop Emulators Bucket - AI Assistant Instructions

## Overview
This is a Scoop bucket containing manifests for various emulators (MAME, Dolphin, RetroArch, shadps4, visualboyadvance-m, etc.). The bucket includes custom PowerShell scripts for validation and maintenance with advanced GitHub Copilot integration for automated fixes.

## Automated PR Validation & Auto-Merge Workflow

### Two PR Workflows

#### 1. User-Created PR (Manual Submissions)
```
User Creates PR (conventional commit)
         ↓
validate-and-merge.ps1 -IsUserPR $true
         ↓
Run Validation Scripts
  1. checkver validation
  2. autoupdate validation
  3. installation test
         ↓
Post Results to PR Comment
         ↓
Decision
  ├─ ✅ All 3 Pass → Tag @beyondmeat for merge review
  └─ ❌ Any Fail → Comment with detailed error report
```

#### 2. Copilot-Generated PR (Auto-Fix)
```
Issue Created / Copilot PR Created
         ↓
validate-and-merge.ps1 -IsUserPR $false
         ↓
Run Validation Scripts (3 tests)
         ↓
Post Results to PR Comment
         ↓
Decision
  ├─ ✅ All 3 Pass → Auto-merge with squash
  ├─ ❌ Any Fail → Request Copilot fix
  │   ├─ Retry Loop (up to 10 attempts)
  │   └─ Each attempt re-runs full pipeline
  └─ After 10 Failures → Escalate to @beyondmeat with context
```

### Validation Scripts

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

**User PRs** (when all validations pass):
1. Posts approval comment: "✅ Validation Passed - Ready for Merge"
2. Tags @beyondmeat for manual merge review
3. Provides maintainer with validation status

**Copilot PRs** (when all validations pass):
1. Auto-merges using **squash merge**
2. Commit message: `fix(bucket): app-name auto-fix validation passed`
3. Closes PR automatically

### Copilot Fix Loop

If any validation fails on Copilot PR:
1. Posts validation failure details with specific errors
2. Posts @copilot fix request with problem description
3. Copilot attempts to fix (up to **10 times total**)
4. Each fix attempt re-runs full validation pipeline
5. Updates PR comment with attempt number

### Escalation Process

After 10 failed fix attempts by Copilot:
1. Creates GitHub issue automatically
2. Includes:
   - Full validation failure details from all 10 attempts
   - All attempted fixes and their results
   - Link to original PR
   - Manifest content and structure
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
- Up to 10 retry attempts before escalation

**Escalation:**
- After 10 failed attempts, creates GitHub issue
- Tags with `@beyondmeat` and `needs-review`
- Includes full validation failure logs
- Includes all attempted fixes and results

---

### 5. `./bin/handle-issue.ps1` (NEW)
**Purpose**: Automatically processes GitHub issues and coordinates auto-fix or Copilot response

**Usage:**
```powershell
# Handle issue from GitHub Actions
.\bin\handle-issue.ps1 `
  -IssueNumber 42 `
  -GitHubToken $env:GITHUB_TOKEN `
  -GitHubRepo "username/emulators" `
  -BucketPath bucket

# Handles these scenarios:
# 1. Auto-fix attempt on identified manifests
# 2. Create PR for successful auto-fixes
# 3. Request Copilot for failed auto-fixes
```

**Parameters:**
- `IssueNumber`: GitHub issue number to process
- `GitHubToken`: GitHub personal access token (if running in workflow)
- `GitHubRepo`: Repository in format "owner/repo" (if running in workflow)
- `BucketPath`: Path to bucket directory (default: "./bucket")

**Features:**
- Parses issue title and body to identify affected manifests
- Attempts auto-fix using autofix-manifest.ps1
- Creates PR with successful fixes and validation status
- Posts detailed comments to issue about fix attempts
- Requests @copilot assistance when auto-fix fails
- Supports up to 10 Copilot fix attempts via validate-and-merge

**Workflow:**
1. Issue created → handle-issue.ps1 triggered
2. Extract manifest names from issue content
3. Run autofix-manifest.ps1 on each manifest
4. If successful: Create PR with fixes, post success comment
5. If failed: Post Copilot request comment with context
6. Copilot submits PR → validate-and-merge runs (up to 10 attempts)
7. All fixes validated, PR merged or escalated

**Exit Codes:**
- `0`: Issue handled (auto-fix success or Copilot request created)
- `-1`: Error (couldn't identify manifests or API failure)

---

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

## File Formatting Standards

**ALL files in this repository MUST follow these standards to pass Scoop bucket validation:**

### PowerShell Files (.ps1)
- **Encoding**: UTF-8 with BOM (Byte Order Mark) - **REQUIRED by Scoop**
- **Line Endings**: CRLF (Windows)
- **Trailing Newline**: Must end with newline character
- **Whitespace**: No trailing whitespace on any line
- **Indentation**: Spaces only (2 or 4 spaces, no tabs)

### Markdown Files (.md)
- **Encoding**: UTF-8 (standard, no BOM needed)
- **Line Endings**: CRLF (Windows)
- **Trailing Newline**: Must end with newline character
- **Whitespace**: No trailing whitespace on any line
- **Code Fences**: Never wrap entire file in markdown code fence (e.g., ````markdown...````)
- **Indentation**: Spaces only

### YAML Files (.yml, .yaml)
- **Encoding**: UTF-8 (standard, no BOM needed)
- **Line Endings**: CRLF (Windows)
- **Trailing Newline**: Must end with newline character
- **Whitespace**: No trailing whitespace on any line
- **Indentation**: Spaces only (2 spaces per Scoop conventions)

### JSON Files (.json)
- **Encoding**: UTF-8 (standard)
- **Line Endings**: CRLF (Windows)
- **Trailing Newline**: Must end with newline character
- **Whitespace**: No trailing whitespace
- **Formatting**: Use formatjson.ps1 to validate/reformat

### File-by-File Standards

#### PowerShell Scripts (bin/*.ps1 + Scoop-Bucket.Tests.ps1)
Checked by Scoop test suite:
- checkver.ps1
- check-autoupdate.ps1
- check-manifest-install.ps1
- validate-and-merge.ps1
- handle-issue.ps1
- autofix-manifest.ps1
- update-manifest.ps1
- test.ps1
- checkurls.ps1
- checkhashes.ps1
- missing-checkver.ps1
- formatjson.ps1
- auto-pr.ps1
- Scoop-Bucket.Tests.ps1

**All MUST have UTF-8 with BOM encoding. Validate with:**
```powershell
$file = Get-Content -Path "script.ps1" -Encoding Byte -ReadCount 0
if ($file[0] -eq 0xEF -and $file[1] -eq 0xBB -and $file[2] -eq 0xBF) {
  Write-Host "✓ Has UTF-8 BOM"
} else {
  Write-Host "✗ Missing UTF-8 BOM"
}
```

#### Documentation Files
- README.md - UTF-8, trailing newline, no code fence wrapper
- CONTRIBUTING.md - UTF-8, trailing newline
- AUTOFIX_EXCAVATOR.md - UTF-8, trailing newline
- AI_INSTRUCTIONS.md - UTF-8, trailing newline (this file)
- .github/pull_request_template.md - UTF-8, trailing newline, **NO markdown wrapper**
- .github/ISSUE_TEMPLATE/*.yml - UTF-8, trailing newline

#### Manifest Files
- bucket/*.json - UTF-8, formatted with formatjson.ps1, trailing newline

### Validation Commands

**Check for UTF-8 BOM in PowerShell files:**
```powershell
Get-ChildItem -Path "bin\*.ps1" | ForEach-Object {
  $bytes = Get-Content -Path $_.FullName -Encoding Byte -ReadCount 3
  if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Write-Host "✓ $($_.Name) has UTF-8 BOM"
  } else {
    Write-Host "✗ $($_.Name) missing UTF-8 BOM"
  }
}
```

**Check for trailing newlines:**
```powershell
Get-ChildItem -Path "*.ps1", "*.md", "*.json", "*.yml" -Recurse | ForEach-Object {
  $content = [System.IO.File]::ReadAllBytes($_.FullName)
  if ($content.Length -gt 0) {
    if ($content[-1] -ne 0x0A) {
      Write-Host "✗ $($_.Name) missing trailing newline"
    } else {
      Write-Host "✓ $($_.Name) has trailing newline"
    }
  }
}
```

**Run Scoop bucket test suite:**
```powershell
.\Scoop-Bucket.Tests.ps1 -Verbose
```

### Common Mistakes to Avoid

1. **UTF-8 BOM Missing on PowerShell Files**: Use `Set-Content -Encoding UTF8` - but this gives UTF-8 without BOM. Use proper encoding:
   ```powershell
   $utf8BOM = New-Object System.Text.UTF8Encoding($true)
   [System.IO.File]::WriteAllText($file, $content, $utf8BOM)
   ```

2. **PR Template Wrapped in Code Fence**: ❌ Do NOT wrap entire template in ````markdown...````
   - This breaks GitHub template parsing
   - Only use code fences for code blocks within the template

3. **Missing Trailing Newlines**: Every file must end with a newline character
   - Use terminal: `Add-Content -Path file.txt -Value ""` or ensure editor adds newline on save

4. **Trailing Whitespace**: No spaces/tabs at end of lines
   - Many editors have "trim trailing whitespace" option (enable it)

5. **Inconsistent Line Endings**: Keep CRLF throughout (Windows standard)
   - Git can auto-convert with `core.autocrlf = true` if needed

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
