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
    [string]$IssueType,
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
function Validate-FixIntegrity {
  param(
    [string]$ManifestPath,
    [string]$AppName
  )

  $updateScript = "$PSScriptRoot/update-manifest.ps1"
  if (-not (Test-Path $updateScript)) {
    Write-Host "  [WARN] update-manifest.ps1 not available for validation" -ForegroundColor Yellow
    return $false
  }

  Write-Host "  [INFO] Running update-manifest.ps1 for $AppName" -ForegroundColor Cyan
  $updateOutput = & $updateScript -ManifestPath $ManifestPath -Update -Force 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  [WARN] update-manifest failed for $AppName" -ForegroundColor Yellow
    Add-Issue -Title "Validation failed" -Description "update-manifest.ps1 failed:\n$updateOutput" -Severity "error"
    return $false
  }

  if (-not (Get-Command 'scoop' -ErrorAction SilentlyContinue)) {
    Write-Host "  [WARN] scoop is not installed; skipping installation verification" -ForegroundColor Yellow
    return $true
  }

  Write-Host "  [INFO] Attempting 'scoop install $AppName' to verify the manifest" -ForegroundColor Cyan
  $installOutput = ''
  try {
    $installOutput = & scoop install $AppName 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "scoop install failed" }
  } catch {
    Write-Host "  [WARN] scoop install failed for $AppName" -ForegroundColor Yellow
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
    # ISO date
    '(?<!\S)(?<ver>\d{4}-\d{2}-\d{2})(?!\S)',
    # Git SHA (7-40 hex chars)
    '(?<!\S)(?<ver>[a-f0-9]{7,40})(?!\S)',
    # Semantic-like (requires at least one dot)
    '(?<!\S)(?<ver>\d+(?:\.\d+)+[\w\.-_]*)',
    # Long numeric (2+ digits)
    '(?<!\S)(?<ver>\d{2,})(?!\S)',
    # Fallback: single digit (last resort)
    '(?<!\S)(?<ver>\d)(?!\S)'
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
          if ($Manifest.architecture.'64bit' -and $Manifest.architecture.'64bit'.url -and $Manifest.architecture.'64bit'.url -match [regex]::Escape($c)) { return $candidate }
          if ($Manifest.architecture.'32bit' -and $Manifest.architecture.'32bit'.url -and $Manifest.architecture.'32bit'.url -match [regex]::Escape($c)) { return $candidate }
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
          if ($Manifest.architecture.'64bit' -and $Manifest.architecture.'64bit'.url -and $Manifest.architecture.'64bit'.url -match [regex]::Escape($candidate)) { return $candidate }
          if ($Manifest.architecture.'32bit' -and $Manifest.architecture.'32bit'.url -and $Manifest.architecture.'32bit'.url -match [regex]::Escape($candidate)) { return $candidate }
          if ($Manifest.architecture.'64bit' -and $Manifest.architecture.'64bit'.url -and $Manifest.architecture.'64bit'.url -match [regex]::Escape($withSuffix)) { return $withSuffix }
          if ($Manifest.architecture.'32bit' -and $Manifest.architecture.'32bit'.url -and $Manifest.architecture.'32bit'.url -match [regex]::Escape($withSuffix)) { return $withSuffix }
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
          if ($Manifest.architecture.'64bit' -and $Manifest.architecture.'64bit'.url -and $Manifest.architecture.'64bit'.url -match [regex]::Escape($c)) { return $candidate }
          if ($Manifest.architecture.'32bit' -and $Manifest.architecture.'32bit'.url -and $Manifest.architecture.'32bit'.url -match [regex]::Escape($c)) { return $candidate }
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
  param([string]$Repo, [string]$Version, [string]$Platform = "github")

  $assets = @()

  if ($Platform -eq "github") {
    try {
      $apiUrl = "https://api.github.com/repos/$repo/releases/tags/$Version"
      $release = Invoke-RestMethod -Uri $apiUrl -ErrorAction SilentlyContinue -UseBasicParsing
      return $release.assets
    } catch {
      Write-Host "  [WARN] GitHub API error: $_" -ForegroundColor Yellow
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

  # If manifest explicitly uses the 'nightly' channel, do not run checkver — maintain dates/labels exactly
  $skipCheckver = $false
  if ($manifest.PSObject.Properties.Match('version').Count -and ($manifest.version -eq 'nightly')) {
    Write-Host "[INFO] Manifest uses 'nightly' channel; skipping checkver detection" -ForegroundColor Cyan
    $skipCheckver = $true
  }

  # Ensure checkver output variable exists
  $checkverOutput = ""

  # Extract Repository Info (GitHub/GitLab/Gitea)
  $gitHubOwner = $null; $gitHubRepo = $null
  $gitLabRepo = $null
  $giteaBase = $null; $giteaRepo = $null

  if ($manifest.checkver.github) {
    if ($manifest.checkver.github -match 'github\.com/([^/]+)/([^/]+)/?$') {
      $gitHubOwner = $matches[1]; $gitHubRepo = $matches[2]
      Write-Verbose "GitHub repo detected: $gitHubOwner/$gitHubRepo"
    }
  } elseif ($manifest.checkver.gitlab) {
    if ($manifest.checkver.gitlab -match 'gitlab\.com/([^/]+)/([^/]+)/?$') {
      $gitLabRepo = "$($matches[1])/$($matches[2])"
      Write-Verbose "GitLab repo detected: $gitLabRepo"
    }
  } elseif ($manifest.checkver.gitea) {
    if ($manifest.checkver.gitea -match '(https?://[^/]+)/([^/]+/[^/]+)') {
      $giteaBase = $matches[1]
      $giteaRepo = $matches[2]
      Write-Verbose "Gitea repo detected: $giteaRepo on $giteaBase"
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

  $needsFix = $false
  $downloadsOk = $false
  $downloadStatus = Test-ManifestDownloadAccessibility -Manifest $manifest
  if ($downloadStatus.Success) {
    Write-Host "[INFO] Existing release assets are reachable" -ForegroundColor Cyan
    $downloadsOk = $true
  } else {
    Write-Host "[WARN] One or more release URLs are not accessible; attempting to repair the manifest" -ForegroundColor Yellow
    foreach ($failure in $downloadStatus.Failures) {
      Write-Host "  [INFO] Could not reach $($failure.Type) URL: $($failure.Url)" -ForegroundColor Yellow
      if ($failure.Error) { Write-Host "    [INFO] Error: $($failure.Error)" -ForegroundColor Yellow }
    }
    $needsFix = $true
  }

  # Try to get latest version from checkver
  $checkverScript = "$PSScriptRoot/checkver.ps1"

  if (!(Test-Path $checkverScript)) {
    Write-Host "[WARN] checkver script not found, cannot validate updates"
    exit 1
  }

  $latestVersion = $null

  # Try to get latest version from APIs first (Priority)
  if ($gitHubOwner -and $gitHubRepo) {
    Write-Host "Checking GitHub Releases for $gitHubOwner/$gitHubRepo..."
    try {
      $apiUrl = "https://api.github.com/repos/$gitHubOwner/$gitHubRepo/releases/latest"
      $latestRelease = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop

      if ($latestRelease) {
        if ($latestRelease.tag_name) {
          $latestVersion = $latestRelease.tag_name -replace '^v', '' -replace '^\.', ''
        } elseif ($latestRelease.name) {
          $latestVersion = $latestRelease.name
        }

        if ($latestVersion) {
          Write-Host "  [INFO] Found version from GitHub Releases: $latestVersion" -ForegroundColor Cyan
        }
      }
    } catch {
      Write-Host "  [WARN] Failed to check GitHub Releases: $_" -ForegroundColor Yellow
    }
  } elseif ($gitLabRepo) {
    Write-Host "Checking GitLab Releases for $gitLabRepo..."
    try {
      $id = [Uri]::EscapeDataString($gitLabRepo)
      $apiUrl = "https://gitlab.com/api/v4/projects/$id/releases"
      $releases = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
      if ($releases -and $releases.Count -gt 0) {
        $latestVersion = $releases[0].tag_name -replace '^v', '' -replace '^\.', ''
        Write-Host "  [INFO] Found version from GitLab Releases: $latestVersion" -ForegroundColor Cyan
      }
    } catch {
      Write-Host "  [WARN] Failed to check GitLab Releases: $_" -ForegroundColor Yellow
    }
  } elseif ($giteaBase -and $giteaRepo) {
    Write-Host "Checking Gitea Releases for $giteaRepo..."
    try {
      $apiUrl = "$giteaBase/api/v1/repos/$giteaRepo/releases?limit=1"
      $releases = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop
      if ($releases -and $releases.Count -gt 0) {
        $latestVersion = $releases[0].tag_name -replace '^v', '' -replace '^\.', ''
        Write-Host "  [INFO] Found version from Gitea Releases: $latestVersion" -ForegroundColor Cyan
      }
    } catch {
      Write-Host "  [WARN] Failed to check Gitea Releases: $_" -ForegroundColor Yellow
    }
  }

  if (-not $latestVersion) {
    if (-not $skipCheckver) {
      Write-Host "Running checkver..."
      $checkverOutput = & $checkverScript -App $appName -Dir $BucketPath 2>&1 | Out-String
    } else {
      Write-Host "[INFO] Skipping checkver because manifest is 'nightly'" -ForegroundColor Cyan
    }
  }

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

            $latestVersion = $latestRelease.tag_name -replace '^v', '' -replace '^\.', ''
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
    $latestVersion = Get-VersionFromCheckverOutput -Output $checkverOutput -AppName $appName
    if ($latestVersion) {
      Write-Host "  [INFO] Using version from checkver: $latestVersion" -ForegroundColor Gray
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
      Repair-VersionPattern -RepoPath $repoPath -Platform $repoPlatform | Out-Null

      # Get latest release
      try {
        if ($repoPlatform -eq "github") {
          $apiUrl = "https://api.github.com/repos/$repoPath/releases/latest"
          $latestRelease = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing -ErrorAction Stop

          if ($latestRelease) {
            if ($latestRelease.tag_name) {
              $latestVersion = $latestRelease.tag_name -replace '^v', '' -replace '^\.', ''
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
            if ($rel.tag_name) { $latestVersion = $rel.tag_name -replace '^v', '' -replace '^\.', '' ; Write-Host "  [OK] Using latest release tag: $latestVersion" -ForegroundColor Green }
            elseif ($rel.name) { $latestVersion = $rel.name; Write-Host "  [OK] Using latest release name: $latestVersion" -ForegroundColor Green }
          }
        }
      } catch {
        Write-Host "  [WARN] Could not fetch latest release tag: $_" -ForegroundColor Yellow
      }
    }

    # Normalize latestVersion into canonical form (handles tags like v.0.12.5, .0.12.5, mame0282)
    try { $latestVersion = ConvertTo-CanonicalVersion -RawVersion $latestVersion -Manifest $manifest -AppName $appName } catch { }

    # Basic sanity check: ensure the extracted version looks like a version token (contains digits, date, or short SHA)
    if (-not (Test-VersionLooksValid -v $latestVersion)) {
      Write-Host "[WARN] Extracted version looks invalid: '$latestVersion' — aborting auto-fix to avoid corrupting manifest" -ForegroundColor Yellow
      Add-Issue -Title "Invalid version extracted" -Description "Extracted version '$latestVersion' for $appName does not resemble a valid version token" -Severity "error"
      exit 2
    }

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

      # If the current version is in a non-canonical form (e.g., 'mame0282'), try to canonicalize using checkver
      if ($currentVersion -match '^mame\d+' -or $currentVersion -match '^\.' -or ($currentVersion -notmatch '\d+\.\d+')) {
        Write-Host "[INFO] Current version format looks non-canonical: $currentVersion. Attempting canonicalization via checkver..." -ForegroundColor Cyan
        try {
          if (Test-Path $checkverScript) {
            $checkverOutput = & $checkverScript -App $appName -Dir $BucketPath 2>&1 | Out-String
            $detectedVersion = Get-VersionFromCheckverOutput -Output $checkverOutput -AppName $appName

            if ($detectedVersion) {
              $detectedVersion = $detectedVersion -replace '^v', ''
              # Normalize MAME style tags if present
              if ($detectedVersion -match '^mame(?<digits>\d+)(?<suffix>[a-zA-Z]*)$') {
                $d = $matches['digits']
                if ($d.Length -ge 4) { $detectedVersion = $d.Substring(0, 1) + '.' + $d.Substring(1) } else { if ($d.Length -gt 3) { $detectedVersion = $d.Substring(0, $d.Length - 3) + '.' + $d.Substring($d.Length - 3) } else { $detectedVersion = $d } }
                if ($matches['suffix']) { $detectedVersion += $matches['suffix'] }
              }

              if ($detectedVersion -ne $manifest.version) {
                Write-Host "  [OK] Canonical version from checkver: $detectedVersion (was $($manifest.version))" -ForegroundColor Green
                $manifest.version = ([string]$detectedVersion) -replace '^\.+', ''
                $sortedManifest = Get-OrderedManifest -Manifest $manifest
                $updatedJson = $sortedManifest | ConvertTo-Json -Depth 10
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)
                Write-Host "[OK] Manifest canonicalized and saved" -ForegroundColor Green
                exit 0
              }
            }
          }
        } catch {
          Write-Host "  [WARN] checkver canonicalization failed: $_" -ForegroundColor Yellow
        }
      }

      Write-Host "[OK] Manifest already up-to-date ($currentVersion)"
      exit 0
    }

    # If downloads were reachable and we couldn't detect any newer version, avoid making changes
    if ($downloadsOk -and -not $latestVersion) {
      Write-Host "[OK] Existing release assets reachable and no newer version detected; nothing to fix" -ForegroundColor Green
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
      $urlChanged = $newUrl -ne $oldUrl
      $urlValid = $false

      Write-Host "Checking $arch URL..."

      # If URL structure suggests it depends on version, try new URL first
      if ($urlChanged) {
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
          Write-Host "  [INFO] Version-substituted URL not accessible"
        }
      }

      # If new URL failed or wasn't tried, check old URL
      if (!$urlValid) {
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
      }

      if (!$urlValid) {
        Write-Host "  [FAIL] URL is not accessible - attempting to fix"
      }

      # If URL is not valid, try version-substituted URL first (already tried above, but logic flow continues)
      # We can skip this block as we already tried substitution above

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
          $assets = Get-ReleaseAsset -Repo $repoPath -Version $latestVersion -Platform $repoPlatform

          # If release not found with exact version, attempt pattern matching
          if (!$assets -or $assets.Count -eq 0) {
            Write-Host "  [WARN] Release tag '$latestVersion' not found, attempting pattern match..." -ForegroundColor Yellow

            $release = Find-ReleaseByPatternMatch -RepoPath $repoPath -TargetVersion $latestVersion -Platform $repoPlatform

            if ($release) {
              # Update latestVersion to the found release
              if ($release.tag_name) {
                $latestVersion = $release.tag_name -replace '^v', '' -replace '^\.', ''  # Strip 'v' prefix and leading dot if present
              } elseif ($release.name) {
                $latestVersion = $release.name
              }

              Write-Host "  [OK] Updated version to: $latestVersion" -ForegroundColor Green

              # Try to get assets from the matched release
              $assets = Get-ReleaseAsset -Repo $repoPath -Version $release.tag_name -Platform $repoPlatform

              # If still no assets but we have release info, try alternative version formats
              if (!$assets -or $assets.Count -eq 0) {
                # Try version without 'v' prefix
                $versionAlt = $release.tag_name -replace '^v', '' -replace '^\.', ''
                if ($versionAlt -ne $release.tag_name) {
                  $assets = Get-ReleaseAsset -Repo $repoPath -Version $versionAlt -Platform $repoPlatform
                }
                # Try version with 'v' prefix
                if ((!$assets -or $assets.Count -eq 0) -and $release.tag_name -notmatch '^v') {
                  $assets = Get-ReleaseAsset -Repo $repoPath -Version "v$($release.tag_name)" -Platform $repoPlatform
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
    if ($manifest.architecture.'64bit'.url) { $hashTargets += @{ Name = '64bit'; Obj = $manifest.architecture.'64bit'; Url = $manifest.architecture.'64bit'.url } }
    if ($manifest.architecture.'32bit'.url) { $hashTargets += @{ Name = '32bit'; Obj = $manifest.architecture.'32bit'; Url = $manifest.architecture.'32bit'.url } }

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
          "jsonpath" = "\$.assets[?(@.name == '$fileName')].digest"
        }

        if ($targetObj.PSObject.Properties.Match('hash').Count) {
          $targetObj.hash = $hashValue
        } else {
          $targetObj | Add-Member -MemberType NoteProperty -Name "hash" -Value $hashValue
          $forceRewrite = $true
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
          if ($targetObj.PSObject.Properties.Match('hash').Count) {
            $targetObj.hash = $newHash
          } else {
            $targetObj | Add-Member -MemberType NoteProperty -Name "hash" -Value $newHash
            $forceRewrite = $true
            Write-Host "  [INFO] Added missing hash field, will rewrite manifest" -ForegroundColor Gray
          }
          Write-Host "  [OK] $targetName hash updated"
        } else {
          if ($targetName -ne 'Generic') {
            Write-Host "  [WARN] Could not get $targetName hash"
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
      Write-Host "  [INFO] Rewriting manifest to include new fields..." -ForegroundColor Cyan

      # Sort keys before saving
      $sortedManifest = Get-OrderedManifest -Manifest $manifest
      $updatedJson = $sortedManifest | ConvertTo-Json -Depth 10

      $utf8NoBom = New-Object System.Text.UTF8Encoding $false
      [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)

      # Format the JSON to match Scoop standards
      $formatScript = "$PSScriptRoot/formatjson.ps1"
      if (Test-Path $formatScript) {
        Write-Host "  [INFO] Formatting manifest..." -ForegroundColor Cyan
        try {
          $output = & $formatScript -App $appName 2>&1
          if ($LASTEXITCODE -ne 0) {
            Write-Host "  [WARN] Formatting failed: $output" -ForegroundColor Yellow
          }
        } catch {
          Write-Host "  [WARN] Formatting script error: $_" -ForegroundColor Yellow
        }
      }

      # After saving, run checkver to ensure version is canonical according to checkver
      try {
        if (Test-Path $checkverScript) {
          Write-Host "  [INFO] Running checkver to determine canonical version..." -ForegroundColor Cyan
          $checkverOutput = & $checkverScript -App $appName -Dir $BucketPath 2>&1 | Out-String

          # Try to extract version from checkver output
          $detectedVersion = Get-VersionFromCheckverOutput -Output $checkverOutput -AppName $appName

          if ($detectedVersion) {
            $detectedVersion = $detectedVersion -replace '^v', ''

            # Validate that detected version appears in updated URLs (to avoid spurious small numbers)
            $versionValid = $false
            if ($manifest.url -and ($manifest.url -match [regex]::Escape($detectedVersion) -or $manifest.url -match [regex]::Escape("v$detectedVersion"))) { $versionValid = $true }
            if (-not $versionValid -and $manifest.architecture) {
              if ($manifest.architecture.'64bit' -and $manifest.architecture.'64bit'.url -and ($manifest.architecture.'64bit'.url -match [regex]::Escape($detectedVersion))) { $versionValid = $true }
              if ($manifest.architecture.'32bit' -and $manifest.architecture.'32bit'.url -and ($manifest.architecture.'32bit'.url -match [regex]::Escape($detectedVersion))) { $versionValid = $true }
            }

            if (-not $versionValid) {
              # Fallback: try to extract version from URL patterns (look for v<digits> or _v<digits>)
              $found = $null
              if ($manifest.url -and ($manifest.url -match 'v\.\?(?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] }
              if (-not $found -and $manifest.architecture.'64bit' -and $manifest.architecture.'64bit'.url -and ($manifest.architecture.'64bit'.url -match 'v\.\?(?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] }
              if (-not $found -and $manifest.architecture.'32bit' -and $manifest.architecture.'32bit'.url -and ($manifest.architecture.'32bit'.url -match 'v\.\?(?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] }

              if ($found) {
                Write-Host "  [WARN] Checkver returned '$detectedVersion' which doesn't match URLs; using version parsed from URL: $found" -ForegroundColor Yellow
                $detectedVersion = $found
                $versionValid = $true
              } else {
                Write-Host "  [WARN] checkver returned '$detectedVersion' which doesn't match updated URLs; ignoring" -ForegroundColor Yellow
                $versionValid = $false
              }
            }

            if ($versionValid -and $detectedVersion -ne $manifest.version) {
              if ($appName -and $appName -match '^duckstation') {
                Write-Host "  [INFO] Detected canonical version but skipping canonicalization for $appName" -ForegroundColor Yellow
              } else {
                Write-Host "  [OK] Using canonical version: $detectedVersion (was $($manifest.version))" -ForegroundColor Green
                $manifest.version = ([string]$detectedVersion) -replace '^\.+', ''

                # Rewrite manifest with updated version
                $sortedManifest = Get-OrderedManifest -Manifest $manifest
                $updatedJson = $sortedManifest | ConvertTo-Json -Depth 10
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)
              }
            }
          } else {
            Write-Host "  [WARN] checkver did not return a parseable version" -ForegroundColor Yellow
          }
        }
      } catch {
        Write-Host "  [WARN] Running checkver failed: $_" -ForegroundColor Yellow
      }

      if ($needsFix) {
        if (-not (Validate-FixIntegrity -ManifestPath $ManifestPath -AppName $appName)) {
          Write-Host "[FAIL] Validation failed; aborting auto-fix" -ForegroundColor Red
          exit 2
        }
      }

      Write-Host "[OK] Manifest auto-fixed and saved" -ForegroundColor Green
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
        Write-Host "  [OK] Updated quoted version in manifest text" -ForegroundColor Green
      } elseif ($updatedContent -match $unquotedPattern) {
        # Handle numeric/unquoted version
        $updatedContent = $updatedContent -replace $unquotedPattern, "`"version`": `"$latestVersion`""
        Write-Host "  [OK] Updated unquoted numeric version in manifest text (now quoted)" -ForegroundColor Green
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

    # After targeted text replacements, run checkver to canonicalize version
    try {
      if (Test-Path $checkverScript) {
        Write-Host "  [INFO] Running checkver to determine canonical version..." -ForegroundColor Cyan
        $checkverOutput = & $checkverScript -App $appName -Dir $BucketPath 2>&1 | Out-String

        $detectedVersion = Get-VersionFromCheckverOutput -Output $checkverOutput -AppName $appName

        if ($detectedVersion) {
          $detectedVersion = $detectedVersion -replace '^v', ''

          # Normalize MAME tags like 'mame0282' -> '0.282'
          if ($detectedVersion -match '^mame(?<digits>\d+)(?<suffix>[a-zA-Z]*)$') {
            $d = $matches['digits']
            if ($d.Length -ge 4) {
              $detectedVersion = $d.Substring(0, 1) + '.' + $d.Substring(1)
            } else {
              if ($d.Length -gt 3) {
                $detectedVersion = $d.Substring(0, $d.Length - 3) + '.' + $d.Substring($d.Length - 3)
              } else {
                $detectedVersion = $d
              }
            }
            if ($matches['suffix']) { $detectedVersion += $matches['suffix'] }
            Write-Host "  [INFO] Normalized MAME tag to canonical version: $detectedVersion" -ForegroundColor Cyan
          }

          # Normalize MAME tags like 'mame0282' -> '0.282'
          if ($detectedVersion -match '^mame(?<digits>\d+)(?<suffix>[a-zA-Z]*)$') {
            $d = $matches['digits']
            if ($d.Length -ge 4) {
              $detectedVersion = $d.Substring(0, 1) + '.' + $d.Substring(1)
            } else {
              if ($d.Length -gt 3) {
                $detectedVersion = $d.Substring(0, $d.Length - 3) + '.' + $d.Substring($d.Length - 3)
              } else {
                $detectedVersion = $d
              }
            }
            if ($matches['suffix']) { $detectedVersion += $matches['suffix'] }
            Write-Host "  [INFO] Normalized MAME tag to canonical version: $detectedVersion" -ForegroundColor Cyan
          }

          # Validate that detected version appears in updated URLs (to avoid spurious small numbers)
          $versionValid = $false
          if ($manifest.url -and ($manifest.url -match [regex]::Escape($detectedVersion) -or $manifest.url -match [regex]::Escape("v$detectedVersion"))) { $versionValid = $true }
          if (-not $versionValid -and $manifest.architecture) {
            if ($manifest.architecture.'64bit' -and $manifest.architecture.'64bit'.url -and ($manifest.architecture.'64bit'.url -match [regex]::Escape($detectedVersion))) { $versionValid = $true }
            if ($manifest.architecture.'32bit' -and $manifest.architecture.'32bit'.url -and ($manifest.architecture.'32bit'.url -match [regex]::Escape($detectedVersion))) { $versionValid = $true }
          }

          if (-not $versionValid) {
            # Fallback: try to extract version from URL patterns (look for v<digits> or _v<digits>)
            $found = $null
            if ($manifest.url -and ($manifest.url -match 'v\.? (?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] }
            if (-not $found -and $manifest.architecture.'64bit' -and $manifest.architecture.'64bit'.url -and ($manifest.architecture.'64bit'.url -match 'v\.? (?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] }
            if (-not $found -and $manifest.architecture.'32bit' -and $manifest.architecture.'32bit'.url -and ($manifest.architecture.'32bit'.url -match 'v\.? (?<ver>\d[\d\.\-_]*)')) { $found = $matches['ver'] }

            if ($found) {
              Write-Host "  [WARN] Checkver returned '$detectedVersion' which doesn't match URLs; using version parsed from URL: $found" -ForegroundColor Yellow
              $detectedVersion = $found
              $versionValid = $true
            } else {
              Write-Host "  [WARN] checkver returned '$detectedVersion' which doesn't match updated URLs; ignoring" -ForegroundColor Yellow
              $versionValid = $false
            }
          }

          if ($versionValid -and $detectedVersion -ne $manifest.version) {
            if ($appName -and $appName -match '^duckstation') {
              Write-Host "  [INFO] Detected canonical version but skipping canonicalization for $appName" -ForegroundColor Yellow
            } else {
              Write-Host "  [OK] Using canonical version: $detectedVersion (was $($manifest.version))" -ForegroundColor Green
              $manifest.version = ([string]$detectedVersion) -replace '^\.+', ''

              # Rewrite file to ensure version is quoted and consistent
              $sortedManifest = Get-OrderedManifest -Manifest $manifest
              $updatedJson = $sortedManifest | ConvertTo-Json -Depth 10
              $utf8NoBom = New-Object System.Text.UTF8Encoding $false
              [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)
            }
          }
        } else {
          Write-Host "  [WARN] checkver did not return a parseable version" -ForegroundColor Yellow
        }
      }
    } catch {
      Write-Host "  [WARN] Running checkver failed: $_" -ForegroundColor Yellow
    }

    if ($needsFix) {
      if (-not (Validate-FixIntegrity -ManifestPath $ManifestPath -AppName $appName)) {
        Write-Host "[FAIL] Validation failed; aborting auto-fix" -ForegroundColor Red
        exit 2
      }
    }

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
          -IssueType "manifest-error" `
          -TagCopilot

        if (!$issueNum) {
          Write-Host "[WARN] Could not create Copilot issue, escalating to manual review" -ForegroundColor Yellow
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
