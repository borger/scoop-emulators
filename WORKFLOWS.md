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
