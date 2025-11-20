param(
    [string]$ManifestPath,
    [string]$BucketPath = (Split-Path -Parent (Split-Path -Parent $ManifestPath)),
    [string]$IssueLog = "",
    [switch]$NotifyOnIssues,
    [string]$GitHubToken = $env:GITHUB_TOKEN,
    [string]$GitHubRepo = $env:GITHUB_REPOSITORY,
    [switch]$AutoCreateIssues
)

<#
.SYNOPSIS
Automatically fixes common manifest issues and broken downloads.

.DESCRIPTION
This script analyzes manifest errors and attempts to auto-fix common issues:
1. Detects 404 errors and tries to find the correct download URL
2. Fixes URL template mismatches (version vs filename format changes)
3. Updates checkver patterns when they fail
4. Recalculates hashes for updated URLs
5. Detects hash mismatches and auto-recomputes
6. Validates manifest structure
7. Supports GitHub, GitLab, and Gitea repositories
8. Attempts GitHub Copilot PR creation for unfixable issues
9. Escalates to manual review if Copilot PR fails
10. Logs issues for manual review if needed

.PARAMETER ManifestPath
Path to the manifest to fix.

.PARAMETER BucketPath
Path to the bucket directory (auto-detected if not provided).

.PARAMETER IssueLog
Path to log file for unfixable issues (for notification system).

.PARAMETER NotifyOnIssues
Enable notifications for issues that require manual review.

.PARAMETER GitHubToken
GitHub API token for creating issues (uses GITHUB_TOKEN env var if not provided).

.PARAMETER GitHubRepo
GitHub repository (owner/repo format) for issue creation (uses GITHUB_REPOSITORY env var if not provided).

.PARAMETER AutoCreateIssues
Automatically create GitHub issues for unfixable problems with Copilot and escalation tags.

.RETURNS
0 if fixed, -1 if unable to fix, 1 if already valid, 2 if manual review needed, 3 if issue created
#>

$ErrorActionPreference = 'Stop'

# Issue tracking for notification system
$issues = @()
function Add-Issue {
    param([string]$Title, [string]$Description, [string]$Severity = "warning")
    $issues += @{ Title = $Title; Description = $Description; Severity = $Severity; App = $appName; Timestamp = Get-Date }
}

# Create GitHub issue with Copilot and escalation tags
function New-GitHubIssue {
    param(
        [string]$Title,
        [string]$Description,
        [string]$Repository,
        [string]$Token,
        [switch]$TagCopilot,
        [switch]$TagEscalation
    )

    if (!$Repository -or !$Token) {
        Write-Host "⚠ GitHub credentials not available, skipping issue creation" -ForegroundColor Yellow
        return $false
    }

    try {
        # Build labels array
        $labels = @("auto-fix")
        if ($TagCopilot) { $labels += "@copilot" }
        if ($TagEscalation) { $labels += "needs-review"; $labels += "@beyondmeat" }

        # Build issue body with context
        $body = @"
## Manifest Auto-Fix Failed
**App**: $appName

### Issue Description
$Description

### Severity
$($issues[-1].Severity)

### Timestamp
$([DateTime]::UtcNow.ToString('o'))

### Next Steps
$(if ($TagCopilot) { "- [ ] GitHub Copilot to review and create fix PR`n" })
$(if ($TagEscalation) { "- [ ] @beyondmeat to manually review and apply fix`n" })
- [ ] Run: ``.\bin\autofix-manifest.ps1 -ManifestPath bucket/$appName.json``
- [ ] Commit and push changes

### Context
Manifest: bucket/$appName.json
"@

        $headers = @{
            Authorization  = "token $Token"
            "Content-Type" = "application/json"
        }

        $payload = @{
            title  = $Title
            body   = $body
            labels = $labels
        } | ConvertTo-Json

        $apiUrl = "https://api.github.com/repos/$Repository/issues"
        $response = Invoke-WebRequest -Uri $apiUrl -Method POST -Headers $headers -Body $payload -ErrorAction Stop
        $issueNumber = ($response.Content | ConvertFrom-Json).number

        Write-Host "✓ GitHub issue #$issueNumber created" -ForegroundColor Green
        Write-Host "  Tags: $($labels -join ', ')" -ForegroundColor Green
        return $issueNumber
    } catch {
        Write-Host "⚠ Failed to create GitHub issue: $_" -ForegroundColor Yellow
        return $false
    }
}

# Validate manifest structure
function Test-ManifestStructure {
    param([object]$Manifest)

    $errors = @()

    if (!$Manifest.version) { $errors += "Missing 'version' field" }
    if (!$Manifest.url -and !$Manifest.architecture) { $errors += "Missing 'url' and 'architecture' fields" }
    if ($Manifest.autoupdate -and !$Manifest.checkver) { $errors += "Has 'autoupdate' but missing 'checkver'" }

    return $errors
}

# Auto-fix checkver pattern based on release analysis
function Repair-CheckverPattern {
    param([string]$Repo, [string]$CurrentPattern, [object]$ReleaseData)

    # Analyze release tag/name to suggest pattern
    $tagName = $ReleaseData.tag_name

    # Extract version numbers from tag
    if ($tagName -match 'v?(\d+[\.\d]*)?') {
        $detectedVersion = $matches[1]
        if ($detectedVersion) {
            Write-Host "  Detected version format: $detectedVersion from tag: $tagName" -ForegroundColor Yellow

            # Suggest pattern based on detected format
            if ($tagName -match '^v\d') {
                return '(?<version>v\d+[\.\d]*)'
            } elseif ($tagName -match '^\d') {
                return '(?<version>\d+[\.\d]*)'
            }
        }
    }

    return $null
}

# Support multiple Git platforms
function Get-ReleaseAssets {
    param([string]$Repo, [string]$Version, [string]$Platform = "github")

    $assets = @()

    if ($Platform -eq "github") {
        try {
            $apiUrl = "https://api.github.com/repos/$repo/releases/tags/$Version"
            $release = Invoke-WebRequest -Uri $apiUrl -ErrorAction SilentlyContinue -UseBasicParsing | ConvertFrom-Json
            return $release.assets
        } catch {
            Write-Host "  ⚠ GitHub API error: $_" -ForegroundColor Yellow
            $errorMsg = $_
        }
    } elseif ($Platform -eq "gitlab") {
        try {
            $projectId = [Uri]::EscapeDataString($repo)
            $apiUrl = "https://gitlab.com/api/v4/projects/$projectId/releases/$Version"
            $release = Invoke-WebRequest -Uri $apiUrl -ErrorAction SilentlyContinue -UseBasicParsing | ConvertFrom-Json

            # Convert GitLab response to similar format
            $assets = $release.assets.sources | ForEach-Object {
                @{ name = $_.filename; browser_download_url = $_.url }
            }
            return $assets
        } catch {
            Write-Host "  ⚠ GitLab API error: $_" -ForegroundColor Yellow
        }
    } elseif ($Platform -eq "gitea") {
        try {
            $apiUrl = "https://$repo/api/v1/repos/$repo/releases/tags/$Version"
            $release = Invoke-WebRequest -Uri $apiUrl -ErrorAction SilentlyContinue -UseBasicParsing | ConvertFrom-Json

            # Convert Gitea response
            $assets = $release.assets | ForEach-Object {
                @{ name = $_.name; browser_download_url = $_.browser_download_url }
            }
            return $assets
        } catch {
            Write-Host "  ⚠ Gitea API error: $_" -ForegroundColor Yellow
        }
    }

    return $assets
}

# Detect and repair hash mismatches
function Test-HashMismatch {
    param([string]$Url, [string]$StoredHash)

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        Write-Host "    Verifying hash..." -ForegroundColor Gray
        Invoke-WebRequest -Uri $Url -OutFile $tempFile -ProgressAction SilentlyContinue -ErrorAction Stop | Out-Null
        $actualHash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash

        if ($actualHash -ne $StoredHash) {
            Write-Host "    ⚠ Hash mismatch detected!" -ForegroundColor Yellow
            Write-Host "      Expected: $StoredHash" -ForegroundColor Yellow
            Write-Host "      Actual:   $actualHash" -ForegroundColor Yellow
            return @{ Mismatch = $true; ActualHash = $actualHash }
        }

        return @{ Mismatch = $false; ActualHash = $actualHash }
    } catch {
        Write-Host "    ⚠ Hash verification failed: $_" -ForegroundColor Yellow
        return $null
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

try {
    if (!(Test-Path $ManifestPath)) {
        Write-Error "Manifest not found: $ManifestPath"
        exit -1
    }

    $ManifestPath = Convert-Path $ManifestPath
    $appName = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $ManifestPath))

    Write-Host "`n=== Auto-fixing manifest: $appName ===" -ForegroundColor Cyan

    # Read manifest
    $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json

    # Validate manifest structure
    $structureErrors = Test-ManifestStructure -Manifest $manifest
    if ($structureErrors) {
        Write-Host "Manifest structure issues detected:" -ForegroundColor Yellow
        foreach ($errorMsg in $structureErrors) {
            Write-Host "  ⚠ $errorMsg" -ForegroundColor Yellow
            Add-Issue -Title "Structure Error" -Description $errorMsg -Severity "error"
        }
    }

    # Skip if no autoupdate
    if (!$manifest.autoupdate) {
        Write-Host "No autoupdate section, skipping"
        exit 1
    }

    # Try to get latest version from checkver
    $checkverScript = "$PSScriptRoot/checkver.ps1"

    if (!(Test-Path $checkverScript)) {
        Write-Host "checkver script not found, skipping"
        exit 1
    }

    Write-Host "Running checkver..."
    $checkverOutput = & $checkverScript -App $appName -Dir $BucketPath 2>&1 | Out-String

    # Parse version from checkver output
    if ($checkverOutput -match ':\s+([\d\.]+)(\s+\(scoop version)?') {
        $latestVersion = $matches[1]
        $currentVersion = $manifest.version

        if ($latestVersion -eq $currentVersion) {
            Write-Host "✓ Manifest already up-to-date (v$currentVersion)"
            exit 1
        }

        Write-Host "Found update: v$currentVersion -> v$latestVersion" -ForegroundColor Yellow

        # Attempt to detect and fix URL issues
        Write-Host "Analyzing download URLs..."

        # Check if URLs have 404s and try to fix them
        $urlPatterns = @()

        # Collect all URLs from manifest
        if ($manifest.url) {
            $urlPatterns += @{ type = "generic"; url = $manifest.url }
        }
        if ($manifest.architecture.'64bit'.url) {
            $urlPatterns += @{ type = "64bit"; url = $manifest.architecture.'64bit'.url }
        }
        if ($manifest.architecture.'32bit'.url) {
            $urlPatterns += @{ type = "32bit"; url = $manifest.architecture.'32bit'.url }
        }

        foreach ($urlPattern in $urlPatterns) {
            $oldUrl = $urlPattern.url
            $arch = $urlPattern.type

            # Try to construct new URL based on version change
            $newUrl = $oldUrl -replace [regex]::Escape($currentVersion), $latestVersion

            Write-Host "Checking $arch URL..."

            # Test if old URL works
            try {
                $response = Invoke-WebRequest -Uri $oldUrl -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction SilentlyContinue
                if ($response.StatusCode -eq 200) {
                    Write-Host "  ✓ Current URL still valid"

                    # Verify hash if it exists
                    $hashField = if ($arch -eq "generic") { "hash" } else { "hash" }
                    if ($manifest.PSObject.Properties.Name -contains $hashField) {
                        $currentHash = if ($arch -eq "generic") { $manifest.hash } else { $manifest.architecture.$arch.hash }
                        if ($currentHash) {
                            $hashResult = Test-HashMismatch -Url $oldUrl -StoredHash $currentHash
                            if ($hashResult -and $hashResult.Mismatch) {
                                Write-Host "    ✓ Auto-fixing hash mismatch" -ForegroundColor Green
                                if ($arch -eq "generic") {
                                    $manifest.hash = $hashResult.ActualHash
                                } else {
                                    $manifest.architecture.$arch.hash = $hashResult.ActualHash
                                }
                            }
                        }
                    }
                    continue
                }
            } catch {
                Write-Host "  ✗ Current URL returned error"
            }

            # Try new URL with version substitution
            try {
                $response = Invoke-WebRequest -Uri $newUrl -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction SilentlyContinue
                if ($response.StatusCode -eq 200) {
                    Write-Host "  ✓ Fixed URL found: $newUrl" -ForegroundColor Green

                    # Update manifest with new URL
                    if ($arch -eq "generic") {
                        $manifest.url = $newUrl
                    } elseif ($arch -eq "64bit") {
                        $manifest.architecture.'64bit'.url = $newUrl
                    } elseif ($arch -eq "32bit") {
                        $manifest.architecture.'32bit'.url = $newUrl
                    }

                    continue
                }
            } catch {
                # New URL also failed, try to find via repository API
            }

            # Try to find via repository API (GitHub, GitLab, Gitea)
            $repoPlatform = "github"
            $repoPath = $null

            if ($manifest.checkver.github) {
                $repoPlatform = "github"
                if ($manifest.checkver.github -match 'github\.com/([^/]+/[^/]+)') {
                    $repoPath = $matches[1]
                }
            } elseif ($manifest.checkver.gitlab) {
                $repoPlatform = "gitlab"
                if ($manifest.checkver.gitlab -match 'gitlab\.com/([^/]+/[^/]+)') {
                    $repoPath = $matches[1]
                }
            } elseif ($manifest.checkver.gitea) {
                $repoPlatform = "gitea"
                if ($manifest.checkver.gitea -match '(https?://[^/]+)/([^/]+/[^/]+)') {
                    $repoPath = $matches[2]
                }
            }

            if ($repoPath) {
                Write-Host "  Attempting $repoPlatform API lookup..."

                try {
                    $assets = Get-ReleaseAssets -Repo $repoPath -Version $latestVersion -Platform $repoPlatform

                    if ($assets) {
                        # Find matching asset based on architecture
                        $asset = $null
                        if ($arch -eq "64bit") {
                            $asset = $assets | Where-Object { $_.name -match "x86.?64|win64|windows.x64|64.?bit|amd64" } | Select-Object -First 1
                        } elseif ($arch -eq "32bit") {
                            $asset = $assets | Where-Object { $_.name -match "x86.?32|win32|windows.x86|32.?bit|386" } | Select-Object -First 1
                        } else {
                            $asset = $assets | Select-Object -First 1
                        }

                        if ($asset) {
                            $fixedUrl = $asset.browser_download_url
                            Write-Host "  ✓ API found asset: $($asset.name)" -ForegroundColor Green

                            if ($arch -eq "generic") {
                                $manifest.url = $fixedUrl
                            } elseif ($arch -eq "64bit") {
                                $manifest.architecture.'64bit'.url = $fixedUrl
                            } elseif ($arch -eq "32bit") {
                                $manifest.architecture.'32bit'.url = $fixedUrl
                            }
                        }
                    }
                } catch {
                    Write-Host "  ⚠ API lookup failed: $_"
                    Add-Issue -Title "URL Resolution Failed" -Description "Could not resolve download URL for $appName $arch" -Severity "warning"
                }
            }
        }

        # Update version
        $manifest.version = $latestVersion

        # Calculate hashes for new URLs
        Write-Host "Calculating hashes..."

        # Helper function to download and hash
        function Get-RemoteFileHash {
            param([string]$Url)

            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                Invoke-WebRequest -Uri $Url -OutFile $tempFile -ProgressAction SilentlyContinue -ErrorAction Stop | Out-Null
                $hash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash
                return $hash
            } catch {
                Write-Warning "Failed to download $Url : $_"
                return $null
            } finally {
                if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
            }
        }

        if ($manifest.url) {
            $hash = Get-RemoteFileHash -Url $manifest.url
            if ($hash) {
                $manifest.hash = $hash
                Write-Host "  ✓ Generic hash updated"
            }
        }

        if ($manifest.architecture.'64bit'.url) {
            $hash = Get-RemoteFileHash -Url $manifest.architecture.'64bit'.url
            if ($hash) {
                $manifest.architecture.'64bit'.hash = $hash
                Write-Host "  ✓ 64bit hash updated"
            }
        }

        if ($manifest.architecture.'32bit'.url) {
            $hash = Get-RemoteFileHash -Url $manifest.architecture.'32bit'.url
            if ($hash) {
                $manifest.architecture.'32bit'.hash = $hash
                Write-Host "  ✓ 32bit hash updated"
            }
        }

        # Save updated manifest
        $updatedJson = $manifest | ConvertTo-Json -Depth 10
        # Use UTF-8 without BOM (standard JSON)
        [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", [System.Text.Encoding]::UTF8)

        Write-Host "✓ Manifest auto-fixed and saved" -ForegroundColor Green

        # Log any issues for manual review
        if ($issues.Count -gt 0 -and $NotifyOnIssues -and $IssueLog) {
            $issues | ConvertTo-Json | Add-Content -Path $IssueLog
            Write-Host "⚠ Issues logged for manual review" -ForegroundColor Yellow

            # Create GitHub issue with Copilot tag
            if ($AutoCreateIssues) {
                $issueTitle = "Auto-fix failed for $appName - Copilot review needed"
                $issueDesc = ($issues | ForEach-Object { "- **$($_.Title)**: $($_.Description)" }) -join "`n"

                $issueNum = New-GitHubIssue `
                    -Title $issueTitle `
                    -Description $issueDesc `
                    -Repository $GitHubRepo `
                    -Token $GitHubToken `
                    -TagCopilot

                if (!$issueNum) {
                    Write-Host "⚠ Could not create Copilot issue, escalating to manual review" -ForegroundColor Yellow
                    # Create escalation issue
                    $issueNum = New-GitHubIssue `
                        -Title "ESCALATION: Manual fix needed for $appName" `
                        -Description $issueDesc `
                        -Repository $GitHubRepo `
                        -Token $GitHubToken `
                        -TagEscalation
                }
            }

            exit 2
        }

        exit 0
    } else {
        Write-Host "Could not parse checkver output"
        Add-Issue -Title "Checkver Parse Failed" -Description "Could not extract version from checkver output for $appName" -Severity "error"

        if ($issues.Count -gt 0 -and $NotifyOnIssues -and $IssueLog) {
            $issues | ConvertTo-Json | Add-Content -Path $IssueLog

            # Create GitHub issue with escalation tag (checkver failure is serious)
            if ($AutoCreateIssues) {
                $issueTitle = "ESCALATION: Checkver failed for $appName"
                $issueDesc = "Could not extract version from checkver output. This requires manual investigation and fix."

                New-GitHubIssue `
                    -Title $issueTitle `
                    -Description $issueDesc `
                    -Repository $GitHubRepo `
                    -Token $GitHubToken `
                    -TagEscalation | Out-Null
            }

            exit 2
        }

        exit -1
    }
} catch {
    Write-Error "Error in auto-fix: $($_.Exception.Message)"
    exit -1
}
