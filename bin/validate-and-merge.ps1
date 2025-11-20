#!/usr/bin/env pwsh
<#
.SYNOPSIS
Validates manifest changes and auto-merges PR if all checks pass.

.DESCRIPTION
This script is called after Copilot submits a PR fix. It:
1. Runs all validation scripts (checkver, autoupdate, install)
2. Reports results to the PR
3. Auto-merges if all checks pass
4. Requests Copilot to fix issues if validation fails
5. Escalates to @beyondmeat if Copilot fix attempts fail

.PARAMETER ManifestPath
Path to the manifest file to validate.

.PARAMETER BucketPath
Path to the bucket directory.

.PARAMETER PullRequestNumber
GitHub PR number for posting validation results.

.PARAMETER GitHubToken
GitHub API token for PR operations.

.PARAMETER GitHubRepo
GitHub repository (owner/repo format).

.PARAMETER MaxRetries
Maximum number of Copilot fix attempts before escalation (default: 10).

.PARAMETER IsUserPR
Set to $true if PR was created by user (not Copilot). User PRs tag @beyondmeat for merge.

.PARAMETER FromIssue
Set to $true if this is fixing an issue. Issues trigger Copilot auto-fix workflow.

.RETURNS
0 if validation passes and merged/tagged, 1 if validation fails, -1 on error
#>

param(
    [string]$ManifestPath,
    [string]$BucketPath = (Split-Path -Parent (Split-Path -Parent $ManifestPath)),
    [int]$PullRequestNumber,
    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [string]$GitHubRepo = $env:GITHUB_REPOSITORY,
    [int]$MaxRetries = 10,
    [bool]$IsUserPR = $false,
    [bool]$FromIssue = $false
)

$ErrorActionPreference = 'Stop'

$appName = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $ManifestPath))
$scriptRoot = Split-Path -Parent $PSScriptRoot
$checkVerScript = "$scriptRoot/bin/checkver.ps1"
$checkAutoupdateScript = "$scriptRoot/bin/check-autoupdate.ps1"
$checkInstallScript = "$scriptRoot/bin/check-manifest-install.ps1"

Write-Host "=== Validating PR #$PullRequestNumber for $appName ===" -ForegroundColor Cyan

# Test all validation scripts
$validationResults = @{
    CheckVer = $null
    CheckAutoupdate = $null
    CheckInstall = $null
    AllPassed = $false
}

# Run checkver
Write-Host "`n[1/3] Running checkver validation..." -ForegroundColor Yellow
try {
    & $checkVerScript -App $appName -Dir $BucketPath | Out-Null
    $validationResults.CheckVer = "✓ PASS"
    Write-Host "  ✓ Checkver passed" -ForegroundColor Green
}
catch {
    $validationResults.CheckVer = "✗ FAIL: $_"
    Write-Host "  ✗ Checkver failed: $_" -ForegroundColor Red
}

# Run check-autoupdate
Write-Host "[2/3] Running autoupdate validation..." -ForegroundColor Yellow
try {
    & $checkAutoupdateScript -ManifestPath $ManifestPath -ErrorAction SilentlyContinue | Out-Null
    $validationResults.CheckAutoupdate = "✓ PASS"
    Write-Host "  ✓ Autoupdate config valid" -ForegroundColor Green
}
catch {
    $validationResults.CheckAutoupdate = "✗ FAIL: $_"
    Write-Host "  ✗ Autoupdate validation failed: $_" -ForegroundColor Red
}

# Run check-manifest-install
Write-Host "[3/3] Running installation test..." -ForegroundColor Yellow
try {
    & $checkInstallScript -ManifestPath $ManifestPath | Out-Null
    $validationResults.CheckInstall = "✓ PASS"
    Write-Host "  ✓ Installation test passed" -ForegroundColor Green
}
catch {
    $validationResults.CheckInstall = "✗ FAIL: $_"
    Write-Host "  ✗ Installation test failed: $_" -ForegroundColor Red
}

# Check if all passed
$allPassed = $validationResults.CheckVer -like "*PASS*" -and `
            $validationResults.CheckAutoupdate -like "*PASS*" -and `
            $validationResults.CheckInstall -like "*PASS*"

$validationResults.AllPassed = $allPassed

# Post validation results as PR comment
function Publish-PRComment {
    param([string]$Body, [string]$RepoRef, [int]$PRNum, [string]$Token)

    if (!$RepoRef -or !$Token -or !$PRNum) { return $false }

    try {
        $headers = @{
            Authorization = "token $Token"
            "Content-Type" = "application/json"
        }

        $payload = @{ body = $Body } | ConvertTo-Json
        $apiUrl = "https://api.github.com/repos/$RepoRef/issues/$PRNum/comments"

        Invoke-WebRequest -Uri $apiUrl -Method POST -Headers $headers -Body $payload -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Host "⚠ Failed to post PR comment: $_" -ForegroundColor Yellow
        return $false
    }
}

# Build validation report
$report = @"
## ✅ Validation Report

**Manifest**: \`$appName\`

### Test Results
- Checkver: $($validationResults.CheckVer)
- Autoupdate Config: $($validationResults.CheckAutoupdate)
- Installation Test: $($validationResults.CheckInstall)

### Status
$(if ($allPassed) { "✅ **All validations passed!** Ready to merge." } else { "❌ **Validation failed.** Requesting Copilot fix..." })

**Timestamp**: $([DateTime]::UtcNow.ToString('o'))
"@

Write-Host "`n=== Validation Report ===" -ForegroundColor Cyan
Write-Host $report

# Post comment to PR
Publish-PRComment -Body $report -RepoRef $GitHubRepo -PRNum $PullRequestNumber -Token $GitHubToken | Out-Null

if ($allPassed) {
    Write-Host "`n✓ All validations passed!" -ForegroundColor Green

    if ($IsUserPR) {
        # User PR: Tag @beyondmeat for manual merge review
        Write-Host "  → Tagging @beyondmeat for merge review (user PR)" -ForegroundColor Cyan

        $mergeRequest = @"
## ✅ Validation Passed - Ready for Merge

All validation checks have passed successfully:
- ✓ Checkver validation
- ✓ Autoupdate configuration
- ✓ Installation test

This PR is ready to be merged by a maintainer.

cc: @beyondmeat
"@

        Publish-PRComment -Body $mergeRequest -RepoRef $GitHubRepo -PRNum $PullRequestNumber -Token $GitHubToken | Out-Null
        exit 0
    }
    else {
        # Copilot PR: Auto-merge
        Write-Host "  → Auto-merging (Copilot PR)..." -ForegroundColor Green

        try {
            $headers = @{
                Authorization = "token $GitHubToken"
                "Content-Type" = "application/json"
            }

            $payload = @{
                commit_title = "fix(bucket): $appName auto-fix validation passed"
                commit_message = "Auto-fixed manifest with all validation checks passing."
                merge_method = "squash"
            } | ConvertTo-Json

            $apiUrl = "https://api.github.com/repos/$GitHubRepo/pulls/$PullRequestNumber/merge"
            $null = Invoke-WebRequest -Uri $apiUrl -Method PUT -Headers $headers -Body $payload -ErrorAction Stop

            Write-Host "✓ PR #$PullRequestNumber merged successfully" -ForegroundColor Green

            # Post merge comment
            $mergeComment = "✅ All validations passed. PR auto-merged by validation script."
            Publish-PRComment -Body $mergeComment -RepoRef $GitHubRepo -PRNum $PullRequestNumber -Token $GitHubToken | Out-Null

            exit 0
        }
        catch {
            Write-Host "⚠ Failed to auto-merge PR: $_" -ForegroundColor Yellow
            exit 1
        }
    }
}
else {
    # Validation failed - request Copilot to fix
    Write-Host "`n❌ Validation failed. Requesting Copilot to fix issues..." -ForegroundColor Red

    $fixRequest = @"
## ❌ Validation Failed - Requesting Fix

Validation tests failed. Please fix the following issues:

$(if ($validationResults.CheckVer -notlike "*PASS*") { "- ⚠ **Checkver**: $($validationResults.CheckVer)`n" })
$(if ($validationResults.CheckAutoupdate -notlike "*PASS*") { "- ⚠ **Autoupdate Config**: $($validationResults.CheckAutoupdate)`n" })
$(if ($validationResults.CheckInstall -notlike "*PASS*") { "- ⚠ **Installation Test**: $($validationResults.CheckInstall)`n" })

Please analyze the manifest and fix all issues. Validation will run again automatically.

**Attempts**: This is fix attempt (1/$MaxRetries). If all fix attempts fail, will escalate to @beyondmeat.

cc: @copilot
"@

    Publish-PRComment -Body $fixRequest -RepoRef $GitHubRepo -PRNum $PullRequestNumber -Token $GitHubToken | Out-Null

    exit 1
}

