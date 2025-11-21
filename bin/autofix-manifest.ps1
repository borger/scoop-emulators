#!/usr/bin/env pwsh
<#
.SYNOPSIS
Automatically repair common manifest issues.

.DESCRIPTION
Intelligently repairs broken manifests by:
1. Detecting and fixing version format mismatches
2. Recovering from URL pattern failures
3. Re-downloading and recalculating hashes
4. Updating checkver and autoupdate configurations
5. Supporting GitHub, GitLab, and Gitea repositories

.PARAMETER ManifestPath
Path to the manifest JSON file to repair.

.PARAMETER BucketPath
Path to the bucket directory (auto-detected from manifest path if not specified).

.PARAMETER IssueLog
Log file path for detailed repair information.

.PARAMETER NotifyOnIssues
Post GitHub comments about repair attempts.

.PARAMETER GitHubToken
GitHub token for posting comments (uses $env:GITHUB_TOKEN if not specified).

.PARAMETER GitHubRepo
GitHub repository in format "owner/repo" (uses $env:GITHUB_REPOSITORY if not specified).

.PARAMETER AutoCreateIssues
Automatically create issues for manifests that couldn't be auto-fixed.

.EXAMPLE
# Auto-fix a broken manifest
.\autofix-manifest.ps1 -ManifestPath bucket\gopher64.json

# Auto-fix with GitHub issue posting
.\autofix-manifest.ps1 -ManifestPath bucket\gopher64.json -GitHubToken $token -NotifyOnIssues

# Auto-fix and create issue if it fails
.\autofix-manifest.ps1 -ManifestPath bucket\gopher64.json -AutoCreateIssues

.OUTPUTS
Repaired manifest file with updated version, hashes, and URLs.

.LINK
https://github.com/borger/scoop-emulators
#>

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
4. Detects and recovers from version scheme changes (numeric -> date-based, etc.)
5. Attempts recovery when checkver itself returns 404 or fails
6. Tries pattern matching when exact release version tags don't exist
7. Recalculates hashes for updated URLs
8. Detects hash mismatches and auto-recomputes
9. Validates manifest structure
10. Supports GitHub, GitLab, and Gitea repositories
11. Attempts GitHub Copilot PR creation for unfixable issues
12. Escalates to manual review if Copilot PR fails
13. Logs issues for manual review if needed

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
0 = manifest valid/no changes needed, 1 = errors (missing script/invalid input), 2 = issues found but unfixable, -1 = critical error
#>

$ErrorActionPreference = 'Stop'

# Set TLS 1.2 (required for GitHub API)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

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
        Write-Host "[WARN] GitHub credentials not available, skipping issue creation" -ForegroundColor Yellow
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
        $response = Invoke-RestMethod -Uri $apiUrl -Method POST -Headers $headers -Body $payload -ErrorAction Stop
        $issueNumber = $response.number

        Write-Host "[OK] GitHub issue #$issueNumber created" -ForegroundColor Green
        Write-Host "  Tags: $($labels -join ', ')" -ForegroundColor Green
        return $issueNumber
    } catch {
        Write-Host "[WARN] Failed to create GitHub issue: $_" -ForegroundColor Yellow
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

# Detect version scheme changes and attempt pattern recovery
function Repair-VersionPattern {
    param(
        [string]$AppName,
        [string]$RepoPath,
        [string]$Platform = "github"
    )

    Write-Host "  Attempting to detect version scheme from recent releases..." -ForegroundColor Yellow

    try {
        $releases = $null

        if ($Platform -eq "github") {
            $apiUrl = "https://api.github.com/repos/$RepoPath/releases?per_page=5"
            $releases = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
        } elseif ($Platform -eq "gitlab") {
            $projectId = [Uri]::EscapeDataString($RepoPath)
            $apiUrl = "https://gitlab.com/api/v4/projects/$projectId/releases?per_page=5"
            $releases = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
        }

        if ($releases -and $releases.Count -gt 0) {
            # Analyze tag patterns from recent releases
            $tags = @()
            foreach ($release in $releases) {
                if ($release.tag_name) { $tags += $release.tag_name }
                elseif ($release.name) { $tags += $release.name }
            }

            Write-Host "  Recent tags: $($tags | Select-Object -First 3 | Join-String -Separator ', ')" -ForegroundColor Gray

            # Detect version scheme patterns
            if ($tags | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}' }) {
                Write-Host "  [INFO] Detected date-based versioning (YYYY-MM-DD)" -ForegroundColor Cyan
                return "date"
            } elseif ($tags | Where-Object { $_ -match '^v?\d+\.\d+\.\d+' }) {
                Write-Host "  [INFO] Detected semantic versioning" -ForegroundColor Cyan
                return "semantic"
            } elseif ($tags | Where-Object { $_ -match '^\d+$' }) {
                Write-Host "  [INFO] Detected numeric-only versioning" -ForegroundColor Cyan
                return "numeric"
            } else {
                Write-Host "  [INFO] Detected custom versioning scheme" -ForegroundColor Cyan
                return "custom"
            }
        }
    } catch {
        Write-Host "  [WARN] Could not analyze recent releases: $_" -ForegroundColor Yellow
    }

    return $null
}

# Try to find release by pattern matching when version tag doesn't exist
function Find-ReleaseByPatternMatch {
    param(
        [string]$RepoPath,
        [string]$TargetVersion,
        [string]$Platform = "github"
    )

    try {
        $releases = $null

        if ($Platform -eq "github") {
            $apiUrl = "https://api.github.com/repos/$RepoPath/releases?per_page=10"
            $releases = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
        }

        if ($releases) {
            # Try exact match first
            $exactMatch = $releases | Where-Object { $_.tag_name -eq $TargetVersion -or $_.tag_name -eq "v$TargetVersion" }
            if ($exactMatch) { return $exactMatch[0] }

            # Try partial matches (for version scheme mismatches)
            $partialMatch = $releases | Where-Object {
                $_.tag_name -match [regex]::Escape($TargetVersion) -or
                $_.name -match [regex]::Escape($TargetVersion)
            }
            if ($partialMatch) {
                Write-Host "  [INFO] Found release with partial version match: $($partialMatch[0].tag_name)" -ForegroundColor Cyan
                return $partialMatch[0]
            }

            # Get latest release if no match found
            $latestRelease = $releases | Where-Object { !$_.prerelease -and !$_.draft } | Select-Object -First 1
            if ($latestRelease) {
                Write-Host "  [WARN] No exact match found; using latest release: $($latestRelease.tag_name)" -ForegroundColor Yellow
                return $latestRelease
            }
        }
    } catch {
        Write-Host "  [WARN] Pattern matching failed: $_" -ForegroundColor Yellow
    }

    return $null
}

# Auto-fix checkver pattern based on release analysis
function Repair-CheckverPattern {
    param([string]$Repo, [string]$CurrentPattern, [object]$ReleaseData)

    # Analyze release tag/name to suggest pattern
    $tagName = $ReleaseData.tag_name
    if (!$tagName) { $tagName = $ReleaseData.name }

    Write-Host "  Analyzing tag format: $tagName" -ForegroundColor Gray

    # Date-based versioning (YYYY-MM-DD)
    if ($tagName -match '(\d{4}-\d{2}-\d{2})') {
        Write-Host "  Detected date-based format from tag: $tagName" -ForegroundColor Yellow
        return '(?<version>\d{4}-\d{2}-\d{2})'
    }

    # Extract version numbers from tag
    if ($tagName -match 'v?(\d+[\.\d\-]*)?') {
        $detectedVersion = $matches[1]
        if ($detectedVersion) {
            Write-Host "  Detected version format: $detectedVersion from tag: $tagName" -ForegroundColor Yellow

            # Suggest pattern based on detected format
            if ($tagName -match '^v\d') {
                return '(?<version>v\d+[\.\d\-]*)'
            } elseif ($tagName -match '^\d{4}-\d{2}') {
                return '(?<version>\d{4}-\d{2}-\d{2})'
            } elseif ($tagName -match '^\d') {
                return '(?<version>\d+[\.\d\-]*)'
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
            $release = Invoke-RestMethod -Uri $apiUrl -ErrorAction SilentlyContinue -UseBasicParsing
            return $release.assets
        } catch {
            Write-Host "  [WARN] GitHub API error: $_" -ForegroundColor Yellow
            $errorMsg = $_
        }
    } elseif ($Platform -eq "gitlab") {
        try {
            $projectId = [Uri]::EscapeDataString($repo)
            $apiUrl = "https://gitlab.com/api/v4/projects/$projectId/releases/$Version"
            $release = Invoke-RestMethod -Uri $apiUrl -ErrorAction SilentlyContinue -UseBasicParsing

            # Convert GitLab response to similar format
            $assets = $release.assets.sources | ForEach-Object {
                @{ name = $_.filename; browser_download_url = $_.url }
            }
            return $assets
        } catch {
            Write-Host "  [WARN] GitLab API error: $_" -ForegroundColor Yellow
        }
    } elseif ($Platform -eq "gitea") {
        try {
            $apiUrl = "https://$repo/api/v1/repos/$repo/releases/tags/$Version"
            $release = Invoke-RestMethod -Uri $apiUrl -ErrorAction SilentlyContinue -UseBasicParsing

            # Convert Gitea response
            $assets = $release.assets | ForEach-Object {
                @{ name = $_.name; browser_download_url = $_.browser_download_url }
            }
            return $assets
        } catch {
            Write-Host "  [WARN] Gitea API error: $_" -ForegroundColor Yellow
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
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $tempFile -ErrorAction Stop -UseBasicParsing | Out-Null
        $actualHash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash

        if ($actualHash -ne $StoredHash) {
            Write-Host "    [WARN] Hash mismatch detected!" -ForegroundColor Yellow
            Write-Host "      Expected: $StoredHash" -ForegroundColor Yellow
            Write-Host "      Actual:   $actualHash" -ForegroundColor Yellow
            return @{ Mismatch = $true; ActualHash = $actualHash }
        }

        return @{ Mismatch = $false; ActualHash = $actualHash }
    } catch {
        Write-Host "    [WARN] Hash verification failed: $_" -ForegroundColor Yellow
        return $null
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

# Get hash from GitHub release checksum file
function Get-ReleaseChecksum {
    param(
        [object[]]$Assets,
        [string]$TargetAssetName
    )

    if (-not $Assets) {
        return $null
    }

    # Look for checksum files
    $checksumPatterns = @('*.sha256', '*.sha256sum', '*.sha256.txt', '*.checksum', '*.hashes', '*.DIGEST', '*.md5', '*.md5sum')
    $checksumAssets = @()

    foreach ($pattern in $checksumPatterns) {
        $checksumAssets += @($Assets | Where-Object { $_.name -like $pattern })
    }

    if ($checksumAssets.Count -eq 0) {
        return $null
    }

    # Download and parse the checksum file
    foreach ($checksumAsset in $checksumAssets) {
        try {
            $ProgressPreference = 'SilentlyContinue'
            $tempFile = [System.IO.Path]::GetTempFileName()
            Invoke-WebRequest -Uri $checksumAsset.browser_download_url -OutFile $tempFile -ErrorAction Stop -UseBasicParsing

            # Parse the checksum file
            $content = Get-Content -Path $tempFile -Raw
            $lines = $content -split "`n" | Where-Object { $_ -match '\S' }

            foreach ($line in $lines) {
                # Match common formats: "hash filename" or "filename hash"
                if ($line -match '^([a-f0-9]{64})\s+(.+?)$' -or $line -match '^(.+?)\s+([a-f0-9]{64})$') {
                    $hash = if ($matches[1] -match '^[a-f0-9]{64}$') { $matches[1] } else { $matches[2] }
                    $filename = if ($matches[1] -match '^[a-f0-9]{64}$') { $matches[2] } else { $matches[1] }

                    # Check if this matches the target asset
                    if ($filename -like "*$($TargetAssetName)*" -or $TargetAssetName -like "*$filename*") {
                        Write-Verbose "[OK] Found SHA256 from GitHub release: $hash"
                        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                        return $hash
                    }
                }
            }
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Verbose "[WARN] Failed to parse checksum file: $_"
        }
    }

    return $null
}

# Download a file and compute its SHA256 hash
function Get-RemoteFileHash {
    param([string]$Url)

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $tempFile -ErrorAction Stop -UseBasicParsing | Out-Null
        $hash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash.ToLower()
        return $hash
    } catch {
        Write-Warning "Failed to download $Url : $_"
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
    $checkverRepaired = $false

    # Extract GitHub owner/repo if available (for fetching release checksums)
    $gitHubOwner = $null
    $gitHubRepo = $null
    if ($manifest.checkver.github) {
        if ($manifest.checkver.github -match 'github\.com/([^/]+)/([^/]+)/?$') {
            $gitHubOwner = $matches[1]
            $gitHubRepo = $matches[2]
            Write-Verbose "GitHub repo detected: $gitHubOwner/$gitHubRepo"
        }
    }

    # Validate manifest structure
    $structureErrors = Test-ManifestStructure -Manifest $manifest
    if ($structureErrors) {
        Write-Host "Manifest structure issues detected:" -ForegroundColor Yellow
        foreach ($errorMsg in $structureErrors) {
            Write-Host "  [WARN] $errorMsg" -ForegroundColor Yellow
            Add-Issue -Title "Structure Error" -Description $errorMsg -Severity "error"
        }
    }

    # Skip if no autoupdate (not an error, manifest is valid as-is)
    if (!$manifest.autoupdate) {
        Write-Host "[OK] No autoupdate section needed, manifest is valid"
        exit 0
    }

    # Try to get latest version from checkver
    $checkverScript = "$PSScriptRoot/checkver.ps1"

    if (!(Test-Path $checkverScript)) {
        Write-Host "[WARN] checkver script not found, cannot validate updates"
        exit 1
    }

    Write-Host "Running checkver..."
    $checkverOutput = & $checkverScript -App $appName -Dir $BucketPath 2>&1 | Out-String

    # Check if checkver output indicates a regex matching failure
    if ($checkverOutput -match "couldn't match") {
        Write-Host "[WARN] Checkver regex pattern doesn't match, attempting to fix checkver config..." -ForegroundColor Yellow

        # Try to detect repo from checkver config
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
        }

        if ($repoPath) {
            # Get the latest release and use API-based checkver
            try {
                if ($repoPlatform -eq "github") {
                    $apiUrl = "https://api.github.com/repos/$repoPath/releases/latest"
                    $latestRelease = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop

                    if ($latestRelease -and $latestRelease.tag_name) {
                        # Repair checkver to use API-based version detection
                        $manifest.checkver = @{
                            "url"      = "https://api.github.com/repos/$repoPath/releases/latest"
                            "jsonpath" = "$.tag_name"
                            "regex"    = "v([0-9.]+)"
                        }
                        $checkverRepaired = $true
                        Write-Host "  [OK] Repaired checkver config to use API-based detection" -ForegroundColor Green

                        $latestVersion = $latestRelease.tag_name -replace '^v', ''
                        Write-Host "  [INFO] Using version from checkver: $latestVersion" -ForegroundColor Gray
                    }
                }
            } catch {
                Write-Host "  [WARN] Could not repair checkver: $_" -ForegroundColor Yellow
            }
        }
    }

    # Parse version from checkver output if not already obtained
    if (-not $latestVersion) {
        # Extract version from the scoop version line - this is the parsed version checkver produced
        if ($checkverOutput -match '\(scoop version is ([^\)]+)\)') {
            $latestVersion = $matches[1]
            Write-Host "  [INFO] Using version from checkver: $latestVersion" -ForegroundColor Gray
        } else {
            # Fallback: Extract the version line after "appname:"
            $lines = $checkverOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }

            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^' + [regex]::Escape($appName) + ':') {
                    # Next non-empty line should be the version
                    if ($i + 1 -lt $lines.Count) {
                        $versionLine = $lines[$i + 1]
                        # Check if this looks like a version (not "(scoop version is...)")
                        if ($versionLine -notmatch '^\(scoop version') {
                            $latestVersion = $versionLine
                            Write-Host "  [INFO] Using version from checkver: $latestVersion" -ForegroundColor Gray
                            break
                        }
                    }
                }
            }
        }
    }

    if (-not $latestVersion) {
        # Checkver itself failed - attempt recovery
        Write-Host "[WARN] Checkver execution failed or returned 404, attempting API fallback..." -ForegroundColor Yellow

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
        }

        if ($repoPath) {
            Write-Host "  Detecting version scheme from repository..." -ForegroundColor Gray
            $schemeType = Repair-VersionPattern -AppName $appName -RepoPath $repoPath -Platform $repoPlatform

            # Get latest release
            try {
                if ($repoPlatform -eq "github") {
                    $apiUrl = "https://api.github.com/repos/$repoPath/releases/latest"
                    $latestRelease = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop

                    if ($latestRelease) {
                        if ($latestRelease.tag_name) {
                            $latestVersion = $latestRelease.tag_name -replace '^v', ''
                        } elseif ($latestRelease.name) {
                            $latestVersion = $latestRelease.name
                        }

                        if ($latestVersion) {
                            Write-Host "[OK] Recovered version from latest release: $latestVersion" -ForegroundColor Green
                        }
                    }
                }
            } catch {
                Write-Host "  [WARN] API fallback also failed: $_" -ForegroundColor Yellow
            }
        }
    }

    if ($latestVersion) {
        $currentVersion = $manifest.version

        if ($latestVersion -eq $currentVersion) {
            # If checkver was repaired, save the manifest even though version didn't change
            if ($checkverRepaired) {
                Write-Host "[OK] Checkver repaired, saving manifest..." -ForegroundColor Green
                $updatedJson = $manifest | ConvertTo-Json -Depth 10
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)
                Write-Host "[OK] Manifest saved with repaired checkver"
                exit 0
            }

            Write-Host "[OK] Manifest already up-to-date (v$currentVersion)"
            exit 0
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
            $urlValid = $false
            try {
                $response = Invoke-WebRequest -Uri $oldUrl -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                if ($response.StatusCode -eq 200) {
                    Write-Host "  [OK] Current URL still valid"
                    $urlValid = $true

                    # Verify hash if it exists
                    $hashField = if ($arch -eq "generic") { "hash" } else { "hash" }
                    if ($manifest.PSObject.Properties.Name -contains $hashField) {
                        $currentHash = if ($arch -eq "generic") { $manifest.hash } else { $manifest.architecture.$arch.hash }
                        if ($currentHash) {
                            $hashResult = Test-HashMismatch -Url $oldUrl -StoredHash $currentHash
                            if ($hashResult -and $hashResult.Mismatch) {
                                Write-Host "    [OK] Auto-fixing hash mismatch" -ForegroundColor Green
                                if ($arch -eq "generic") {
                                    $manifest.hash = $hashResult.ActualHash.ToLower()
                                } else {
                                    $manifest.architecture.$arch.hash = $hashResult.ActualHash.ToLower()
                                }
                            }
                        }
                    }
                    continue
                }
            } catch {
                Write-Host "  [FAIL] Current URL returned error: $($_.Exception.Message)"
            }

            if (!$urlValid) {
                Write-Host "  [FAIL] URL is not accessible - attempting to fix"
            }

            # If URL is not valid, try version-substituted URL first
            try {
                $response = Invoke-WebRequest -Uri $newUrl -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                if ($response.StatusCode -eq 200) {
                    Write-Host "  [OK] Fixed URL found with version substitution: $newUrl" -ForegroundColor Green

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
                Write-Host "  Attempting $repoPlatform API lookup for version: $latestVersion..."

                try {
                    $assets = Get-ReleaseAssets -Repo $repoPath -Version $latestVersion -Platform $repoPlatform

                    # If release not found with exact version, attempt pattern matching
                    if (!$assets -or $assets.Count -eq 0) {
                        Write-Host "  [WARN] Release tag '$latestVersion' not found, attempting pattern match..." -ForegroundColor Yellow

                        $release = Find-ReleaseByPatternMatch -RepoPath $repoPath -TargetVersion $latestVersion -Platform $repoPlatform

                        if ($release) {
                            # Update latestVersion to the found release
                            if ($release.tag_name) {
                                $latestVersion = $release.tag_name -replace '^v', ''  # Strip 'v' prefix if present
                            } elseif ($release.name) {
                                $latestVersion = $release.name
                            }

                            Write-Host "  [OK] Updated version to: $latestVersion" -ForegroundColor Green

                            # Try to get assets from the matched release
                            $assets = Get-ReleaseAssets -Repo $repoPath -Version $release.tag_name -Platform $repoPlatform

                            # If still no assets but we have release info, try alternative version formats
                            if (!$assets -or $assets.Count -eq 0) {
                                # Try version without 'v' prefix
                                $versionAlt = $release.tag_name -replace '^v', ''
                                if ($versionAlt -ne $release.tag_name) {
                                    $assets = Get-ReleaseAssets -Repo $repoPath -Version $versionAlt -Platform $repoPlatform
                                }
                                # Try version with 'v' prefix
                                if ((!$assets -or $assets.Count -eq 0) -and $release.tag_name -notmatch '^v') {
                                    $assets = Get-ReleaseAssets -Repo $repoPath -Version "v$($release.tag_name)" -Platform $repoPlatform
                                }
                            }
                        } else {
                            Write-Host "  [WARN] No release found matching version pattern" -ForegroundColor Yellow
                            Add-Issue -Title "Release Not Found" -Description "Could not find release for version $latestVersion or similar" -Severity "warning"
                        }
                    }

                    if ($assets) {
                        # Find matching asset based on architecture
                        $asset = $null

                        # Separate Windows-specific and all archive assets
                        $windowsAssets = $assets | Where-Object { $_.name -match "windows|win" }
                        $archiveAssets = $assets | Where-Object { $_.name -match "\.(zip|exe|msi|7z)$" }
                        if (!$archiveAssets) {
                            $archiveAssets = $assets
                        }

                        if ($arch -eq "64bit") {
                            # First try: Windows assets with 64-bit patterns, prefer .zip
                            $asset = $windowsAssets | Where-Object { $_.name -match "x86.?64|win64|x64|amd64" -and $_.name -match "\.(zip|exe|msi|7z)$" } | Sort-Object { $_.name -match "\.zip$" } -Descending | Select-Object -First 1
                            # Second try: Any asset with 64-bit patterns
                            if (!$asset) {
                                $asset = $archiveAssets | Where-Object { $_.name -match "x86.?64|win64|x64|amd64" -and $_.name -match "\.(zip|exe|msi|7z)$" } | Sort-Object { $_.name -match "\.zip$" } -Descending | Select-Object -First 1
                            }
                            # Third try: Windows asset (assume 64-bit if only one version)
                            if (!$asset) {
                                $asset = $windowsAssets | Where-Object { $_.name -match "\.(zip|exe|msi|7z)$" } | Sort-Object { $_.name -match "\.zip$" } -Descending | Select-Object -First 1
                            }
                            # Last resort: largest archive (likely 64-bit)
                            if (!$asset) {
                                $asset = $archiveAssets | Sort-Object { $_.size } -Descending | Select-Object -First 1
                            }
                        } elseif ($arch -eq "32bit") {
                            # First try: Windows assets with 32-bit patterns, prefer .zip
                            $asset = $windowsAssets | Where-Object { $_.name -match "x86.?32|win32|i386|386|ia32" -and $_.name -match "\.(zip|exe|msi|7z)$" } | Sort-Object { $_.name -match "\.zip$" } -Descending | Select-Object -First 1
                            # Second try: Any asset with 32-bit patterns
                            if (!$asset) {
                                $asset = $archiveAssets | Where-Object { $_.name -match "x86.?32|win32|i386|386|ia32" -and $_.name -match "\.(zip|exe|msi|7z)$" } | Sort-Object { $_.name -match "\.zip$" } -Descending | Select-Object -First 1
                            }
                            # Third try: Windows asset (assume 32-bit if smaller)
                            if (!$asset) {
                                $asset = $windowsAssets | Where-Object { $_.name -match "\.(zip|exe|msi|7z)$" } | Sort-Object { $_.size } | Select-Object -First 1
                            }
                            # Last resort: smallest archive (likely 32-bit)
                            if (!$asset) {
                                $asset = $archiveAssets | Sort-Object { $_.size } | Select-Object -First 1
                            }
                        } else {
                            # Generic - prefer Windows archives, then zip files
                            $asset = $windowsAssets | Where-Object { $_.name -match "\.(zip|exe|msi|7z)$" } | Sort-Object { $_.name -match "\.zip$" } -Descending | Select-Object -First 1
                            if (!$asset) {
                                $asset = $archiveAssets | Where-Object { $_.name -match "\.(zip|exe|msi|7z)$" } | Sort-Object { $_.name -match "\.zip$" } -Descending | Select-Object -First 1
                            }
                            if (!$asset) {
                                $asset = $archiveAssets | Select-Object -First 1
                            }
                        }

                        if ($asset) {
                            $fixedUrl = $asset.browser_download_url
                            Write-Host "  [OK] API found asset for ${arch}: $($asset.name)" -ForegroundColor Green

                            if ($arch -eq "generic") {
                                $manifest.url = $fixedUrl
                            } elseif ($arch -eq "64bit") {
                                $manifest.architecture.'64bit'.url = $fixedUrl
                            } elseif ($arch -eq "32bit") {
                                $manifest.architecture.'32bit'.url = $fixedUrl
                            }

                            # Try to get checksum from GitHub release first
                            $hash = $null
                            if ($assets) {
                                $fileName = Split-Path -Leaf $fixedUrl
                                $hash = Get-ReleaseChecksum -Assets $assets -TargetAssetName $fileName
                            }

                            # Fall back to downloading and calculating if no checksum found
                            if (-not $hash) {
                                $hash = Get-RemoteFileHash -Url $fixedUrl
                            }

                            if ($hash) {
                                if ($arch -eq "generic") {
                                    $manifest.hash = $hash.ToLower()
                                } else {
                                    $manifest.architecture.$arch.hash = $hash.ToLower()
                                }
                                Write-Host "  [OK] Updated hash for ${arch} asset" -ForegroundColor Green
                            }
                        } else {
                            Write-Host "  [WARN] No matching Windows asset found in release for $arch" -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "  [WARN] Could not retrieve assets from $repoPlatform API" -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "  [WARN] API lookup failed: $_"
                    Add-Issue -Title "URL Resolution Failed" -Description "Could not resolve download URL for $appName $arch" -Severity "warning"
                }
            }
        }

        # Calculate hashes for new URLs (try GitHub release checksums first)
        Write-Host "Getting hashes for updated URLs..."

        # Try to fetch GitHub release assets if available (for checksum files)
        $releaseAssets = $null
        $hasChecksumFiles = $false
        if ($gitHubOwner -and $gitHubRepo) {
            $releaseAssets = Get-ReleaseAssets -Repo "$gitHubOwner/$gitHubRepo" -Version "v$($manifest.version)" -Platform "github"
            if (-not $releaseAssets) {
                # Try without 'v' prefix
                $releaseAssets = Get-ReleaseAssets -Repo "$gitHubOwner/$gitHubRepo" -Version $manifest.version -Platform "github"
            }
            # Check if checksum files exist
            if ($releaseAssets) {
                $checksumFiles = @($releaseAssets | Where-Object { $_.name -like '*.sha256' -or $_.name -like '*.sha256sum' -or $_.name -like '*.checksum' })
                $hasChecksumFiles = $checksumFiles.Count -gt 0
            }
        }

        $hashTargets = @()
        if ($manifest.url) { $hashTargets += @{ Name = 'Generic'; Obj = $manifest; Url = $manifest.url } }
        if ($manifest.architecture.'64bit'.url) { $hashTargets += @{ Name = '64bit'; Obj = $manifest.architecture.'64bit'; Url = $manifest.architecture.'64bit'.url } }
        if ($manifest.architecture.'32bit'.url) { $hashTargets += @{ Name = '32bit'; Obj = $manifest.architecture.'32bit'; Url = $manifest.architecture.'32bit'.url } }

        foreach ($target in $hashTargets) {
            $targetName = $target.Name
            $targetObj = $target.Obj
            $targetUrl = $target.Url

            # If checksum files exist in release, use API-based hash lookup
            if ($hasChecksumFiles -and $releaseAssets) {
                $fileName = Split-Path -Leaf $targetUrl
                $targetObj.hash = [ordered]@{
                    "url"      = "https://api.github.com/repos/$gitHubOwner/$gitHubRepo/releases/latest"
                    "jsonpath" = "\$.assets[?(@.name == '$fileName')].digest"
                }
                Write-Host "  [OK] $targetName hash configured for API lookup: $fileName"
            } else {
                # Fall back to static hash
                $newHash = $null
                if ($releaseAssets) {
                    $fileName = Split-Path -Leaf $targetUrl
                    $newHash = Get-ReleaseChecksum -Assets $releaseAssets -TargetAssetName $fileName
                }
                if (-not $newHash) {
                    $newHash = Get-RemoteFileHash -Url $targetUrl
                }
                if ($newHash) {
                    $targetObj.hash = $newHash
                    Write-Host "  [OK] $targetName hash updated"
                } else {
                    if ($targetName -ne 'Generic') {
                        Write-Host "  [WARN] Could not get $targetName hash"
                    }
                }
            }
        }

        # Save updated manifest - preserve original formatting by doing targeted text replacements
        $originalContent = Get-Content $ManifestPath -Raw
        $updatedContent = $originalContent

        # Build list of replacements (URL, old hash, new hash)
        $replacements = @()

        # Collect replacements for each URL pattern
        foreach ($pattern in $urlPatterns) {
            $arch = $pattern.type
            $oldUrl = $pattern.url
            $newUrl = $null
            $newHash = $null

            # Find the new URL and hash from manifest object
            if ($arch -eq "generic") {
                if ($manifest.url -ne $pattern.url) {
                    $newUrl = $manifest.url
                    $newHash = $manifest.hash
                }
            } elseif ($arch -eq "64bit") {
                if ($manifest.architecture.'64bit'.url -ne $pattern.url) {
                    $newUrl = $manifest.architecture.'64bit'.url
                    $newHash = $manifest.architecture.'64bit'.hash
                }
            } elseif ($arch -eq "32bit") {
                if ($manifest.architecture.'32bit'.url -ne $pattern.url) {
                    $newUrl = $manifest.architecture.'32bit'.url
                    $newHash = $manifest.architecture.'32bit'.hash
                }
            }

            if ($newUrl -and $newHash) {
                $replacements += @{
                    oldUrl  = $oldUrl
                    newUrl  = $newUrl
                    newHash = $newHash
                }
            }
        }

        # Apply URL and hash replacements in order
        foreach ($replacement in $replacements) {
            # Find the old URL and replace with new URL and new hash
            $oldUrl = $replacement.oldUrl
            $newUrl = $replacement.newUrl
            $newHash = $replacement.newHash

            # Create a pattern to find the URL and its corresponding hash
            $urlPattern = [regex]::Escape($oldUrl)
            $hashPattern = '"hash":\s*"([a-f0-9]{64})"'

            # Find the line with this URL
            $lines = $updatedContent -split "`r`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match $urlPattern) {
                    # Replace URL on this line
                    $lines[$i] = $lines[$i] -replace $urlPattern, $newUrl

                    # Look for hash on the next few lines
                    for ($j = $i + 1; $j -lt [Math]::Min($i + 5, $lines.Count); $j++) {
                        if ($lines[$j] -match $hashPattern) {
                            $oldHash = $matches[1]
                            $lines[$j] = $lines[$j] -replace [regex]::Escape($oldHash), $newHash
                            break
                        }
                    }
                    break
                }
            }

            $updatedContent = $lines -join "`r`n"
        }

        # Ensure file ends with newline
        if (!$updatedContent.EndsWith("`r`n")) {
            $updatedContent += "`r`n"
        }

        # Write back preserving original line endings (UTF-8 without BOM)
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($ManifestPath, $updatedContent, $utf8NoBom)

        Write-Host "[OK] Manifest auto-fixed and saved" -ForegroundColor Green

        # Log any issues for manual review
        if ($issues.Count -gt 0 -and $NotifyOnIssues -and $IssueLog) {
            $issues | ConvertTo-Json | Add-Content -Path $IssueLog
            Write-Host "[WARN] Issues logged for manual review" -ForegroundColor Yellow

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
                    Write-Host "[WARN] Could not create Copilot issue, escalating to manual review" -ForegroundColor Yellow
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
        Write-Host "[FAIL] Could not parse checkver output"
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
