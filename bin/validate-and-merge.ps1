#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Validates manifest changes and auto-merges PR if all checks pass.

.DESCRIPTION
    Orchestrates the validation pipeline for Scoop manifests in a CI/CD context.
    1. Runs checkver, check-autoupdate, and check-manifest-install.
    2. Posts results to the GitHub PR.
    3. Auto-merges if successful (for Copilot PRs) or tags maintainers (for User PRs).
    4. Requests fixes from Copilot if validation fails.

.PARAMETER ManifestPath
    Path to the manifest file.

.PARAMETER BucketPath
    Path to the bucket root.

.PARAMETER PullRequestNumber
    GitHub PR ID.

.PARAMETER GitHubToken
    GitHub API Token.

.PARAMETER GitHubRepo
    Repository slug (owner/repo).
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [string]$BucketPath = (Split-Path -Parent (Split-Path -Parent $ManifestPath)),

    [Parameter(Mandatory = $true)]
    [int]$PullRequestNumber,

    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [string]$GitHubRepo = $env:GITHUB_REPOSITORY,
    [int]$MaxRetries = 10,
    [bool]$IsUserPR = $false,
    [bool]$FromIssue = $false
)

$ErrorActionPreference = 'Stop'

# Ensure TLS 1.2 is enabled (critical for PS 5.1)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# --- Helpers ---

function Invoke-GitHubApi {
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [object]$Body
    )

    $headers = @{
        Authorization  = "token $GitHubToken"
        "Content-Type" = "application/json"
        "Accept"       = "application/vnd.github.v3+json"
    }

    $params = @{
        Uri             = $Uri
        Method          = $Method
        Headers         = $headers
        ErrorAction     = 'Stop'
        UseBasicParsing = $true # Required for PS 5.1
    }

    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }

    try {
        Invoke-WebRequest @params | Out-Null
        return $true
    } catch {
        Write-Warning "GitHub API call failed: $($_.Exception.Message)"
        return $false
    }
}

function Publish-PRComment {
    param([string]$Body)
    $url = "https://api.github.com/repos/$GitHubRepo/issues/$PullRequestNumber/comments"
    Invoke-GitHubApi -Uri $url -Method POST -Body @{ body = $Body }
}

function Merge-PR {
    param([string]$Title, [string]$Message)
    $url = "https://api.github.com/repos/$GitHubRepo/pulls/$PullRequestNumber/merge"
    $body = @{
        commit_title   = $Title
        commit_message = $Message
        merge_method   = "squash"
    }
    Invoke-GitHubApi -Uri $url -Method PUT -Body $body
}

# --- Main Logic ---

$appName = [System.IO.Path]::GetFileNameWithoutExtension($ManifestPath)
$binDir = Join-Path (Split-Path -Parent $PSScriptRoot) "bin"

Write-Host "=== Validating PR #$PullRequestNumber for $appName ===" -ForegroundColor Cyan

$results = @{
    CheckVer        = @{ Status = "PENDING"; Output = "" }
    CheckAutoupdate = @{ Status = "PENDING"; Output = "" }
    CheckInstall    = @{ Status = "PENDING"; Output = "" }
}

# Define validation tasks
$validationTasks = @(
    @{
        Id        = "CheckVer"
        Label     = "Checkver"
        Command   = "$binDir/checkver.ps1"
        Arguments = @("-App", $appName, "-Dir", $BucketPath)
    },
    @{
        Id        = "CheckAutoupdate"
        Label     = "Autoupdate"
        Command   = "$binDir/check-autoupdate.ps1"
        Arguments = @("-ManifestPath", $ManifestPath)
    }
)

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Write-Host "`n[1-2/3] Running validation checks in parallel (PS 7+)..." -ForegroundColor Yellow

    $taskResults = $validationTasks | ForEach-Object -Parallel {
        $task = $_
        $result = @{ Id = $task.Id; Status = "FAIL"; Output = "" }
        $ErrorActionPreference = 'Stop'

        try {
            & $task.Command @($task.Arguments) *>$null
            if ($LASTEXITCODE -ne 0) { throw "Exited with code $LASTEXITCODE" }
            $result.Status = "PASS"
        } catch {
            $result.Output = $_.Exception.Message
        }
        return $result
    }

    foreach ($res in $taskResults) {
        $results[$res.Id].Status = $res.Status
        $results[$res.Id].Output = $res.Output
        if ($res.Status -eq "PASS") {
            Write-Host "  [OK] $($res.Id) passed" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] $($res.Id) failed" -ForegroundColor Red
        }
    }
} else {
    Write-Host "`n[1-2/3] Running validation checks sequentially (PS 5.1)..." -ForegroundColor Yellow

    foreach ($task in $validationTasks) {
        Write-Host "Running $($task.Label)..." -NoNewline
        try {
            & $task.Command @($task.Arguments) *>$null
            if ($LASTEXITCODE -ne 0) { throw "Exited with code $LASTEXITCODE" }
            $results[$task.Id].Status = "PASS"
            Write-Host " [OK]" -ForegroundColor Green
        } catch {
            $results[$task.Id].Status = "FAIL"
            $results[$task.Id].Output = $_.Exception.Message
            Write-Host " [FAIL]" -ForegroundColor Red
        }
    }
}

# 3. Install
Write-Host "[3/3] Running installation test..." -ForegroundColor Yellow
try {
    & "$binDir/check-manifest-install.ps1" -ManifestPath $ManifestPath | Out-Null
    $results.CheckInstall.Status = "PASS"
    Write-Host "  [OK] Installation test passed" -ForegroundColor Green
} catch {
    $results.CheckInstall.Status = "FAIL"
    $results.CheckInstall.Output = $_.Exception.Message
    Write-Host "  [FAIL] Installation failed" -ForegroundColor Red
}

# Evaluate
$allPassed = ($results.CheckVer.Status -eq 'PASS') -and
($results.CheckAutoupdate.Status -eq 'PASS') -and
($results.CheckInstall.Status -eq 'PASS')

# Build Report
$icon = if ($allPassed) { "✅" } else { "❌" }
$report = @"
## $icon Validation Report: \`$appName\`

| Test | Status | Details |
|------|--------|---------|
| **Checkver** | $($results.CheckVer.Status) | $($results.CheckVer.Output) |
| **Autoupdate** | $($results.CheckAutoupdate.Status) | $($results.CheckAutoupdate.Output) |
| **Install** | $($results.CheckInstall.Status) | $($results.CheckInstall.Output) |

**Timestamp**: $([DateTime]::UtcNow.ToString('u'))
"@

Publish-PRComment -Body $report | Out-Null

if ($allPassed) {
    Write-Host "`n[SUCCESS] All checks passed." -ForegroundColor Green

    if ($IsUserPR) {
        Write-Host "User PR: Tagging maintainers." -ForegroundColor Cyan
        Publish-PRComment -Body "✅ Ready for merge. cc: @beyondmeat" | Out-Null
    } else {
        Write-Host "Copilot PR: Auto-merging." -ForegroundColor Cyan
        $mergeResult = Merge-PR -Title "fix(bucket): $appName validation passed" -Message "Auto-merged by validation pipeline."

        if ($mergeResult) {
            Write-Host "PR Merged." -ForegroundColor Green
        } else {
            Write-Error "Failed to merge PR."
            exit 1
        }
    }
    exit 0
} else {
    Write-Host "`n[FAILURE] Validation failed." -ForegroundColor Red

    $fixRequest = @"
## ⚠️ Validation Failed

Please analyze the report above and fix the issues.
- Checkver failures usually mean the regex needs updating.
- Autoupdate failures mean the download URL is broken.
- Install failures mean the package is invalid or conflicts exist.

cc: @copilot
"@
    Publish-PRComment -Body $fixRequest | Out-Null
    exit 1
}

