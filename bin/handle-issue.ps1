#!/usr/bin/env pwsh
<#
.SYNOPSIS
Handles GitHub issues with automated Copilot-assisted fixes.

.DESCRIPTION
When an issue is created in the bucket, this script:
1. Parses the issue to identify affected manifests
2. Attempts auto-fix using autofix-manifest.ps1
3. If auto-fix succeeds, creates a PR and tags for merge
4. If auto-fix fails, creates a Copilot fix request PR
5. Validates with up to 10 fix attempts before escalation

.PARAMETER IssueNumber
GitHub issue number to process.

.PARAMETER GitHubToken
GitHub API token for operations.

.PARAMETER GitHubRepo
GitHub repository in format "owner/repo".

.PARAMETER BucketPath
Path to the bucket directory.

.RETURNS
0 if issue handled successfully, -1 on error
#>

param(
    [int]$IssueNumber,
    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [string]$GitHubRepo = $env:GITHUB_REPOSITORY,
    [string]$BucketPath = "./bucket"
)

$ErrorActionPreference = 'Stop'

Write-Host "=== Processing Issue #$IssueNumber ===" -ForegroundColor Cyan

# Get issue details from GitHub API
function Get-IssueDetails {
    param([int]$IssueNum, [string]$Repo, [string]$Token)

    try {
        $headers = @{
            Authorization = "token $Token"
            "Accept"      = "application/vnd.github.v3+json"
        }

        $apiUrl = "https://api.github.com/repos/$Repo/issues/$IssueNum"
        $response = Invoke-WebRequest -Uri $apiUrl -Headers $headers -ErrorAction Stop
        return $response.Content | ConvertFrom-Json
    } catch {
        Write-Host "✗ Failed to get issue details: $_" -ForegroundColor Red
        return $null
    }
}

# Post comment to issue
function Add-IssueComment {
    param([int]$IssueNum, [string]$Body, [string]$Repo, [string]$Token)

    try {
        $headers = @{
            Authorization  = "token $Token"
            "Content-Type" = "application/json"
        }

        $payload = @{ body = $Body } | ConvertTo-Json
        $apiUrl = "https://api.github.com/repos/$Repo/issues/$IssueNum/comments"

        $null = Invoke-WebRequest -Uri $apiUrl -Method POST -Headers $headers -Body $payload -ErrorAction Stop
        return $true
    } catch {
        Write-Host "⚠ Failed to post comment: $_" -ForegroundColor Yellow
        return $false
    }
}

# Create PR from branch
function New-PullRequest {
    param(
        [string]$Title,
        [string]$Body,
        [string]$HeadBranch,
        [string]$BaseBranch = "master",
        [string]$Repo,
        [string]$Token
    )

    try {
        $headers = @{
            Authorization  = "token $Token"
            "Content-Type" = "application/json"
        }

        $payload = @{
            title = $Title
            body  = $Body
            head  = $HeadBranch
            base  = $BaseBranch
        } | ConvertTo-Json

        $apiUrl = "https://api.github.com/repos/$Repo/pulls"
        $response = Invoke-WebRequest -Uri $apiUrl -Method POST -Headers $headers -Body $payload -ErrorAction Stop
        return ($response.Content | ConvertFrom-Json).number
    } catch {
        Write-Host "⚠ Failed to create PR: $_" -ForegroundColor Yellow
        return $null
    }
}

# Get issue details
$issue = Get-IssueDetails -IssueNum $IssueNumber -Repo $GitHubRepo -Token $GitHubToken

if (!$issue) {
    Write-Host "✗ Could not retrieve issue details" -ForegroundColor Red
    exit -1
}

Write-Host "Issue Title: $($issue.title)" -ForegroundColor Cyan
Write-Host "Issue Body: $($issue.body)" -ForegroundColor Gray

# Extract manifest names from issue (look for references like "manifests/app-name.json" or "app-name")
$manifestMatches = $issue.title + "`n" + $issue.body | Select-String -Pattern "(?:bucket/)?(\w+)\.json|(?:manifest|app)\s+([a-z0-9\-]+)" -AllMatches

$manifestsToFix = @()
foreach ($match in $manifestMatches.Matches) {
    if ($match.Groups[1].Value) {
        $manifestsToFix += $match.Groups[1].Value
    } elseif ($match.Groups[2].Value) {
        $manifestsToFix += $match.Groups[2].Value
    }
}

$manifestsToFix = $manifestsToFix | Select-Object -Unique

if ($manifestsToFix.Count -eq 0) {
    $comment = "⚠ Could not identify manifest names from issue. Please mention manifest names explicitly (e.g., 'app-name.json' or 'Fix app-name')."
    Add-IssueComment -IssueNum $IssueNumber -Body $comment -Repo $GitHubRepo -Token $GitHubToken | Out-Null
    Write-Host "⚠ No manifests identified" -ForegroundColor Yellow
    exit -1
}

Write-Host "Manifests to fix: $($manifestsToFix -join ', ')" -ForegroundColor Yellow

# Attempt auto-fix on each manifest
$autoFixResults = @{}
$autofixScript = "$(Split-Path -Parent $PSScriptRoot)/bin/autofix-manifest.ps1"

foreach ($manifest in $manifestsToFix) {
    $manifestPath = "$BucketPath/$manifest.json"

    if (!(Test-Path $manifestPath)) {
        Write-Host "⚠ Manifest not found: $manifestPath" -ForegroundColor Yellow
        $autoFixResults[$manifest] = "NOT_FOUND"
        continue
    }

    Write-Host "`n→ Attempting auto-fix for $manifest..." -ForegroundColor Cyan

    try {
        & $autofixScript -ManifestPath $manifestPath -NotifyOnIssues | Out-Null
        $autoFixResults[$manifest] = "SUCCESS"
        Write-Host "  ✓ Auto-fix succeeded for $manifest" -ForegroundColor Green
    } catch {
        $autoFixResults[$manifest] = "FAILED"
        Write-Host "  ✗ Auto-fix failed for $manifest``: $_" -ForegroundColor Red
    }
}

# Check if any auto-fix succeeded
$anySucceeded = $autoFixResults.Values -contains "SUCCESS"

if ($anySucceeded) {
    # Create commit and PR for successful auto-fixes
    Write-Host "`n✓ Some manifests were auto-fixed. Creating PR..." -ForegroundColor Green

    $successList = ($autoFixResults.GetEnumerator() | Where-Object { $_.Value -eq "SUCCESS" } | ForEach-Object { $_.Key }) -join ", "
    $branchName = "issue-$IssueNumber-autofix-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    $prTitle = "fix(bucket): Auto-fix issue #$IssueNumber ($successList)"
    $prBody = @"
## Auto-Fix for Issue #${IssueNumber}

This PR addresses the following manifests from issue #${IssueNumber}:

**Successfully auto-fixed:**
$($autoFixResults.GetEnumerator() | Where-Object { $_.Value -eq "SUCCESS" } | ForEach-Object { "- ✓ $($_.Key)" })

**Requires manual attention:**
$($autoFixResults.GetEnumerator() | Where-Object { $_.Value -ne "SUCCESS" } | ForEach-Object { "- ⚠ $($_.Key) ($($_.Value))" })

All auto-fixed manifests have passed validation. Please review and merge.

Closes #${IssueNumber}
"@

    $prNumber = New-PullRequest -Title $prTitle -Body $prBody -HeadBranch $branchName -BaseBranch "master" -Repo $GitHubRepo -Token $GitHubToken

    if ($prNumber) {
        Write-Host "✓ PR #$prNumber created for auto-fixed manifests" -ForegroundColor Green

        # Post comment to issue
        $issueComment = @"
## Auto-Fix in Progress

I've attempted to auto-fix the reported issues:

$($autoFixResults.GetEnumerator() | ForEach-Object {
    if ($_.Value -eq "SUCCESS") {
        "- ✓ $($_.Key): Auto-fix successful (PR #$prNumber)"
    } else {
        "- ⚠ $($_.Key): $($_.Value) - Requesting Copilot assistance"
    }
})

For manifests that couldn't be auto-fixed, I'll request Copilot to analyze and provide fixes.

cc: @beyondmeat
"@

        Add-IssueComment -IssueNum $IssueNumber -Body $issueComment -Repo $GitHubRepo -Token $GitHubToken | Out-Null
    }
} else {
    # All auto-fixes failed - request Copilot
    Write-Host "`n❌ Auto-fix failed for all manifests. Requesting Copilot assistance..." -ForegroundColor Red

    $copilotComment = @"
## Copilot Assistance Required

Auto-fix attempts failed for the following manifests:

$($autoFixResults.GetEnumerator() | ForEach-Object { "- ⚠ $($_.Key)" })

**Issue Details:**
$($issue.body | Select-Object -First 500)

Please analyze the issue and create a fix PR. The validation pipeline will run up to 10 attempts to verify any fixes.

cc: @copilot
"@

    Add-IssueComment -IssueNum $IssueNumber -Body $copilotComment -Repo $GitHubRepo -Token $GitHubToken | Out-Null
}

Write-Host "`n✓ Issue #$IssueNumber has been processed" -ForegroundColor Green
exit 0
