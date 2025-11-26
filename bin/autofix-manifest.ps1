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

# Load centralized release/hash helpers
$lib = Join-Path $PSScriptRoot 'lib-releasehelpers.ps1'
if (Test-Path $lib) { . $lib }

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
        [string]$IssueType,
        [switch]$TagCopilot,
        [switch]$TagEscalation
    )

    if (!$Repository -or !$Token) {
        Write-Host '[WARN] GitHub credentials not available, skipping issue creation' -ForegroundColor Yellow
        return $false
    }

    try {
        # Build labels array
        $labels = @("auto-fix")
        if ($TagCopilot) { $labels += "@copilot" }
        if ($TagEscalation) { $labels += "needs-review"; $labels += "@beyondmeat" }

        # Add issue type labels
        switch ($IssueType) {
            "bug" { $labels += "bug" }
            "manifest-error" { $labels += "manifest-error" }
            "hash-error" { $labels += "hash-mismatch" }
        }

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

        Write-Host '[OK] GitHub issue #' -NoNewline; Write-Host $issueNumber -NoNewline; Write-Host ' created' -ForegroundColor Green
        Write-Host "  Tags: $($labels -join ', ')" -ForegroundColor Green
        return $issueNumber
    } catch {
        Write-Host '[WARN] Failed to create GitHub issue: ' -NoNewline; Write-Host $_ -ForegroundColor Yellow
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

# Test whether every download URL in the manifest is reachable via HTTP HEAD.
function Test-ManifestDownloadAccessibility {
    param(
        [object]$Manifest,
        [int]$TimeoutSec = 10
    )

    $targets = @()
    if ($Manifest.url) {
        $targets += @{ Type = 'generic'; Url = $Manifest.url }
    }
    if ($Manifest.architecture) {
        foreach ($arch in '64bit', '32bit', 'arm64') {
            if ($Manifest.architecture.$arch -and $Manifest.architecture.$arch.url) {
                $targets += @{ Type = $arch; Url = $Manifest.architecture.$arch.url }
            }
        }
    }

    if ($targets.Count -eq 0) {
        return @{ Success = $true; Failures = @() }
    }

    $failures = @()
    foreach ($target in $targets) {
        try {
            Invoke-WebRequest -Uri $target.Url -Method Head -TimeoutSec $TimeoutSec -UseBasicParsing -Headers @{ 'User-Agent' = 'scoop-autofix/1.0' } | Out-Null
        } catch {
            $failures += @{ Type = $target.Type; Url = $target.Url; Error = $_.Exception.Message }
        }
    }

    return @{ Success = ($failures.Count -eq 0); Failures = $failures }
}

# Validate any proposed fix by running update-manifest and attempting an install.
function Test-FixIntegrity {
    param(
        [string]$ManifestPath,
        [string]$AppName
    )

    $updateScript = "$PSScriptRoot/update-manifest.ps1"
    if (-not (Test-Path $updateScript)) {
        Write-Host '  [WARN] update-manifest.ps1 not available for validation' -ForegroundColor Yellow
        return $false
    }

    Write-Host ('  [INFO] Running update-manifest.ps1 for {0}' -f $AppName) -ForegroundColor Cyan
    $updateOutput = & $updateScript -ManifestPath $ManifestPath -Update -Force 2>&1
    # $LASTEXITCODE may not be set for PowerShell scripts; check both it and $? for robustness
    if ($LASTEXITCODE -ne 0 -or -not $?) {
        Write-Host ('  [WARN] update-manifest failed for {0}' -f $AppName) -ForegroundColor Yellow
        Add-Issue -Title "Validation failed" -Description "update-manifest.ps1 failed:\n$updateOutput" -Severity "error"
        return $false
    }

    if (-not (Get-Command 'scoop' -ErrorAction SilentlyContinue)) {
        Write-Host '  [WARN] scoop is not installed; skipping installation verification' -ForegroundColor Yellow
        return $true
    }

    Write-Host ('  [INFO] Attempting ''scoop install {0}'' to verify the manifest' -f $AppName) -ForegroundColor Cyan
    $installOutput = ''
    try {
        $installOutput = & scoop install $AppName 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "scoop install failed" }
    } catch {
        Write-Host ('  [WARN] scoop install failed for {0}' -f $AppName) -ForegroundColor Yellow
        Add-Issue -Title "Install verification failed" -Description "scoop install $AppName failed:\n$installOutput" -Severity "warning"
        return $false
    }

    return $true
}

# Helper to extract the first token that looks like a version (contains digits).
function Get-VersionTokenFromText {
    param([string]$Text)

    if (-not $Text) { return $null }

    # Prioritized patterns to extract a reasonable version token from free text.
    $patterns = @(
        # Date + commit (YYYY-MM-DD-abcdef)
        '(?<!\S)(?<ver>\d{4}-\d{2}-\d{2}-[a-f0-9]{7,40})(?!\S)',
        # ISO date
        '(?<!\S)(?<ver>\d{4}-\d{2}-\d{2})(?!\S)',
        # Git SHA (7-40 hex chars)
        '(?<!\S)(?<ver>[a-f0-9]{7,40})(?!\S)',
        # Semantic-like (requires at least one dot)
        '(?<!\S)(?<ver>\d+(?:\.\d+)+[\w\.-_]*)',
        # Long numeric (2+ digits)
        '(?<!\S)(?<ver>\d{2,})(?!\S)'
    )

    foreach ($p in $patterns) {
        if ($Text -match $p) {
            $candidate = $matches['ver']
            if ($candidate -and ($candidate -ne "couldn't")) {
                return $candidate
            }
        }
    }

    # As a final attempt, scan tokens but reject tokens that mix letters on both sides
    $tokens = $Text -split '\s+'
    foreach ($t in $tokens) {
        if ($t -match '\d') {
            # strip trailing punctuation
            $tok = $t.TrimEnd(':', ',', ';', '.')
            # Accept tokens that start or end with a digit (e.g., '1.2.3' or '123beta' or 'beta123')
            if ($tok -match '^\d' -or $tok -match '\d$') {
                return $tok
            }
        }
    }

    return $null
}

# Heuristic check that an extracted version looks reasonable.
function Test-VersionLooksValid {
    param([string]$v)

    if (-not $v) { return $false }

    # Allow pure numeric versions (build numbers)
    if ($v -match '^[0-9]+$') { return $true }

    # Allow ISO dates YYYY-MM-DD
    if ($v -match '^\d{4}-\d{2}-\d{2}$') { return $true }

    # Allow date-commit format YYYY-MM-DD-<sha>
    if ($v -match '^\d{4}-\d{2}-\d{2}-[a-f0-9]{7,40}$') { return $true }

    # Allow git SHAs (7+ hex characters)
    if ($v -match '^[a-f0-9]{7,40}$') { return $true }

    # Allow semantic-like versions: starts and ends with a digit and contains digits and dots/hyphens/underscores
    if ($v -match '^\d[0-9\.\-_]*\d$') { return $true }

    # Reject short tokens that mix letters with digits (e.g., '3k', 'ita3k')
    return $false
}

# Extract a version string from checkver output by looking for tokens that follow the app name.
function Get-VersionFromCheckverOutput {
    param(
        [string]$Output,
        [string]$AppName
    )

    if (-not $Output -or -not $AppName) { return $null }

    $normalized = $Output -replace "`r", ''
    $lines = $normalized -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        # Look for lines that start with the app name (e.g., "vita3k: 4835")
        if ($line -match '^' + [regex]::Escape($AppName) + ':(?<tail>.*)') {
            $tail = $matches['tail']
            # Try to extract a reasonable token from the tail and validate it
            $token = Get-VersionTokenFromText -Text $tail
            if ($token) {
                # Trim common surrounding punctuation
                $token = $token -replace '^[\s:"]+|[\s:"]+$', ''
                if (Test-VersionLooksValid -v $token) { return $token }
            }

            # If tail didn't yield a valid token, try the next non-empty line (some checkver scripts emit version on following line)
            if ($i + 1 -lt $lines.Count) {
                $nextLine = $lines[$i + 1]
                if ($nextLine -notmatch '^\(scoop version') {
                    $token = Get-VersionTokenFromText -Text $nextLine
                    if ($token) {
                        $token = $token -replace '^[\s:"]+|[\s:"]+$', ''
                        if (Test-VersionLooksValid -v $token) { return $token }
                    }
                }
            }
        }
    }

    # If no app-prefixed line matched, try to extract a token from the whole output and validate it
    $fallback = Get-VersionTokenFromText -Text $normalized
    if ($fallback) {
        $fallback = $fallback -replace '^[\s:"]+|[\s:"]+$', ''
        if (Test-VersionLooksValid -v $fallback) { return $fallback }
    }

    return $null
}

# Sort manifest keys according to Scoop standards
function Get-OrderedManifest {
    param([object]$Manifest)

    $orderedKeys = @(
        'version', 'description', 'homepage', 'license', 'notes', 'depends', 'suggest',
        'identifier', 'url', 'hash', 'architecture', 'extract_dir', 'extract_to',
        'pre_install', 'installer', 'post_install', 'env_add_path', 'env_set',
        'bin', 'shortcuts', 'persist', 'uninstaller', 'checkver', 'autoupdate',
        '64bit', '32bit', 'arm64'
    )

    $sorted = [ordered]@{}

    # Add known keys in order
    foreach ($key in $orderedKeys) {
        if ($Manifest.PSObject.Properties.Match($key).Count) {
            $sorted[$key] = $Manifest.$key
        }
    }

    # Add remaining keys
    foreach ($prop in $Manifest.PSObject.Properties) {
        if ($orderedKeys -notcontains $prop.Name) {
            $sorted[$prop.Name] = $prop.Value
        }
    }

    return $sorted
}

# Convert raw version strings into a canonical form
function ConvertTo-CanonicalVersion {
    param(
        [string]$RawVersion,
        [object]$Manifest,
        [string]$AppName
    )

    if (-not $RawVersion) { return $null }
    # Certain apps (historical or intentionally non-standard) should not be normalized.
    # DuckStation uses its own versioning; avoid auto-normalizing its version strings.
    if ($AppName -and $AppName -match '^duckstation') {
        return $RawVersion.Trim()
    }
    $v = $RawVersion.Trim()

    # Strip leading v and optional dot (v.1.2.3 -> 1.2.3)
    $v = $v -replace '^[vV]\.?', ''
    # Strip leading dots
    $v = $v -replace '^\.+', ''

    # If the value is purely numeric (build number), preserve as-is
    if ($v -match '^[0-9]+$') { return $v }

    # Preserve ISO-style dates (YYYY-MM-DD) exactly (nightly/date tags)
    if ($v -match '^\d{4}-\d{2}-\d{2}$') { return $v }

    # Preserve date-commit format (YYYY-MM-DD-hash)
    if ($v -match '^\d{4}-\d{2}-\d{2}-[a-f0-9]+$') { return $v }

    # If version contains a '-g<commit>' suffix (e.g. 20251115-g3d6627c), prefer the commit SHA alone
    # But only if it doesn't already contain semantic versioning (dots)
    if ($v -notmatch '\d+\.\d+' -and $v -match '-g(?<commit>[0-9a-f]{7})$') {
        return $matches['commit']
    }

    # Detect and temporarily strip common hyphenated suffixes (e.g. -master, -release)
    # But preserve git commit suffixes like -g<commit> and semantic build suffixes
    $hyphenSuffix = $null
    if ($v -match '(?<base>.+?)(-(?<suf>[a-zA-Z][\w-]*))$') {
        $suffix = $matches['suf']
        # Don't strip suffixes that look like git commits (g followed by hex) or semantic build info
        if ($suffix -notmatch '^g[a-f0-9]+$' -and $suffix -notmatch '^\d+.*') {
            $v = $matches['base']
            $hyphenSuffix = $suffix
        }
    }

    # If version looks like <build>-<commitSHA> (e.g. 3834-59250a6), prefer the build number only
    if ($v -match '^(?<build>\d+)[\-_](?<commit>[a-f0-9]{6,})$') {
        return $matches['build']
    }

    # If already has dots (semantic-like), return as-is
    if ($v -match '\d+\.\d+') { return $v }

    # If the version contains multiple digit groups separated by underscores/dots/hyphens
    # (e.g. beta_10_6, release-1-2-3), join them with dots to form a semantic-like version
    $digitMatches = [regex]::Matches($v, '\d+') | ForEach-Object { $_.Value }
    if ($digitMatches.Count -ge 2) {
        $candidate = ($digitMatches -join '.')

        # Preserve any trailing alpha suffix (e.g., 10_6b -> 10.6b)
        if ($v -match '[a-zA-Z]+$') { $candidate += $matches[0] }

        # Validate candidate against manifest URLs if provided
        if ($Manifest) {
            $candidates = @($candidate, "v$candidate", "v.$candidate", ".$candidate")
            foreach ($c in $candidates) {
                if ($Manifest.url -and $Manifest.url -match [regex]::Escape($c)) { return $candidate }
                if ($Manifest.architecture) {
                    $tmp64 = Get-ArchUrl -Manifest $Manifest -Arch '64bit'
                    if ($tmp64 -and ($tmp64 -match [regex]::Escape($c))) { return $candidate }
                    $tmp32 = Get-ArchUrl -Manifest $Manifest -Arch '32bit'
                    if ($tmp32 -and ($tmp32 -match [regex]::Escape($c))) { return $candidate }
                }
            }
        }

        # If no manifest match found, still return the candidate as a reasonable normalization
        if ($hyphenSuffix) {
            # If URLs mention the hyphen suffix, prefer candidate without suffix unless only suffixed form matches
            $withSuffix = "$candidate-$hyphenSuffix"
            if ($Manifest) {
                if ($Manifest.url -and $Manifest.url -match [regex]::Escape($candidate)) { return $candidate }
                if ($Manifest.url -and $Manifest.url -match [regex]::Escape($withSuffix)) { return $candidate }
                if ($Manifest.architecture) {
                    $tmp64 = Get-ArchUrl -Manifest $Manifest -Arch '64bit'
                    if ($tmp64 -and ($tmp64 -match [regex]::Escape($candidate))) { return $candidate }
                    $tmp32 = Get-ArchUrl -Manifest $Manifest -Arch '32bit'
                    if ($tmp32 -and ($tmp32 -match [regex]::Escape($candidate))) { return $candidate }
                    $tmp64 = Get-ArchUrl -Manifest $Manifest -Arch '64bit'
                    if ($tmp64 -and ($tmp64 -match [regex]::Escape($withSuffix))) { return $withSuffix }
                    $tmp32 = Get-ArchUrl -Manifest $Manifest -Arch '32bit'
                    if ($tmp32 -and ($tmp32 -match [regex]::Escape($withSuffix))) { return $withSuffix }
                }
            }
            return $candidate
        }

        return $candidate
    }

    # Try to find a contiguous run of digits in the value (fallback for single-run tags like mame0282)
    if ($v -match '(?<pre>.*?)(?<digits>\d+)(?<post>.*)') {
        $digits = $matches['digits']
        $prefix = $matches['pre']
        $post = $matches['post']

        # If it's a MAME-style tag like 'mame0282' or contains letters + digits,
        # convert by inserting a dot before the last 3 digits when length>=4
        if ($digits.Length -ge 4) {
            $left = $digits.Substring(0, $digits.Length - 3)
            $right = $digits.Substring($digits.Length - 3)
            $candidate = "$left.$right"
        } elseif ($digits.Length -eq 3) {
            # Treat 3-digit sequences as MAME-style only when there is a non-numeric prefix
            # (e.g., 'mame0282' -> '0.282'). If the raw value is purely numeric like '115',
            # return the digits unchanged.
            if ($prefix -match '[a-zA-Z]' -or $RawVersion -match '[a-zA-Z]') {
                $candidate = "0.$digits"
            } else {
                $candidate = $digits
            }
        } else {
            # Fallback: return digits as-is
            $candidate = $digits
        }

        # Append any trailing alpha suffix that was present (e.g., 0282b -> 0.282b)
        if ($post -match '[a-zA-Z]+') { $candidate += ($post -replace '[^a-zA-Z]', '') }

        # Validate candidate against manifest URLs if provided
        if ($Manifest) {
            $candidates = @($candidate, "v$candidate", "v.$candidate", ".$candidate")
            foreach ($c in $candidates) {
                if ($Manifest.url -and $Manifest.url -match [regex]::Escape($c)) { return $candidate }
                if ($Manifest.architecture) {
                    $tmp64 = Get-ArchUrl -Manifest $Manifest -Arch '64bit'
                    if ($tmp64 -and ($tmp64 -match [regex]::Escape($c))) { return $candidate }
                    $tmp32 = Get-ArchUrl -Manifest $Manifest -Arch '32bit'
                    if ($tmp32 -and ($tmp32 -match [regex]::Escape($c))) { return $candidate }
                }
            }
        }

        # If no manifest match found, still return the candidate as a reasonable normalization
        return $candidate
    }

    return $v
}

# Detect version scheme changes and attempt pattern recovery
function Repair-VersionPattern {
    param(
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

            Write-Host "  Recent tags: $((($tags | Select-Object -First 3) -join ', '))" -ForegroundColor Gray

            # Detect version scheme patterns
            if ($tags | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}' }) {
                Write-Host '  [INFO] Detected date-based versioning (YYYY-MM-DD)' -ForegroundColor Cyan
                return "date"
            } elseif ($tags | Where-Object { $_ -match '^v?\d+\.\d+\.\d+' }) {
                Write-Host '  [INFO] Detected semantic versioning' -ForegroundColor Cyan
                return "semantic"
            } elseif ($tags | Where-Object { $_ -match '^\d+$' }) {
                Write-Host '  [INFO] Detected numeric-only versioning' -ForegroundColor Cyan
                return "numeric"
            } else {
                Write-Host '  [INFO] Detected custom versioning scheme' -ForegroundColor Cyan
                return "custom"
            }
        }
    } catch {
        Write-Host ('  [WARN] Could not analyze recent releases: {0}' -f $_) -ForegroundColor Yellow
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
                Write-Host ('  [INFO] Found release with partial version match: {0}' -f $partialMatch[0].tag_name) -ForegroundColor Cyan
                return $partialMatch[0]
            }

            # Get latest release if no match found
            $latestRelease = $releases | Where-Object { !$_.prerelease -and !$_.draft } | Select-Object -First 1
            if ($latestRelease) {
                Write-Host ('  [WARN] No exact match found; using latest release: {0}' -f $latestRelease.tag_name) -ForegroundColor Yellow
                return $latestRelease
            }
        }
    } catch {
        Write-Host ('  [WARN] Pattern matching failed: {0}' -f $_) -ForegroundColor Yellow
    }

    return $null
}

# Auto-fix checkver pattern based on release analysis
function Repair-CheckverPattern {
    param([object]$ReleaseData)

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
function Get-ReleaseAsset {
    param([string]$Repo, [string]$Version, [string]$Platform = "github", [string]$Base = $null)

    try {
        if ($Platform -eq "github") {
            $apiUrl = "https://api.github.com/repos/$repo/releases/tags/$Version"
            $release = Invoke-RestMethod -Uri $apiUrl -ErrorAction SilentlyContinue -UseBasicParsing
            return $release.assets
        } elseif ($Platform -eq "gitlab") {
            $projectId = [Uri]::EscapeDataString($repo)
            $apiUrl = "https://gitlab.com/api/v4/projects/$projectId/releases/$Version"
            $release = Invoke-RestMethod -Uri $apiUrl -ErrorAction SilentlyContinue -UseBasicParsing

            # Convert GitLab response to similar format
            return $release.assets.sources | ForEach-Object {
                @{ name = $_.filename; browser_download_url = $_.url }
            }
        } elseif ($Platform -eq "gitea") {
            # For Gitea we expect either a Base host (e.g., https://gitea.example) + Repo path (owner/repo)
            if ($Base) {
                $apiUrl = "$Base/api/v1/repos/$Repo/releases/tags/$Version"
            } elseif ($Repo -match 'https?://') {
                # Repo already contains a URL like https://host/owner/repo
                $trimmed = $Repo -replace '/+$', ''
                $apiUrl = "$trimmed/api/v1/repos/$Repo/releases/tags/$Version"
            } else {
                # Can't construct a gitea API URL without base; try a best-effort default which will likely fail
                $apiUrl = "https://$Repo/api/v1/repos/$Repo/releases/tags/$Version"
            }
            $release = Invoke-RestMethod -Uri $apiUrl -ErrorAction SilentlyContinue -UseBasicParsing

            if ($release -and $release.assets) {
                return $release.assets | ForEach-Object { @{ name = $_.name; browser_download_url = $_.browser_download_url } }
            }
        }
    } catch {
        Write-Host ('  [WARN] {0} API error: {1}' -f $Platform, $_) -ForegroundColor Yellow
    }

    return @()
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
            Write-Host '    [WARN] Hash mismatch detected!' -ForegroundColor Yellow
            Write-Host "      Expected: $StoredHash" -ForegroundColor Yellow
            Write-Host "      Actual:   $actualHash" -ForegroundColor Yellow
            return @{ Mismatch = $true; ActualHash = $actualHash }
        }

        return @{ Mismatch = $false; ActualHash = $actualHash }
    } catch {
        Write-Host ('    [WARN] Hash verification failed: {0}' -f $_) -ForegroundColor Yellow
        return $null
    } finally {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

# Get hash from GitHub release checksum file
## Use Get-ReleaseChecksum from bin/lib-releasehelpers.ps1

# Download a file and compute its SHA256 hash
## Use Get-RemoteFileHash / ConvertTo-FileHash from bin/lib-releasehelpers.ps1

# Normalize MAME-style version tags (e.g., 'mame0282' -> '0.282')
function Convert-MameVersion {
    param([string]$Version)

    if ($Version -notmatch '^mame(?<digits>\d+)(?<suffix>[a-zA-Z]*)$') {
        return $Version
    }

    $digits = $matches['digits']
    $suffix = $matches['suffix']
    $normalized = $null

    if ($digits.Length -ge 4) {
        $normalized = $digits.Substring(0, 1) + '.' + $digits.Substring(1)
    } elseif ($digits.Length -gt 3) {
        $normalized = $digits.Substring(0, $digits.Length - 3) + '.' + $digits.Substring($digits.Length - 3)
    } else {
        $normalized = $digits
    }

    if ($suffix) { $normalized += $suffix }
    return $normalized
}

# Extract repository info (GitHub/GitLab/Gitea) from manifest checkver config
function Get-RepositoryInfo {
    param([object]$Manifest)

    $info = @{ Platform = $null; Path = $null; Base = $null }

    if ($Manifest.checkver.github) {
        $info.Platform = "github"
        if ($Manifest.checkver.github -match 'github\.com/([^/]+/[^/]+)') {
            $info.Path = $matches[1]
        }
    } elseif ($Manifest.checkver.gitlab) {
        $info.Platform = "gitlab"
        if ($Manifest.checkver.gitlab -match 'gitlab\.com/([^/]+/[^/]+)') {
            $info.Path = $matches[1]
        }
    } elseif ($Manifest.checkver.gitea) {
        $info.Platform = "gitea"
        if ($Manifest.checkver.gitea -match '(https?://[^/]+)/([^/]+/[^/]+)') {
            $info.Base = $matches[1]
            $info.Path = $matches[2]
        }
    }

    return $info
}

# Helpers for safe access/modification of architecture entries
function Initialize-ArchObject {
    param([object]$Manifest, [string]$Arch)
    if (-not $Manifest.architecture) { $Manifest.architecture = @{} }
    if (-not $Manifest.architecture.$Arch) { $Manifest.architecture.$Arch = @{} }
}

function Get-ArchUrl {
    param([object]$Manifest, [string]$Arch)
    if ($Manifest -and $Manifest.architecture -and $Manifest.architecture.$Arch -and $Manifest.architecture.$Arch.url) { return $Manifest.architecture.$Arch.url }
    return $null
}

function Set-ArchUrl {
    param([object]$Manifest, [string]$Arch, [string]$Url)
    Initialize-ArchObject -Manifest $Manifest -Arch $Arch
    $Manifest.architecture.$Arch.url = $Url
}

function Get-ArchHash {
    param([object]$Manifest, [string]$Arch)
    if ($Manifest -and $Manifest.architecture -and $Manifest.architecture.$Arch -and $Manifest.architecture.$Arch.hash) { return $Manifest.architecture.$Arch.hash }
    return $null
}

function Set-ArchHash {
    param([object]$Manifest, [string]$Arch, [string]$Hash)
    Initialize-ArchObject -Manifest $Manifest -Arch $Arch
    $Manifest.architecture.$Arch.hash = $Hash
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

    # If manifest explicitly uses the 'nightly' channel, do not run checkver — maintain dates/labels exactly
    $skipCheckver = $false
    if ($manifest.PSObject.Properties.Match('version').Count -and ($manifest.version -eq 'nightly' -or $manifest.version -eq 'dev')) {
        Write-Host '[INFO] Manifest uses ' -NoNewline; Write-Host "'$($manifest.version)'" -NoNewline; Write-Host ' channel; skipping checkver detection' -ForegroundColor Cyan
        $skipCheckver = $true
    }

    # Ensure checkver output variable exists
    $checkverOutput = ""

    # Extract Repository Info (GitHub/GitLab/Gitea)
    $repoInfo = Get-RepositoryInfo -Manifest $manifest
    $gitHubOwner = $null; $gitHubRepo = $null

    if ($repoInfo.Platform -eq "github") {
        if ($repoInfo.Path -match '^([^/]+)/(.+)$') {
            $gitHubOwner = $matches[1]; $gitHubRepo = $matches[2]
            Write-Verbose "GitHub repo detected: $gitHubOwner/$gitHubRepo"
        }
    }

    # Validate manifest structure
    $structureErrors = Test-ManifestStructure -Manifest $manifest
    if ($structureErrors) {
        Write-Host "Manifest structure issues detected:" -ForegroundColor Yellow
        foreach ($errorMsg in $structureErrors) {
            Write-Host ('  [WARN] {0}' -f $errorMsg) -ForegroundColor Yellow
            Add-Issue -Title "Structure Error" -Description $errorMsg -Severity "error"
        }
    }

    # Skip if no autoupdate (not an error, manifest is valid as-is)
    if (!$manifest.autoupdate) {
        Write-Host '[OK] No autoupdate section needed, manifest is valid'
        exit 0
    }

    $needsFix = $false
    $downloadsOk = $false
    $downloadStatus = Test-ManifestDownloadAccessibility -Manifest $manifest
    if ($downloadStatus.Success) {
        Write-Host '[INFO] Existing release assets are reachable' -ForegroundColor Cyan
        $downloadsOk = $true
    } else {
        Write-Host '[WARN] One or more release URLs are not accessible; attempting to repair the manifest' -ForegroundColor Yellow
        foreach ($failure in $downloadStatus.Failures) {
            Write-Host ('  [INFO] Could not reach {0} URL: {1}' -f $failure.Type, $failure.Url) -ForegroundColor Yellow
            if ($failure.Error) { Write-Host ('    [INFO] Error: {0}' -f $failure.Error) -ForegroundColor Yellow }
        }
        $needsFix = $true
    }

    # Try to get latest version from checkver
    $checkverScript = "$PSScriptRoot/checkver.ps1"

    if (!(Test-Path $checkverScript)) {
        Write-Host '[WARN] checkver script not found, cannot validate updates'
        exit 1
    }

    $latestVersion = $null

    # Try to get latest version from APIs first (Priority)
    if ($repoInfo.Platform -eq "github" -and $repoInfo.Path) {
        Write-Host "Checking GitHub Releases for $($repoInfo.Path)..."
        try {
            $apiUrl = "https://api.github.com/repos/$($repoInfo.Path)/releases/latest"
            $latestRelease = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop

            if ($latestRelease) {
                $latestVersion = if ($latestRelease.tag_name) { $latestRelease.tag_name } else { $latestRelease.name }
                $latestVersion = $latestVersion -replace '^v', '' -replace '^\.', ''
                if ($latestVersion) {
                    Write-Host ('  [INFO] Found version from GitHub Releases: {0}' -f $latestVersion) -ForegroundColor Cyan
                }
            }
        } catch {
            Write-Host ('  [WARN] Failed to check GitHub Releases: {0}' -f $_) -ForegroundColor Yellow
        }
    } elseif ($repoInfo.Platform -eq "gitlab" -and $repoInfo.Path) {
        Write-Host "Checking GitLab Releases for $($repoInfo.Path)..."
        try {
            $id = [Uri]::EscapeDataString($repoInfo.Path)
            $apiUrl = "https://gitlab.com/api/v4/projects/$id/releases"
            $releases = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
            if ($releases -and $releases.Count -gt 0) {
                $latestVersion = $releases[0].tag_name -replace '^v', '' -replace '^\.', ''
                Write-Host ('  [INFO] Found version from GitLab Releases: {0}' -f $latestVersion) -ForegroundColor Cyan
            }
        } catch {
            Write-Host ('  [WARN] Failed to check GitLab Releases: {0}' -f $_) -ForegroundColor Yellow
        }
    } elseif ($repoInfo.Platform -eq "gitea" -and $repoInfo.Path -and $repoInfo.Base) {
        Write-Host "Checking Gitea Releases for $($repoInfo.Path)..."
        try {
            $apiUrl = "$($repoInfo.Base)/api/v1/repos/$($repoInfo.Path)/releases?limit=1"
            $releases = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
            if ($releases -and $releases.Count -gt 0) {
                $latestVersion = $releases[0].tag_name -replace '^v', '' -replace '^\.', ''
                Write-Host ('  [INFO] Found version from Gitea Releases: {0}' -f $latestVersion) -ForegroundColor Cyan
            }
        } catch {
            Write-Host ('  [WARN] Failed to check Gitea Releases: {0}' -f $_) -ForegroundColor Yellow
        }
    }

    if (-not $latestVersion) {
        if (-not $skipCheckver) {
            Write-Host "Running checkver..."
            $checkverOutput = & $checkverScript -App $appName -Dir $BucketPath 2>&1 | Out-String
        } else {
            Write-Host '[INFO] Skipping checkver because manifest is ' -NoNewline; Write-Host "'nightly'" -ForegroundColor Cyan
        }
    }

    # Check if checkver output indicates a regex matching failure
    if ($checkverOutput -match "couldn't match") {
        Write-Host '[WARN] Checkver regex pattern does' -NoNewline; Write-Host "'" -NoNewline; Write-Host 't match, attempting to fix checkver config...' -ForegroundColor Yellow

        if ($repoInfo.Platform -eq "github" -and $repoInfo.Path) {
            try {
                $apiUrl = "https://api.github.com/repos/$($repoInfo.Path)/releases/latest"
                $latestRelease = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop

                if ($latestRelease -and $latestRelease.tag_name) {
                    # Repair checkver to use API-based version detection
                    $manifest.checkver = @{
                        "url"      = "https://api.github.com/repos/$($repoInfo.Path)/releases/latest"
                        "jsonpath" = "$.tag_name"
                        "regex"    = "v([0-9.]+)"
                    }
                    $checkverRepaired = $true
                    Write-Host '  [OK] Repaired checkver config to use API-based detection' -ForegroundColor Green

                    $latestVersion = $latestRelease.tag_name -replace '^v', '' -replace '^\.', ''
                    Write-Host ('  [INFO] Using version from checkver: {0}' -f $latestVersion) -ForegroundColor Gray
                }
            } catch {
                Write-Host ('  [WARN] Could not repair checkver: {0}' -f $_) -ForegroundColor Yellow
            }
        }
    }

    # Parse version from checkver output if not already obtained
    if (-not $latestVersion) {
        $latestVersion = Get-VersionFromCheckverOutput -Output $checkverOutput -AppName $appName
        if ($latestVersion) {
            Write-Host ('  [INFO] Using version from checkver: {0}' -f $latestVersion) -ForegroundColor Gray
        }
    }

    if (-not $latestVersion) {
        # Checkver itself failed - attempt recovery
        Write-Host '[WARN] Checkver execution failed or returned 404, attempting API fallback...' -ForegroundColor Yellow

        if ($repoInfo.Platform -eq "github" -and $repoInfo.Path) {
            Write-Host "  Detecting version scheme from repository..." -ForegroundColor Gray
            Repair-VersionPattern -RepoPath $repoInfo.Path -Platform $repoInfo.Platform | Out-Null

            try {
                $apiUrl = "https://api.github.com/repos/$($repoInfo.Path)/releases/latest"
                $latestRelease = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop

                if ($latestRelease) {
                    $latestVersion = if ($latestRelease.tag_name) { $latestRelease.tag_name } else { $latestRelease.name }
                    $latestVersion = $latestVersion -replace '^v', '' -replace '^\.', ''

                    if ($latestVersion) {
                        Write-Host '[OK] Recovered version from latest release: ' -NoNewline; Write-Host $latestVersion -ForegroundColor Green
                    }
                }
            } catch {
                Write-Host ('  [WARN] API fallback also failed: {0}' -f $_) -ForegroundColor Yellow
            }
        }
    }

    if ($latestVersion) {
        # If checkver returned a short git SHA (7 hex chars) but the manifest uses GitHub releases,
        # prefer the latest release tag instead of treating the SHA as a numeric version.
        if ($latestVersion -match '^[a-f0-9]{7}$') {
            try {
                # If repo not already extracted, try to parse it from checkver.url (e.g., actions/workflows URL)
                if (-not $gitHubOwner -and -not $gitHubRepo -and $manifest.checkver -and $manifest.checkver.url -and ($manifest.checkver.url -match 'github\.com/([^/]+)/([^/]+)/?')) {
                    $gitHubOwner = $matches[1]; $gitHubRepo = $matches[2]
                }

                if ($gitHubOwner -and $gitHubRepo -and ($manifest.autoupdate -and ($manifest.autoupdate.url -match '/releases/download' -or ($manifest.autoupdate.architecture -and ($manifest.autoupdate.architecture.'64bit'.url -match '/releases/download' -or $manifest.autoupdate.architecture.'32bit'.url -match '/releases/download')) ) -or ($manifest.checkver -and $manifest.checkver.url -and $manifest.checkver.url -match 'actions/workflows'))) {
                    Write-Host "  [INFO] checkver returned a commit SHA; querying GitHub Releases for canonical tag..." -ForegroundColor Cyan
                    $apiUrl = "https://api.github.com/repos/$gitHubOwner/$gitHubRepo/releases/latest"
                    $rel = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
                    if ($rel) {
                        if ($rel.tag_name) { $latestVersion = $rel.tag_name -replace '^v', '' -replace '^\.', '' ; Write-Host ('  [OK] Using latest release tag: {0}' -f $latestVersion) -ForegroundColor Green }
                            elseif ($rel.name) { $latestVersion = $rel.name; Write-Host ('  [OK] Using latest release name: {0}' -f $latestVersion) -ForegroundColor Green }
                    }
                }
            } catch {
                Write-Host ('  [WARN] Could not fetch latest release tag: {0}' -f $_) -ForegroundColor Yellow
            }
        }

        # Normalize latestVersion into canonical form (handles tags like v.0.12.5, .0.12.5, mame0282)
        try { $latestVersion = ConvertTo-CanonicalVersion -RawVersion $latestVersion -Manifest $manifest -AppName $appName } catch { }

        # Basic sanity check: ensure the extracted version looks like a version token (contains digits, date, or short SHA)
        if (-not (Test-VersionLooksValid -v $latestVersion)) {
            Write-Host '[WARN] Extracted version looks invalid: ' -NoNewline; Write-Host "'$latestVersion'" -NoNewline; Write-Host ' — aborting auto-fix to avoid corrupting manifest' -ForegroundColor Yellow
            Add-Issue -Title "Invalid version extracted" -Description "Extracted version '$latestVersion' for $appName does not resemble a valid version token" -Severity "error"
            exit 2
        }

        $currentVersion = $manifest.version

        if ($latestVersion -eq $currentVersion) {
            # If checkver was repaired, save the manifest even though version didn't change
            if ($checkverRepaired) {
                Write-Host '[OK] Checkver repaired, saving manifest...' -ForegroundColor Green
                $updatedJson = $manifest | ConvertTo-Json -Depth 10
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)
                Write-Host '[OK] Manifest saved with repaired checkver'
                exit 0
            }

            # If the current version is in a non-canonical form (e.g., 'mame0282'), try to canonicalize using checkver
            if ($currentVersion -match '^mame\d+' -or $currentVersion -match '^\.' -or ($currentVersion -notmatch '\d+\.\d+')) {
                Write-Host '[INFO] Current version format looks non-canonical: ' -NoNewline; Write-Host $currentVersion -NoNewline; Write-Host '. Attempting canonicalization via checkver...' -ForegroundColor Cyan
                try {
                    if (Test-Path $checkverScript) {
                        $checkverOutput = & $checkverScript -App $appName -Dir $BucketPath 2>&1 | Out-String
                        $detectedVersion = Get-VersionFromCheckverOutput -Output $checkverOutput -AppName $appName

                        if ($detectedVersion) {
                            $detectedVersion = $detectedVersion -replace '^v', ''
                            $detectedVersion = Convert-MameVersion -Version $detectedVersion

                            if ($detectedVersion -ne $manifest.version) {
                                Write-Host ('  [OK] Canonical version from checkver: {0} (was {1})' -f $detectedVersion, $manifest.version) -ForegroundColor Green
                                $manifest.version = ([string]$detectedVersion) -replace '^\.+', ''
                                $sortedManifest = Get-OrderedManifest -Manifest $manifest
                                $updatedJson = $sortedManifest | ConvertTo-Json -Depth 10
                                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                                [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)
                                Write-Host '[OK] Manifest canonicalized and saved' -ForegroundColor Green
                                exit 0
                            }
                        }
                    }
                } catch {
                    Write-Host ('  [WARN] checkver canonicalization failed: {0}' -f $_) -ForegroundColor Yellow
                }
            }

            Write-Host '[OK] Manifest already up-to-date (' -NoNewline; Write-Host $currentVersion -NoNewline; Write-Host ')'
            exit 0
        }

        # If downloads were reachable and we couldn't detect any newer version, avoid making changes
        if ($downloadsOk -and -not $latestVersion) {
            Write-Host '[OK] Existing release assets reachable and no newer version detected; nothing to fix' -ForegroundColor Green
            exit 0
        }

        Write-Host "Found update: $currentVersion -> $latestVersion" -ForegroundColor Yellow

        # Update version in memory object (ensure it's stored as a string to preserve JSON quoting)
        $manifest.version = [string]$latestVersion
        # Normalize: strip any leading dot that may appear from URL patterns like 'v.$version'
        if ($manifest.version -match '^\.(.+)') { $manifest.version = $matches[1] }

        # Attempt to detect and fix URL issues
        Write-Host "Analyzing download URLs..."

        # Check if URLs have 404s and try to fix them
        $urlPatterns = @()

        # Collect all URLs from manifest
        if ($manifest.url) { $urlPatterns += @{ type = 'generic'; url = $manifest.url } }
        $a64 = Get-ArchUrl -Manifest $manifest -Arch '64bit'
        if ($a64) { $urlPatterns += @{ type = '64bit'; url = $a64 } }
        $a32 = Get-ArchUrl -Manifest $manifest -Arch '32bit'
        if ($a32) { $urlPatterns += @{ type = '32bit'; url = $a32 } }

        foreach ($urlPattern in $urlPatterns) {
            $oldUrl = $urlPattern.url
            $arch = $urlPattern.type

            # Try to construct new URL based on version change
            $newUrl = $oldUrl -replace [regex]::Escape($currentVersion), $latestVersion
            $urlChanged = $newUrl -ne $oldUrl
            $urlValid = $false

            Write-Host "Checking $arch URL..."

            # If URL structure suggests it depends on version, try new URL first
            if ($urlChanged) {
                try {
                    $response = Invoke-WebRequest -Uri $newUrl -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                    if ($response.StatusCode -eq 200) {
                        Write-Host ('  [OK] Fixed URL found with version substitution: {0}' -f $newUrl) -ForegroundColor Green

                        # Update manifest with new URL
                        if ($arch -eq "generic") {
                            $manifest.url = $newUrl
                        } elseif ($arch -eq "64bit") {
                            Set-ArchUrl -Manifest $manifest -Arch '64bit' -Url $newUrl
                        } elseif ($arch -eq "32bit") {
                            Set-ArchUrl -Manifest $manifest -Arch '32bit' -Url $newUrl
                        }

                        continue
                    }
                } catch {
                    Write-Host '  [INFO] Version-substituted URL not accessible'
                }
            }

            # If new URL failed or wasn't tried, check old URL
            if (!$urlValid) {
                try {
                    $response = Invoke-WebRequest -Uri $oldUrl -Method Head -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                    if ($response.StatusCode -eq 200) {
                        Write-Host '  [OK] Current URL still valid'
                        $urlValid = $true

                        # Verify hash if it exists (top-level or architecture-specific)
                        $currentHash = if ($arch -eq "generic") { $manifest.hash } else { Get-ArchHash -Manifest $manifest -Arch $arch }
                        if ($currentHash) {
                            $hashResult = Test-HashMismatch -Url $oldUrl -StoredHash $currentHash
                            if ($hashResult -and $hashResult.Mismatch) {
                                Write-Host '    [OK] Auto-fixing hash mismatch' -ForegroundColor Green
                                if ($arch -eq "generic") {
                                    $manifest.hash = $hashResult.ActualHash.ToLower()
                                } else {
                                    Set-ArchHash -Manifest $manifest -Arch $arch -Hash $hashResult.ActualHash.ToLower()
                                }
                            }
                        }
                    }
                    continue
                } catch {
                    Write-Host ('  [FAIL] Current URL returned error: {0}' -f $_.Exception.Message)
                }
            }

            if (!$urlValid) {
                Write-Host '  [FAIL] URL is not accessible - attempting to fix'
            }

            # If URL is not valid, try version-substituted URL first (already tried above, but logic flow continues)
            # We can skip this block as we already tried substitution above

            # Try to find via repository API (GitHub, GitLab, Gitea)
            if (!$repoInfo.Platform -or !$repoInfo.Path) {
                # Fallback: try to extract from alternate config locations if not already found
                Write-Host '  [WARN] Repository not configured in checkver; cannot lookup assets' -ForegroundColor Yellow
                continue
            }

            Write-Host "  Attempting $($repoInfo.Platform) API lookup for version: $latestVersion..."

            try {
                $assets = Get-ReleaseAsset -Repo $repoInfo.Path -Version $latestVersion -Platform $repoInfo.Platform -Base $repoInfo.Base

                # If release not found with exact version, attempt pattern matching
                if (!$assets -or $assets.Count -eq 0) {
                    Write-Host ('  [WARN] Release tag ''{0}'' not found, attempting pattern match...' -f $latestVersion) -ForegroundColor Yellow

                    $release = Find-ReleaseByPatternMatch -RepoPath $repoInfo.Path -TargetVersion $latestVersion -Platform $repoInfo.Platform

                    if ($release) {
                        # Update latestVersion to the found release
                        if ($release.tag_name) {
                            $latestVersion = $release.tag_name -replace '^v', '' -replace '^\.', ''  # Strip 'v' prefix and leading dot if present
                        } elseif ($release.name) {
                            $latestVersion = $release.name
                        }

                        Write-Host ('  [OK] Updated version to: {0}' -f $latestVersion) -ForegroundColor Green

                        # Try to get assets from the matched release
                        $assets = Get-ReleaseAsset -Repo $repoInfo.Path -Version $release.tag_name -Platform $repoInfo.Platform -Base $repoInfo.Base

                        # If still no assets but we have release info, try alternative version formats
                        if (!$assets -or $assets.Count -eq 0) {
                            # Try version without 'v' prefix
                            $versionAlt = $release.tag_name -replace '^v', '' -replace '^\.', ''
                            if ($versionAlt -ne $release.tag_name) {
                                $assets = Get-ReleaseAsset -Repo $repoInfo.Path -Version $versionAlt -Platform $repoInfo.Platform -Base $repoInfo.Base
                            }
                            # Try version with 'v' prefix
                            if ((!$assets -or $assets.Count -eq 0) -and $release.tag_name -notmatch '^v') {
                                $assets = Get-ReleaseAsset -Repo $repoInfo.Path -Version "v$($release.tag_name)" -Platform $repoInfo.Platform -Base $repoInfo.Base
                            }
                        }
                    } else {
                        Write-Host '  [WARN] No release found matching version pattern' -ForegroundColor Yellow
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
                        $asset = $windowsAssets | Where-Object { $_.name -match "x86\.?32|win32|i386|386|ia32" -and $_.name -match "\.(zip|exe|msi|7z)$" } | Sort-Object { $_.name -match "\.zip$" } -Descending | Select-Object -First 1
                        # Second try: Any asset with 32-bit patterns
                        if (!$asset) {
                            $asset = $archiveAssets | Where-Object { $_.name -match "x86\.?32|win32|i386|386|ia32" -and $_.name -match "\.(zip|exe|msi|7z)$" } | Sort-Object { $_.name -match "\.zip$" } -Descending | Select-Object -First 1
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
                        Write-Host ('  [OK] API found asset for {0}: {1}' -f $arch, $asset.name) -ForegroundColor Green

                        if ($arch -eq "generic") {
                            $manifest.url = $fixedUrl
                        } elseif ($arch -eq "64bit") {
                            Set-ArchUrl -Manifest $manifest -Arch '64bit' -Url $fixedUrl
                        } elseif ($arch -eq "32bit") {
                            Set-ArchUrl -Manifest $manifest -Arch '32bit' -Url $fixedUrl
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
                                Set-ArchHash -Manifest $manifest -Arch $arch -Hash $hash.ToLower()
                            }
                            Write-Host ('  [OK] Updated hash for {0} asset' -f $arch) -ForegroundColor Green
                        }
                    } else {
                        Write-Host ('  [WARN] No matching Windows asset found in release for {0}' -f $arch) -ForegroundColor Yellow
                    }
                } else {
                        Write-Host ('  [WARN] Could not retrieve assets from {0} API' -f $repoPlatform) -ForegroundColor Yellow
                }
            } catch {
                Write-Host ('  [WARN] API lookup failed: {0}' -f $_)
                Add-Issue -Title "URL Resolution Failed" -Description "Could not resolve download URL for $appName $arch" -Severity "warning"
            }
        }

        # Calculate hashes for new URLs (try GitHub release checksums first)
        Write-Host "Getting hashes for updated URLs..."

        # Try to fetch GitHub release assets if available (for checksum files)
        $releaseAssets = $null
        $hasChecksumFiles = $false
        if ($gitHubOwner -and $gitHubRepo) {
            $releaseAssets = Get-ReleaseAsset -Repo "$gitHubOwner/$gitHubRepo" -Version "v$($manifest.version)" -Platform "github"
            if (-not $releaseAssets) {
                # Try without 'v' prefix
                $releaseAssets = Get-ReleaseAsset -Repo "$gitHubOwner/$gitHubRepo" -Version $manifest.version -Platform "github"
            }
            # Check if checksum files exist
            if ($releaseAssets) {
                $checksumFiles = @($releaseAssets | Where-Object { $_.name -like '*.sha256' -or $_.name -like '*.sha256sum' -or $_.name -like '*.checksum' })
                $hasChecksumFiles = $checksumFiles.Count -gt 0
            }
        }

        $hashTargets = @()
        if ($manifest.url) { $hashTargets += @{ Name = 'Generic'; Obj = $manifest; Url = $manifest.url } }
        $tmp64 = Get-ArchUrl -Manifest $manifest -Arch '64bit'
        if ($tmp64) { $hashTargets += @{ Name = '64bit'; Obj = $manifest.architecture.'64bit'; Url = $tmp64 } }
        $tmp32 = Get-ArchUrl -Manifest $manifest -Arch '32bit'
        if ($tmp32) { $hashTargets += @{ Name = '32bit'; Obj = $manifest.architecture.'32bit'; Url = $tmp32 } }

        $forceRewrite = $false

        foreach ($target in $hashTargets) {
            $targetName = $target.Name
            $targetObj = $target.Obj
            $targetUrl = $target.Url

            # If checksum files exist in release, use API-based hash lookup
            if ($hasChecksumFiles -and $releaseAssets) {
                $fileName = Split-Path -Leaf $targetUrl
                $hashValue = [ordered]@{
                    "url"      = "https://api.github.com/repos/$gitHubOwner/$gitHubRepo/releases/latest"
                    "jsonpath" = '$.assets[?(@.name == ''' + $fileName + ''')].digest'
                }

                if ($targetObj.PSObject.Properties.Match('hash').Count) {
                    $targetObj.hash = $hashValue
                } else {
                    $targetObj | Add-Member -MemberType NoteProperty -Name "hash" -Value $hashValue
                    $forceRewrite = $true
                }
                Write-Host ('  [OK] {0} hash configured for API lookup: {1}' -f $targetName, $fileName)
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
                    if ($targetObj.PSObject.Properties.Match('hash').Count) {
                        $targetObj.hash = $newHash
                    } else {
                        $targetObj | Add-Member -MemberType NoteProperty -Name "hash" -Value $newHash
                        $forceRewrite = $true
                        Write-Host '  [INFO] Added missing hash field, will rewrite manifest' -ForegroundColor Gray
                    }
                    Write-Host ('  [OK] {0} hash updated' -f $targetName)
                } else {
                    if ($targetName -ne 'Generic') {
                        Write-Host ('  [WARN] Could not get {0} hash' -f $targetName)
                    }
                }
            }
        }

        # Ensure version property is a string before any rewrite (prevents ConvertTo-Json from emitting a bare number)
        if ($manifest.PSObject.Properties.Match('version').Count) {
            $manifest.version = [string]$manifest.version
            if ($manifest.version -match '^\.(.+)') { $manifest.version = $matches[1] }
        }

        # If we added new fields (like hash), we must rewrite the file using ConvertTo-Json
        # because regex replacement can't easily insert new lines in the right place
        if ($forceRewrite) {
            Write-Host '  [INFO] Rewriting manifest to include new fields...' -ForegroundColor Cyan

            # Sort keys before saving
            $sortedManifest = Get-OrderedManifest -Manifest $manifest
            $updatedJson = $sortedManifest | ConvertTo-Json -Depth 10

            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)

            # Format the JSON to match Scoop standards
            $formatScript = "$PSScriptRoot/formatjson.ps1"
            if (Test-Path $formatScript) {
                Write-Host '  [INFO] Formatting manifest...' -ForegroundColor Cyan
                try {
                    $output = & $formatScript -App $appName 2>&1
                    # formatjson.ps1 is a PS script; prefer checking $? (and $LASTEXITCODE as extra) to detect failure
                    if ($LASTEXITCODE -ne 0 -or -not $?) {
                        Write-Host ('  [WARN] Formatting failed: {0}' -f $output) -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host ('  [WARN] Formatting script error: {0}' -f $_) -ForegroundColor Yellow
                }
            }

            # After saving, run checkver to ensure version is canonical according to checkver
            try {
                if (Test-Path $checkverScript) {
                    Write-Host '  [INFO] Running checkver to determine canonical version...' -ForegroundColor Cyan
                    $checkverOutput = & $checkverScript -App $appName -Dir $BucketPath 2>&1 | Out-String

                    # Try to extract version from checkver output
                    $detectedVersion = Get-VersionFromCheckverOutput -Output $checkverOutput -AppName $appName

                    if ($detectedVersion) {
                        $detectedVersion = $detectedVersion -replace '^v', ''

                        # Validate that detected version appears in updated URLs (to avoid spurious small numbers)
                        $versionValid = $false
                        if ($manifest.url -and ($manifest.url -match [regex]::Escape($detectedVersion) -or $manifest.url -match [regex]::Escape("v$detectedVersion"))) { $versionValid = $true }
                        if (-not $versionValid -and $manifest.architecture) {
                            $tmp64 = Get-ArchUrl -Manifest $manifest -Arch '64bit'
                            if ($tmp64 -and ($tmp64 -match [regex]::Escape($detectedVersion))) { $versionValid = $true }
                            $tmp32 = Get-ArchUrl -Manifest $manifest -Arch '32bit'
                            if ($tmp32 -and ($tmp32 -match [regex]::Escape($detectedVersion))) { $versionValid = $true }
                        }

                        if (-not $versionValid) {
                            # Fallback: try to extract version from URL patterns (look for v<digits> or _v<digits>)
                            $found = $null
                            if ($manifest.url -and ($manifest.url -match 'v\.\?(?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] }
                            if (-not $found) { $tmp64 = Get-ArchUrl -Manifest $manifest -Arch '64bit'; if ($tmp64 -and ($tmp64 -match 'v\.\?(?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] } }
                            if (-not $found) { $tmp32 = Get-ArchUrl -Manifest $manifest -Arch '32bit'; if ($tmp32 -and ($tmp32 -match 'v\.\?(?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] } }

                            if ($found) {
                                Write-Host ('  [WARN] Checkver returned ''{0}'' which doesn''t match URLs; using version parsed from URL: {1}' -f $detectedVersion, $found) -ForegroundColor Yellow
                                $detectedVersion = $found
                                $versionValid = $true
                            } else {
                                Write-Host ('  [WARN] checkver returned ''{0}'' which doesn''t match updated URLs; ignoring' -f $detectedVersion) -ForegroundColor Yellow
                                $versionValid = $false
                            }
                        }

                        if ($versionValid -and $detectedVersion -ne $manifest.version) {
                            if ($appName -and $appName -match '^duckstation') {
                                Write-Host ('  [INFO] Detected canonical version but skipping canonicalization for {0}' -f $appName) -ForegroundColor Yellow
                            } else {
                                Write-Host ('  [OK] Using canonical version: {0} (was {1})' -f $detectedVersion, $manifest.version) -ForegroundColor Green
                                $manifest.version = ([string]$detectedVersion) -replace '^\.+', ''

                                # Rewrite manifest with updated version
                                $sortedManifest = Get-OrderedManifest -Manifest $manifest
                                $updatedJson = $sortedManifest | ConvertTo-Json -Depth 10
                                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                                [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)
                            }
                        }
                    } else {
                        Write-Host '  [WARN] checkver did not return a parseable version' -ForegroundColor Yellow
                    }
                }
            } catch {
                Write-Host ('  [WARN] Running checkver failed: {0}' -f $_) -ForegroundColor Yellow
            }

            if ($needsFix) {
                if (-not (Test-FixIntegrity -ManifestPath $ManifestPath -AppName $appName)) {
                    Write-Host '[FAIL] Validation failed; aborting auto-fix' -ForegroundColor Red
                    exit 2
                }
            }

            Write-Host '[OK] Manifest auto-fixed and saved' -ForegroundColor Green
            exit 0
        }

        # Save updated manifest - preserve original formatting by doing targeted text replacements
        $originalContent = Get-Content $ManifestPath -Raw
        $updatedContent = $originalContent

        # Update version in text content if it changed
        if ($currentVersion -ne $latestVersion) {
            # Try to replace quoted version first, then unquoted numeric version if present
            $quotedPattern = '"version":\s*"' + [regex]::Escape($currentVersion) + '"'
            $unquotedPattern = '"version":\s*' + [regex]::Escape($currentVersion) + '(?![\d\w\._-])'

            if ($updatedContent -match $quotedPattern) {
                $updatedContent = $updatedContent -replace $quotedPattern, "`"version`": `"$latestVersion`""
                Write-Host '  [OK] Updated quoted version in manifest text' -ForegroundColor Green
            } elseif ($updatedContent -match $unquotedPattern) {
                # Handle numeric/unquoted version
                $updatedContent = $updatedContent -replace $unquotedPattern, "`"version`": `"$latestVersion`""
                Write-Host '  [OK] Updated unquoted numeric version in manifest text (now quoted)' -ForegroundColor Green
            }
        }

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
                $tmpUrl = Get-ArchUrl -Manifest $manifest -Arch '64bit'
                if ($tmpUrl -and $tmpUrl -ne $pattern.url) {
                    $newUrl = $tmpUrl
                    $newHash = Get-ArchHash -Manifest $manifest -Arch '64bit'
                }
            } elseif ($arch -eq "32bit") {
                $tmpUrl = Get-ArchUrl -Manifest $manifest -Arch '32bit'
                if ($tmpUrl -and $tmpUrl -ne $pattern.url) {
                    $newUrl = $tmpUrl
                    $newHash = Get-ArchHash -Manifest $manifest -Arch '32bit'
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
            # use single-quoted regex string to stay PS5.1-safe when it contains character classes
            $hashPattern = '"hash":\s*"([a-f0-9]+)"'

            # Find the line with this URL
            $lines = $updatedContent -split "`r`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match $urlPattern) {
                    # Replace URL on this line
                    $lines[$i] = $lines[$i] -replace $urlPattern, $newUrl

                    # Look for hash on the next few lines
                    for ($j = $i + 1; $j -lt ($i + 5) -and $j -lt $lines.Count; $j++) {
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

        # After targeted text replacements, run checkver to canonicalize version
        try {
            if (Test-Path $checkverScript) {
                Write-Host '  [INFO] Running checkver to determine canonical version...' -ForegroundColor Cyan
                $checkverOutput = & $checkverScript -App $appName -Dir $BucketPath 2>&1 | Out-String

                $detectedVersion = Get-VersionFromCheckverOutput -Output $checkverOutput -AppName $appName

                if ($detectedVersion) {
                    $detectedVersion = $detectedVersion -replace '^v', ''
                    $detectedVersion = Convert-MameVersion -Version $detectedVersion

                    # Validate that detected version appears in updated URLs (to avoid spurious small numbers)
                    $versionValid = $false
                    if ($manifest.url -and ($manifest.url -match [regex]::Escape($detectedVersion) -or $manifest.url -match [regex]::Escape("v$detectedVersion"))) { $versionValid = $true }
                    if (-not $versionValid -and $manifest.architecture) {
                        $tmp64 = Get-ArchUrl -Manifest $manifest -Arch '64bit'
                        if ($tmp64 -and ($tmp64 -match [regex]::Escape($detectedVersion))) { $versionValid = $true }
                        $tmp32 = Get-ArchUrl -Manifest $manifest -Arch '32bit'
                        if ($tmp32 -and ($tmp32 -match [regex]::Escape($detectedVersion))) { $versionValid = $true }
                    }

                    if (-not $versionValid) {
                        # Try to extract version from URL patterns (look for v<digits> or _v<digits>)
                        $found = $null
                        if ($manifest.url -and ($manifest.url -match 'v\.?(?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] }
                        if (-not $found) { $tmp64 = Get-ArchUrl -Manifest $manifest -Arch '64bit'; if ($tmp64 -and ($tmp64 -match 'v\.?(?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] } }
                        if (-not $found) { $tmp32 = Get-ArchUrl -Manifest $manifest -Arch '32bit'; if ($tmp32 -and ($tmp32 -match 'v\.?(?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] } }

                        if ($found) {
                            Write-Host ('  [WARN] Checkver returned ''{0}'' which doesn''t match URLs; using version parsed from URL: {1}' -f $detectedVersion, $found) -ForegroundColor Yellow
                            $detectedVersion = $found
                            $versionValid = $true
                        } else {
                            Write-Host ('  [WARN] checkver returned ''{0}'' which doesn''t match updated URLs; ignoring' -f $detectedVersion) -ForegroundColor Yellow
                            $versionValid = $false
                        }
                    }

                    if ($versionValid -and $detectedVersion -ne $manifest.version) {
                        if ($appName -and $appName -match '^duckstation') {
                            Write-Host ('  [INFO] Detected canonical version but skipping canonicalization for {0}' -f $appName) -ForegroundColor Yellow
                        } else {
                            Write-Host ('  [OK] Using canonical version: {0} (was {1})' -f $detectedVersion, $manifest.version) -ForegroundColor Green
                            $manifest.version = ([string]$detectedVersion) -replace '^\.+', ''

                            # Rewrite file to ensure version is quoted and consistent
                            $sortedManifest = Get-OrderedManifest -Manifest $manifest
                            $updatedJson = $sortedManifest | ConvertTo-Json -Depth 10
                            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                            [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)
                        }
                    }
                } else {
                    Write-Host '  [WARN] checkver did not return a parseable version' -ForegroundColor Yellow
                }
            }
        } catch {
            Write-Host ('  [WARN] Running checkver failed: {0}' -f $_) -ForegroundColor Yellow
        }

        if ($needsFix) {
            if (-not (Test-FixIntegrity -ManifestPath $ManifestPath -AppName $appName)) {
                Write-Host '[FAIL] Validation failed; aborting auto-fix' -ForegroundColor Red
                exit 2
            }
        }

        Write-Host '[OK] Manifest auto-fixed and saved' -ForegroundColor Green

        # Log any issues for manual review
        if ($issues.Count -gt 0 -and $NotifyOnIssues -and $IssueLog) {
            $issues | ConvertTo-Json | Add-Content -Path $IssueLog
            Write-Host '[WARN] Issues logged for manual review' -ForegroundColor Yellow

            # Create GitHub issue with Copilot tag
            if ($AutoCreateIssues) {
                $issueTitle = "Auto-fix failed for $appName - Copilot review needed"
                $issueDesc = ($issues | ForEach-Object { "- **$($_.Title)**: $($_.Description)" }) -join "`n"

                $issueNum = New-GitHubIssue `
                    -Title $issueTitle `
                    -Description $issueDesc `
                    -Repository $GitHubRepo `
                    -Token $GitHubToken `
                    -IssueType "manifest-error" `
                    -TagCopilot

                if (!$issueNum) {
                    Write-Host '[WARN] Could not create Copilot issue, escalating to manual review' -ForegroundColor Yellow
                    # Create escalation issue
                    $issueNum = New-GitHubIssue `
                        -Title "ESCALATION: Manual fix needed for $appName" `
                        -Description $issueDesc `
                        -Repository $GitHubRepo `
                        -Token $GitHubToken `
                        -IssueType "bug" `
                        -TagEscalation
                }
            }

            exit 2
        }

        exit 0
    } else {
        Write-Host '[FAIL] Could not parse checkver output'
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
                    -IssueType "manifest-error" `
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
