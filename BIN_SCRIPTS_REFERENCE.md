# PowerShell Scripts Reference

Quick reference for all PowerShell scripts in the `bin/` directory.

## Manifest Creation & Automation

### create-emulator-manifest.ps1
**Purpose**: Automatically create complete emulator manifests from GitHub repositories.

**Usage**:
```powershell
# Create from GitHub URL
.\bin\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/owner/repo"

# Create from GitHub issue
.\bin\create-emulator-manifest.ps1 -IssueNumber 123 -GitHubToken "ghp_..."

# Skip confirmations
.\bin\create-emulator-manifest.ps1 -GitHubUrl "..." -AutoApprove
```

**Features**:
- Auto-detects platform (Nintendo, PlayStation, etc.)
- Monitors runtime for created files
- Generates portable mode setup
- Creates data migration script
- Updates GitHub issues

**Time**: 2-5 minutes per manifest

---

### handle-issue.ps1
**Purpose**: Process GitHub issues for manifest creation or bugfixes.

**Usage**:
```powershell
# Process specific issue
.\bin\handle-issue.ps1 -IssueNumber 123 -GitHubToken "token"

# Detect and process request issues
.\bin\handle-issue.ps1 -GitHubToken "token"
```

**Features**:
- Detects manifest requests automatically
- Routes to create-emulator-manifest.ps1
- Fixes broken manifests
- Posts results to issues
- Handles Copilot assistance

---

## Validation Scripts

### checkver.ps1
**Purpose**: Test version detection configuration.

**Usage**:
```powershell
# Check specific manifest
.\bin\checkver.ps1 -App gopher64 -Dir bucket

# Check all manifests
.\bin\checkver.ps1 -Dir bucket
```

**Output**: Latest detected version

**Must Pass**: Before autoupdate works

---

### check-autoupdate.ps1
**Purpose**: Validate autoupdate configuration is correct.

**Usage**:
```powershell
.\bin\check-autoupdate.ps1 -ManifestPath bucket\gopher64.json
```

**Checks**:
- Architecture URLs are valid
- Version placeholder `$version` exists
- Hash placeholder `$sha256` exists

**Must Pass**: Before using autoupdate

---

### check-manifest-install.ps1
**Purpose**: Test that manifest actually installs correctly.

**Usage**:
```powershell
.\bin\check-manifest-install.ps1 -ManifestPath bucket\gopher64.json
```

**Steps**:
1. Downloads executable
2. Verifies hash
3. Installs app
4. Runs post-install scripts
5. Uninstalls and cleans up

**Must Pass**: Before committing manifest

---

### checkurls.ps1
**Purpose**: Verify all download URLs are accessible.

**Usage**:
```powershell
.\bin\checkurls.ps1 -App gopher64 -Dir bucket
```

**Detects**: 404 errors, broken links, redirects

**Recommended**: Before committing

---

### checkhashes.ps1
**Purpose**: Verify SHA256 hashes match actual files.

**Usage**:
```powershell
.\bin\checkhashes.ps1 -App gopher64 -Dir bucket
```

**Detects**: Hash mismatches, corrupted downloads

**Recommended**: Before committing

---

## Manifest Management

### update-manifest.ps1
**Purpose**: Update version and hashes from latest release.

**Usage**:
```powershell
# Preview changes (dry-run)
.\bin\update-manifest.ps1 -ManifestPath bucket\gopher64.json

# Apply updates
.\bin\update-manifest.ps1 -ManifestPath bucket\gopher64.json -Update

# Apply without confirmation
.\bin\update-manifest.ps1 -ManifestPath bucket\gopher64.json -Update -Force
```

**Updates**:
- Latest version number
- Download URLs
- SHA256 hashes

**Note**: For simple version bumps, don't use update-manifest.ps1

---

### autofix-manifest.ps1
**Purpose**: Automatically repair broken or outdated manifests.

**Usage**:
```powershell
# Auto-fix broken manifest
.\bin\autofix-manifest.ps1 -ManifestPath bucket\gopher64.json

# With GitHub integration
.\bin\autofix-manifest.ps1 -ManifestPath bucket\gopher64.json `
  -GitHubToken "token" -NotifyOnIssues
```

**Repairs**:
- Version format mismatches
- Broken URLs
- Missing hashes
- Outdated checkver config

**Success Rate**: ~95% for common issues

---

## Utility Scripts

### formatjson.ps1
**Purpose**: Format and validate JSON structure.

**Usage**:
```powershell
# Format all manifests
.\bin\formatjson.ps1

# Format specific bucket
.\bin\formatjson.ps1 -Dir .\bucket
```

**Ensures**:
- Proper indentation
- Valid JSON structure
- Consistent formatting

**Recommended**: Before committing

---

### missing-checkver.ps1
**Purpose**: Find manifests without version detection.

**Usage**:
```powershell
.\bin\missing-checkver.ps1 -Dir bucket
```

**Output**: List of manifests needing checkver configuration

**Action**: Add checkver to identified manifests

---

### validate-and-merge.ps1
**Purpose**: Run all validation tests and auto-merge on success.

**Usage**:
```powershell
.\bin\validate-and-merge.ps1 -ManifestPath bucket\gopher64.json `
  -PullRequestNumber 123 -GitHubToken "token" -GitHubRepo "owner/repo"
```

**Steps**:
1. Runs checkver, check-autoupdate, check-manifest-install
2. Posts results to PR
3. Auto-merges if all pass
4. Requests Copilot fixes if failed

**Used By**: GitHub Actions

---

### auto-pr.ps1
**Purpose**: Create pull requests for manifest updates.

**Usage**:
```powershell
# Create PRs to default upstream
.\bin\auto-pr.ps1

# Create PRs to custom upstream
.\bin\auto-pr.ps1 -upstream "username/fork:develop"
```

**Upstream Default**: borger/scoop-emulators:master

**Used By**: Automated update workflows

---

### test.ps1
**Purpose**: Run all Pester tests for the bucket.

**Usage**:
```powershell
.\bin\test.ps1
```

**Requirements**:
- Pester 5.2.0+
- BuildHelpers 2.0.1+

**Output**: Test results summary

---

## Typical Workflows

### ✅ Creating a New Manifest
```powershell
# 1. Create manifest
.\bin\create-emulator-manifest.ps1 -GitHubUrl "https://github.com/..."

# 2. Run all validation tests (must all pass)
.\bin\checkver.ps1 -Dir bucket -App appname
.\bin\check-autoupdate.ps1 -ManifestPath bucket\appname.json
.\bin\check-manifest-install.ps1 -ManifestPath bucket\appname.json

# 3. Commit
git add bucket\appname.json
git commit -m "feat(appname): add manifest"
git push
```

### ✅ Updating an Existing Manifest
```powershell
# 1. Update to latest version
.\bin\update-manifest.ps1 -ManifestPath bucket\appname.json -Update

# 2. Validate
.\bin\checkver.ps1 -Dir bucket -App appname
.\bin\check-manifest-install.ps1 -ManifestPath bucket\appname.json

# 3. Commit
git add bucket\appname.json
git commit -m "chore(appname): update to latest version"
git push
```

### ✅ Fixing a Broken Manifest
```powershell
# 1. Auto-fix
.\bin\autofix-manifest.ps1 -ManifestPath bucket\appname.json

# 2. Validate
.\bin\check-manifest-install.ps1 -ManifestPath bucket\appname.json

# 3. Commit
git add bucket\appname.json
git commit -m "fix(appname): repair manifest"
git push
```

### ✅ Processing GitHub Issues
```powershell
# 1. When someone files a manifest request issue:
.\bin\handle-issue.ps1 -IssueNumber 123 -GitHubToken "token"

# 2. System automatically:
# - Creates manifest
# - Updates issue with results
# - Adds success labels
```

---

## Getting Help

All scripts have built-in help:

```powershell
# View synopsis
Get-Help .\bin\checkver.ps1

# View full help
Get-Help .\bin\checkver.ps1 -Full

# View examples
Get-Help .\bin\checkver.ps1 -Examples
```

---

## Exit Codes

Scripts use these exit codes:

- **0** - Success
- **1** - General error
- **-1** - Validation failed

---

## Environment Variables

**SCOOP_HOME** - Path to Scoop installation (auto-detected if not set)

**GITHUB_TOKEN** - GitHub API token (used by handle-issue.ps1, validate-and-merge.ps1)

**GITHUB_REPOSITORY** - Repository in format "owner/repo" (for GitHub Actions)

---

## Quick Tips

1. **Before committing**, run: `.\bin\check-manifest-install.ps1`
2. **For format issues**, run: `.\bin\formatjson.ps1`
3. **For version updates**, run: `.\bin\update-manifest.ps1 -Update`
4. **For broken manifests**, run: `.\bin\autofix-manifest.ps1`
5. **For new requests**, the system processes automatically

---

For detailed documentation, see:
- MANIFEST_CREATION.md - Full feature guide
- QUICKSTART.md - Quick reference
- AUTOMATION_SUMMARY.md - System overview
