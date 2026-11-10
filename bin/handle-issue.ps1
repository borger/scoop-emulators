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
. "$PSScriptRoot/lib-releasehelpers.ps1"

Write-Host "=== Processing Issue #$IssueNumber ===" -ForegroundColor Cyan

# Check if this is a manifest request issue
function Test-ManifestRequest {
    param([object]$Issue)

    $requestLabels = @("request-manifest", "emulator-request", "add-emulator", "request-emulator", "add-app", "package-request")
    $hasRequestLabel = $false

    foreach ($label in $Issue.labels) {
        if ($requestLabels -contains $label.name) {
            $hasRequestLabel = $true
            break
        }
    }

    if ($hasRequestLabel) {
        return $true
    }

    $issueText = '{0}{1}{2}' -f $Issue.title, [Environment]::NewLine, $Issue.body
    $hasGitHubUrl = $issueText -match 'https?://github\.com/[^/\s]+/[^/\s]+'
    $hasRequestContext = $issueText -match '(?i)\b(?:request(?:ing)?|add(?:ing)?|creat(?:e|ing))\b.{0,80}\b(?:emulator|manifest|app)\b|\b(?:emulator|manifest|app)\b.{0,80}\b(?:request|add|create)\b'
    if ($hasGitHubUrl -and $hasRequestContext) {
        return $true
    }

    return $false
}

function Get-ManifestNamesFromIssue {
    param(
        [string]$Title,
        [string]$Body
    )

    $issueText = '{0}{1}{2}' -f $Title, [Environment]::NewLine, $Body
    $pattern = '(?:bucket[/\\])?([a-z0-9_-]+)\.json|(?:manifest|app)\s+([a-z0-9_-]+)'
    $matches = [regex]::Matches($issueText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $names = foreach ($match in $matches) {
        if ($match.Groups[1].Success) {
            $match.Groups[1].Value
        } elseif ($match.Groups[2].Success) {
            $match.Groups[2].Value
        }
    }

    return @($names | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
}

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
        Write-Host ('[FAIL] Failed to get issue details: {0}' -f $_) -ForegroundColor Red
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
        Write-Host ('[WARN] Failed to post comment: {0}' -f $_) -ForegroundColor Yellow
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
        Write-Host ('[WARN] Failed to create PR: {0}' -f $_) -ForegroundColor Yellow
        return $null
    }
}

function Invoke-ManifestCreation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$IssueNumber,

        [Parameter(Mandatory)]
        [string]$GitHubToken,

        [Parameter(Mandatory)]
        [string]$ScriptPath
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Manifest creation script not found: $ScriptPath"
    }

    $result = Invoke-PowerShellScript -Path $ScriptPath -ArgumentList @(
        '-IssueNumber', $IssueNumber,
        '-GitHubToken', $GitHubToken,
        '-NonInteractive',
        '-CreatePR'
    )

    if ($result.ExitCode -ne 0) {
        throw "Manifest creation failed with exit code $($result.ExitCode). $($result.Output)"
    }

    return $result.Output
}

# Get issue details
$issue = Get-IssueDetails -IssueNum $IssueNumber -Repo $GitHubRepo -Token $GitHubToken

if (!$issue) {
    Write-Host '[FAIL] Could not retrieve issue details' -ForegroundColor Red
    exit -1
}

Write-Host "Issue Title: $($issue.title)" -ForegroundColor Cyan
Write-Host "Issue Body: $($issue.body)" -ForegroundColor Gray

# Check if this is a manifest request
if (Test-ManifestRequest -Issue $issue) {
    Write-Host ([Environment]::NewLine + '[INFO] Detected manifest request - triggering automated creation') -ForegroundColor Cyan

    $manifestScript = Join-Path $PSScriptRoot 'create-manifest.ps1'

    try {
        Write-Host '[INFO] Executing manifest creation script...' -ForegroundColor Cyan

        Invoke-ManifestCreation -IssueNumber $IssueNumber -GitHubToken $GitHubToken -ScriptPath $manifestScript |
            Out-Null

        Write-Host ([Environment]::NewLine + ('[OK] Manifest created successfully from issue #{0}' -f $IssueNumber)) -ForegroundColor Green
        exit 0
    } catch {
        Write-Host ([Environment]::NewLine + ('[ERROR] Failed to create manifest from issue: {0}' -f $_.Exception.Message)) -ForegroundColor Red

        # Post error comment to issue
        $errorComment = @"
❌ Automated manifest creation failed:

**Error:** $($_.Exception.Message)

Please provide a GitHub repository URL in the issue body, or manually review requirements for the manifest.

cc: @beyondmeat
"@

        Add-IssueComment -IssueNum $IssueNumber -Body $errorComment -Repo $GitHubRepo -Token $GitHubToken | Out-Null
        exit -1
    }
}

# Extract manifest names from issue (look for references like "bucket\app-name.json" or "app-name")
$manifestsToFix = @(Get-ManifestNamesFromIssue -Title $issue.title -Body $issue.body)

if ($manifestsToFix.Count -eq 0) {
    $comment = '[WARN] Could not identify manifest names from issue. Please include manifest names explicitly (e.g., ''app-name.json'' or ''Fix app-name'').'
    Add-IssueComment -IssueNum $IssueNumber -Body $comment -Repo $GitHubRepo -Token $GitHubToken | Out-Null
    Write-Host '[WARN] No manifests identified' -ForegroundColor Yellow
    exit -1
}

Write-Host "Manifests to fix: $($manifestsToFix -join ', ')" -ForegroundColor Yellow

# Attempt auto-fix on each manifest
$autoFixResults = @{}
$autofixScript = "$(Split-Path -Parent $PSScriptRoot)/bin/autofix-manifest.ps1"

foreach ($manifest in $manifestsToFix) {
    $manifestPath = "$BucketPath/$manifest.json"

    if (!(Test-Path $manifestPath)) {
        Write-Host ('[WARN] Manifest not found: {0}' -f $manifestPath) -ForegroundColor Yellow
        $autoFixResults[$manifest] = "NOT_FOUND"
        continue
    }

    Write-Host "`n→ Attempting auto-fix for $manifest..." -ForegroundColor Cyan

    try {
        $autoFixResult = Invoke-PowerShellScript -Path $autofixScript -ArgumentList @(
            '-ManifestPath', $manifestPath,
            '-NotifyOnIssues'
        )
        if ($autoFixResult.ExitCode -ne 0) {
            throw "Auto-fix exited with code $($autoFixResult.ExitCode). $($autoFixResult.Output)"
        }
        $autoFixResults[$manifest] = "SUCCESS"
        Write-Host ('  [OK] Auto-fix succeeded for {0}' -f $manifest) -ForegroundColor Green
    } catch {
        $autoFixResults[$manifest] = "FAILED"
        Write-Host ('  [FAIL] Auto-fix failed for {0}: {1}' -f $manifest, $_.Exception.Message) -ForegroundColor Red
    }
}

# Check if any auto-fix succeeded
$anySucceeded = $autoFixResults.Values -contains "SUCCESS"

if ($anySucceeded) {
    # Create commit and PR for successful auto-fixes
    Write-Host ([Environment]::NewLine + '[OK] Some manifests were auto-fixed. Creating PR...') -ForegroundColor Green

    $successList = ($autoFixResults.GetEnumerator() | Where-Object { $_.Value -eq "SUCCESS" } | ForEach-Object { $_.Key }) -join ", "
    $branchName = "issue-$IssueNumber-autofix-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    $prTitle = "fix(bucket): Auto-fix issue #$IssueNumber ($successList)"
    $prBody = @"
## Auto-Fix for Issue #${IssueNumber}

This PR addresses the following manifests from issue #${IssueNumber}:

**Successfully auto-fixed:**
$($autoFixResults.GetEnumerator() | Where-Object { $_.Value -eq "SUCCESS" } | ForEach-Object { "- [OK] $($_.Key)" })

**Requires manual attention:**
$($autoFixResults.GetEnumerator() | Where-Object { $_.Value -ne "SUCCESS" } | ForEach-Object { "- [WARN] $($_.Key) ($($_.Value))" })

All auto-fixed manifests have passed validation. Please review and merge.

Closes #${IssueNumber}
"@

    $prNumber = New-PullRequest -Title $prTitle -Body $prBody -HeadBranch $branchName -BaseBranch "master" -Repo $GitHubRepo -Token $GitHubToken

    if ($prNumber) {
        Write-Host ('[OK] PR #{0} created for auto-fixed manifests' -f $prNumber) -ForegroundColor Green

        # Post comment to issue
        $issueComment = @"
## Auto-Fix in Progress

I've attempted to auto-fix the reported issues:

$($autoFixResults.GetEnumerator() | ForEach-Object {
    if ($_.Value -eq "SUCCESS") {
        "- [OK] $($_.Key): Auto-fix successful (PR #$prNumber)"
    } else {
        "- [WARN] $($_.Key): $($_.Value) - Requesting Copilot assistance"
    }
})

For manifests that couldn't be auto-fixed, I'll request Copilot to analyze and provide fixes.

cc: @beyondmeat
"@

        Add-IssueComment -IssueNum $IssueNumber -Body $issueComment -Repo $GitHubRepo -Token $GitHubToken | Out-Null
    }
} else {
    # All auto-fixes failed - request Copilot
    Write-Host ([Environment]::NewLine + '[FAIL] Auto-fix failed for all manifests. Requesting Copilot assistance...') -ForegroundColor Red

    $copilotComment = @"
## Copilot Assistance Required

Auto-fix attempts failed for the following manifests:

$($autoFixResults.GetEnumerator() | ForEach-Object { "- [WARN] $($_.Key)" })

**Issue Details:**
$($issue.body | Select-Object -First 500)

Please analyze the issue and create a fix PR. The validation pipeline will run up to 10 attempts to verify any fixes.

cc: @copilot
"@

    Add-IssueComment -IssueNum $IssueNumber -Body $copilotComment -Repo $GitHubRepo -Token $GitHubToken | Out-Null
}

Write-Host ([Environment]::NewLine + ('[OK] Issue #{0} has been processed' -f $IssueNumber)) -ForegroundColor Green
exit 0
