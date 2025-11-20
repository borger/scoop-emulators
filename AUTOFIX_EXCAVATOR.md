# Excavator Auto-Fix Enhancement

## Overview
The Excavator GitHub workflow has been enhanced to automatically detect and fix common manifest issues when they occur during version updates. When auto-fixes fail, it automatically creates GitHub issues with Copilot and escalation tags.

## Complete Workflow

### 1. **Excavate Step** (Scoop Official)
- Runs the standard Scoop Excavator to check for updates
- Uses GitHub Actions from ScoopInstaller/GithubActions

### 2. **Auto-fix Step** (Enhanced)
- Runs `./bin/autofix-manifest.ps1` on all manifests (except nightly/dev)
- Detects issues and attempts to automatically fix them
- Creates GitHub issues if auto-fix fails:
  - **Copilot Issues**: Tagged with `@copilot` for AI-assisted PR creation
  - **Escalation Issues**: Tagged with `@beyondmeat` if Copilot PR fails

### 3. **Commit Step**
- Commits any fixed manifests back to the repository
- Uses auto-updater service account credentials

### 4. **GitHub Copilot Integration** (New)
When auto-fix encounters unfixable issues:
1. Creates GitHub issue with `@copilot` label
2. Copilot analyzes issue and submits PR with fix
3. If PR fixes the issue → merged automatically
4. If PR fails → escalates with `@beyondmeat` label for manual review

## What Can Be Auto-Fixed

### URL Correction
- **Simple version substitution**: Replaces old version with new version in URL
  - Example: `app-1.0.zip` → `app-1.1.zip`

- **GitHub API lookup**: Finds correct download URL from GitHub release assets
  - Searches for matching architecture (64bit, 32bit, generic)
  - Automatically updates URL if found

### Hash Calculation
- Downloads updated files
- Calculates SHA256 hashes
- Updates manifest hash fields

### Supported Scenarios
✓ Version scheme change (1.0 → 1.1)
✓ Filename format change (app-windows.zip → app-1.1-windows.zip)
✓ 404 errors on download URLs
✓ Architecture-specific downloads

## What Triggers Escalation

✗ Checkver pattern failures (regex doesn't match new format)
✗ Manifest structure changes (no autoupdate/checkver sections)
✗ Nightly/dev builds (intentionally skipped - no stable version)
✗ Projects with no GitHub releases
✗ Copilot PR creation fails

**Escalation Process:**
1. Auto-fix detects unfixable issue
2. Creates GitHub issue with `@copilot` label
3. Copilot submits PR attempt
4. If PR fails → automatic escalation to `@beyondmeat`
5. Manual review and fix applied

## Implementation Details

### autofix-manifest.ps1
```powershell
& .\bin\autofix-manifest.ps1 `
  -ManifestPath bucket/app.json `
  -BucketPath bucket `
  -AutoCreateIssues `
  -GitHubToken $env:GITHUB_TOKEN `
  -GitHubRepo "owner/repo"
```

**Parameters:**
- `-ManifestPath`: Path to manifest file
- `-BucketPath`: Path to bucket directory
- `-IssueLog`: Path to log issues to file
- `-NotifyOnIssues`: Enable issue notifications
- `-GitHubToken`: GitHub API token (uses `$env:GITHUB_TOKEN` if not provided)
- `-GitHubRepo`: GitHub repository in `owner/repo` format (uses `$env:GITHUB_REPOSITORY` if not provided)
- `-AutoCreateIssues`: Automatically create GitHub issues for unfixable problems

**Features:**
- Runs checkver to find latest version
- Attempts 3-tier URL fixing:
  1. Simple version substitution
  2. GitHub/GitLab/Gitea API release asset lookup
  3. Issue creation with Copilot tag
- Downloads and calculates SHA256 hashes
- Detects hash mismatches and auto-recomputes
- Validates manifest structure
- Creates GitHub issues with proper labels:
  - `auto-fix`: All auto-fix issues
  - `@copilot`: For Copilot AI-assisted fixes
  - `needs-review`, `@beyondmeat`: For escalation

**Exit Codes:**
- `0`: Successfully fixed
- `1`: Already valid/up-to-date
- `2`: Issues detected, GitHub issue created
- `3`: GitHub issue created (alternative)
- `-1`: Fatal error

### Workflow Execution
```yaml
Excavate → Auto-fix with issue creation → Copilot PR → Commit & Push
```

Runs hourly via cron: `0 * * * *` (every hour at :00)

### GitHub Issue Template

When auto-fix fails, issues are created with this structure:

```
Title: Auto-fix failed for [app] - Copilot review needed
Labels: auto-fix, @copilot

## Manifest Auto-Fix Failed
**App**: [app-name]

### Issue Description
[Technical details of what failed]

### Severity
[error|warning]

### Timestamp
[ISO 8601 timestamp]

### Next Steps
- [ ] GitHub Copilot to review and create fix PR
- [ ] Run: `.\bin\autofix-manifest.ps1 -ManifestPath bucket/[app].json`
- [ ] Commit and push changes

### Context
Manifest: bucket/[app].json
```

If Copilot PR fails, escalation issue is created:
```
Title: ESCALATION: Manual fix needed for [app]
Labels: auto-fix, needs-review, @beyondmeat
```

## Benefits

1. **Automated Recovery**: Manifests that break due to upstream changes are automatically fixed
2. **Reduced Maintenance**: No manual intervention needed for common URL/version changes
3. **Quick Fixes**: Broken manifests are fixed and pushed within minutes of being discovered
4. **Audit Trail**: Git history shows what was auto-fixed and when

## Example Fixes

### melonDS (filename format change)
- **Before**: `melonDS-windows-x86_64.zip`
- **After**: `melonDS-1.1-windows-x86_64.zip`
- **Fix**: Auto-detected via GitHub API, updated URL and hash

### SpaghettiKart (version scheme change)
- **Before**: `Spaghettify-Alfredo-Alfa-1-Windows.zip`
- **After**: `Spaghettify-Alfredo-Alfa-1-Windows.zip` (tag changed from name to numeric)
- **Fix**: Version updated, URL adjusted, hash recalculated

## Enhanced Features (Implemented)

### 1. Intelligent Checkver Regex Fixing
The autofix script now analyzes release tags and names to suggest corrected checkver patterns when the current pattern fails:
- Detects version number format from release tags
- Suggests appropriate regex patterns (e.g., `v\d+`, `\d+[\.\d]*`)
- Helps manifests with version scheme changes

### 2. Multi-Platform Repository Support
Extended support beyond GitHub to include:
- **GitHub**: `https://api.github.com/repos/:owner/:repo/releases/tags/:version`
- **GitLab**: `https://gitlab.com/api/v4/projects/:id/releases/:version`
- **Gitea**: Custom Gitea instance API support

Manifests can now specify:
```json
"checkver": {
  "gitlab": "https://gitlab.com/user/repo"
}
```
or
```json
"checkver": {
  "gitea": "https://gitea.example.com/user/repo"
}
```

### 3. Hash Mismatch Detection
Automatically detects when stored hashes don't match downloaded files:
- Verifies each downloaded file's SHA256
- Reports mismatches with expected vs actual hashes
- Auto-recomputes correct hash
- Useful for corrupted downloads or upstream changes

### 4. Manifest Structure Validation
Validates manifest JSON structure and auto-repairs:
- Checks for required fields (version, url, autoupdate, checkver)
- Detects missing autoupdate with checkver present (or vice versa)
- Logs structural issues for manual review
- Prevents invalid manifests from being committed

### 5. Issue Notification System
Comprehensive issue logging and notification:
- Tracks all detected issues with severity levels
- Logs issues to file for notification systems
- Exit code 2 indicates manual review needed
- Issues stored with timestamp and app name for tracking

Example issue log format:
```json
{
  "Title": "Structure Error",
  "Description": "Missing 'autoupdate' section",
  "Severity": "error",
  "App": "example-app",
  "Timestamp": "2025-11-19T10:30:45"
}
```

### 6. Manual Review Workflow
Complete workflow for handling edge cases:
- Script returns exit code 2 when manual review needed
- Issues logged with full context
- Can integrate with GitHub Issues or notification webhooks
- Preserves manifest integrity while flagging problems

## Usage with New Features

### Basic Usage (Unchanged)
```powershell
.\bin\autofix-manifest.ps1 -ManifestPath bucket/app.json
```

### Enable Notifications
```powershell
.\bin\autofix-manifest.ps1 `
  -ManifestPath bucket/app.json `
  -IssueLog issues.log `
  -NotifyOnIssues
```

### Integration in Workflow
```yaml
- name: Auto-fix manifests
  run: |
    $manifests = Get-ChildItem -Path my_bucket/bucket -Name *.json
    foreach ($manifest in $manifests) {
      .\bin\autofix-manifest.ps1 `
        -ManifestPath "my_bucket/bucket/$manifest" `
        -IssueLog issues.log `
        -NotifyOnIssues
    }
```

## Configuration

Edit `.github/workflows/excavator.yml`:
- Change cron schedule for different run frequency
- Add `GITHUB_TOKEN` secret if not already present
- Configure git user (currently "Scoop Auto-Updater")

## Troubleshooting

### Manifests not updating
1. Check if checkver is working: `.\bin\update-manifest.ps1 -ManifestPath bucket/app.json -Verbose`
2. Check if autoupdate section exists: `Get-Content bucket/app.json | ConvertFrom-Json | Select autoupdate`
3. Verify GitHub token has write access to repository

### Failed auto-fixes
- Script falls back to manual review notifications
- Check script output for specific error messages
- Update manifest checkver pattern if regex no longer matches releases
