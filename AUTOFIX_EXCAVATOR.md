# Excavator Auto-Fix Enhancement

## Overview
The Excavator GitHub workflow has been enhanced to automatically detect and fix common manifest issues when they occur during version updates.

## How It Works

### 1. **Excavate Step** (Scoop Official)
- Runs the standard Scoop Excavator to check for updates
- Uses GitHub Actions from ScoopInstaller/GithubActions

### 2. **Auto-fix Step** (New)
- Runs `./bin/autofix-manifest.ps1` on all manifests (except nightly/dev)
- Detects issues and attempts to automatically fix them

### 3. **Commit Step**
- Commits any fixed manifests back to the repository
- Uses auto-updater service account credentials

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

## What Requires Manual Review

✗ Checkver pattern failures (regex doesn't match new format)
✗ Manifest structure changes (no autoupdate/checkver sections)
✗ Nightly/dev builds (intentionally skipped - no stable version)
✗ Projects with no GitHub releases

## Implementation Details

### autofix-manifest.ps1
```powershell
& .\bin\autofix-manifest.ps1 -ManifestPath bucket/app.json -BucketPath bucket
```

**Features:**
- Runs checkver to find latest version
- Attempts 3-tier URL fixing:
  1. Simple version substitution
  2. GitHub API release asset lookup
  3. Manual review fallback
- Downloads and calculates SHA256 hashes
- Updates manifest JSON
- Returns appropriate exit codes (0=fixed, 1=valid, -1=failed)

### Workflow Execution
```yaml
Excavate → Auto-fix broken → Commit changes → Push
```

Runs hourly via cron: `0 * * * *` (every hour at :00)

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

## Future Enhancements

- [ ] Intelligent checkver regex fixing based on release names
- [ ] Support for non-GitHub repositories (GitLab, Gitea, etc.)
- [ ] Hash mismatch detection and auto-recomputation
- [ ] Manifest structure validation and auto-repair
- [ ] Notification system for unfixable issues
- [ ] Manual review workflow for edge cases

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
