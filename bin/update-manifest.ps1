#!/usr/bin/env pwsh
<#
.SYNOPSIS
Update manifest version and hashes from the latest release.

.DESCRIPTION
Automatically updates a manifest with:
1. Latest version from checkver configuration
2. Download URLs for all architectures
3. SHA256 hashes for downloaded files

.PARAMETER ManifestPath
Path to the manifest JSON file to update.

.PARAMETER Update
Switch to perform actual update. Without this, runs in dry-run mode showing what would change.

.PARAMETER Force
Skip confirmation prompts and apply updates immediately.

.EXAMPLE
# Check what would be updated
.\update-manifest.ps1 -ManifestPath bucket\gopher64.json

# Apply updates
.\update-manifest.ps1 -ManifestPath bucket\gopher64.json -Update

# Update without prompts
.\update-manifest.ps1 -ManifestPath bucket\gopher64.json -Update -Force

.OUTPUTS
Updated manifest file (if -Update switch used) or preview of changes (dry-run).

.LINK
https://github.com/borger/scoop-emulators
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [switch]$Update = $false,

    [switch]$Force = $false
)

<#
.SYNOPSIS
Checks for latest version and optionally updates a manifest with autoupdate.

.DESCRIPTION
This script performs the following:
1. Validates the manifest has 'checkver' and 'autoupdate' sections
2. Uses Scoop's checkver to find the latest version
3. Optionally updates the manifest with the latest version
4. Returns the version information found

.PARAMETER ManifestPath
The path to the manifest JSON file to check and optionally update.

.PARAMETER Update
Switch to actually update the manifest. If not specified, only reports the latest version.

.PARAMETER Force
Force update even if the current version matches the latest version found.

.RETURNS
0 if successful
-1 if an error occurs (prints error message to stderr)

.NOTES
Requires Scoop to be installed and available in PATH.
#>

$ErrorActionPreference = 'Stop'

# Load shared release/hash helpers
$lib = Join-Path $PSScriptRoot 'lib-releasehelpers.ps1'
if (Test-Path $lib) { . $lib }

function Get-FormatJsonPath {
    $scoopHome = $env:SCOOP_HOME
    if (-not $scoopHome) {
        try {
            $scoopHome = scoop prefix scoop
        } catch {
            $scoopHome = $null
        }
    }

    if ($scoopHome) {
        $formatJsonPath = Join-Path $scoopHome 'bin\formatjson.ps1'
        if (Test-Path $formatJsonPath) {
            return $formatJsonPath
        }
    }

    return $null
}

function Get-GitHubReleaseAssets {
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$TagName = 'latest'
    )

    $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases/$TagName"
    Write-Verbose ('[INFO] Fetching GitHub release assets from: {0}' -f $apiUrl)

    try {
        $response = Invoke-WebRequest -Uri $apiUrl -ErrorAction Stop
        $releaseInfo = $response.Content | ConvertFrom-Json
        return $releaseInfo.assets
    } catch {
        Write-Verbose ('[WARN] Could not fetch GitHub release assets: {0}' -f $_)
        return $null
    }
}

function Resolve-ManifestUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Version,

        [string]$CommitToken
    )

    $resolvedUrl = $Url.Replace('$version', $Version)
    if ($CommitToken) {
        $resolvedUrl = $resolvedUrl.Replace('$matchCommit', $CommitToken)
    }

    return $resolvedUrl
}

function Update-ManifestUrls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Manifest,

        [Parameter(Mandatory)]
        [string]$Version,

        [string]$CommitToken
    )

    foreach ($architecture in @('64bit', '32bit', 'arm64')) {
        $manifestArchitecture = $Manifest.architecture.$architecture
        $nestedUrl = $Manifest.autoupdate.architecture.$architecture.url
        if ($nestedUrl) {
            if (-not $manifestArchitecture) {
                throw "Autoupdate URL exists for '$architecture', but the manifest has no matching architecture."
            }

            $manifestArchitecture.url = Resolve-ManifestUrl -Url $nestedUrl -Version $Version -CommitToken $CommitToken
        }

        $directUrl = $Manifest.autoupdate.$architecture.url
        if ($directUrl) {
            if (-not $manifestArchitecture) {
                throw "Autoupdate URL exists for '$architecture', but the manifest has no matching architecture."
            }

            $manifestArchitecture.url = Resolve-ManifestUrl -Url $directUrl -Version $Version -CommitToken $CommitToken
        }
    }

    if ($Manifest.autoupdate.url) {
        $Manifest.url = Resolve-ManifestUrl -Url $Manifest.autoupdate.url -Version $Version -CommitToken $CommitToken
    }

    return $Manifest
}

## Use shared Get-ReleaseChecksum from bin/lib-releasehelpers.ps1

try {
    # Check if file exists
    if (!(Test-Path $ManifestPath)) {
        Write-Error "Manifest file not found: $ManifestPath"
        exit -1
    }

    # Convert to absolute path
    $ManifestPath = Convert-Path $ManifestPath

    # Extract app name from filename
    $AppName = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $ManifestPath))
    Write-Verbose "App name: $AppName"

    # Read and parse the manifest
    $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json

    # Check for required sections
    if (!$manifest.checkver) {
        Write-Error "Manifest does not contain 'checkver' section"
        exit -1
    }

    if (!$manifest.autoupdate) {
        Write-Error "Manifest does not contain 'autoupdate' section"
        exit -1
    }

    Write-Verbose '[OK] Manifest has both ''checkver'' and ''autoupdate'' sections'

    $currentVersion = $manifest.version
    Write-Verbose "Current version: $currentVersion"

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

    # Use Scoop's checkver to find the latest version
    Write-Verbose "Checking for latest version..."

    $checkverScript = "$PSScriptRoot/checkver.ps1"

    if (!(Test-Path $checkverScript)) {
        Write-Error "checkver script not found at $checkverScript"
        exit -1
    }

    # Capture checkver output using our wrapper which handles Write-Host properly
    $checkverOutput = & $checkverScript -App $AppName -Dir (Split-Path $ManifestPath) 2>&1 | Out-String

    Write-Verbose "Checkver output: '$checkverOutput'"

    # Parse the output to find the latest version. Support arbitrary tokens (dates, hashes, semantic versions).
    # Prefer the form: "appname: <version> (scoop version is ...)", otherwise take the first non-space token after the colon.
    $latestVersion = $null
    if ($checkverOutput -match "$([regex]::Escape($AppName)):\s*(\S+)\s*\(scoop version") {
        $latestVersion = $matches[1]
    } elseif ($checkverOutput -match "$([regex]::Escape($AppName)):\s*(\S+)") {
        $latestVersion = $matches[1]
    }

    if (-not $latestVersion) {
        Write-Error "Could not parse version from checkver output: $checkverOutput"
        exit -1
    }

    Write-Verbose "Latest version found: $latestVersion"
    Write-Host "Found version: $latestVersion (current: $currentVersion)"

    if ($latestVersion -eq $currentVersion -and !$Force) {
        Write-Host '[OK] Manifest is already up to date'
        exit 0
    }

    if ($Update) {
        Write-Verbose "Updating manifest..."

        # Read the manifest JSON and update the version field
        $manifestContent = Get-Content -Path $ManifestPath -Raw
        $manifestJson = ConvertFrom-Json $manifestContent

        # Store old version for reporting
        $oldVersion = $manifestJson.version

        # Update version
        $manifestJson.version = $latestVersion

        # Derive commit-only token if version contains a trailing commit SHA
        $commitToken = $null
        if ($latestVersion -match '([a-f0-9]{7,40})$') { $commitToken = $matches[1] }

        # Update generic and all supported architecture URLs.
        Update-ManifestUrls -Manifest $manifestJson -Version $latestVersion -CommitToken $commitToken | Out-Null

        # Now we need to get the hashes for the updated URLs
        Write-Verbose "Getting hashes for updated URLs..."

        # Get GitHub release assets if available (for checksum files)
        $releaseAssets = $null
        $hasChecksumFiles = $false
        if ($gitHubOwner -and $gitHubRepo) {
            $releaseAssets = Get-GitHubReleaseAssets -Owner $gitHubOwner -Repo $gitHubRepo -TagName "v$latestVersion"
            if (-not $releaseAssets) {
                # Try without 'v' prefix
                $releaseAssets = Get-GitHubReleaseAssets -Owner $gitHubOwner -Repo $gitHubRepo -TagName $latestVersion
            }
            # Check if checksum files exist
            if ($releaseAssets) {
                $checksumFiles = @($releaseAssets | Where-Object { $_.name -like '*.sha256' -or $_.name -like '*.sha256sum' -or $_.name -like '*.checksum' })
                $hasChecksumFiles = $checksumFiles.Count -gt 0
            }
        }

        # Use Get-RemoteFileHash from bin/lib-releasehelpers.ps1
        foreach ($architectureEntry in $manifestJson.architecture.PSObject.Properties) {
            $architecture = $architectureEntry.Name
            $url = $architectureEntry.Value.url
            if (-not $url) { continue }

            Write-Verbose ('Getting hash for {0}: {1}' -f $architecture, $url)
            $fileName = Split-Path -Leaf $url

            if ($hasChecksumFiles -and $releaseAssets) {
                $manifestJson.architecture.$architecture.hash = [ordered]@{
                    'url'      = "https://api.github.com/repos/$gitHubOwner/$gitHubRepo/releases/latest"
                    'jsonpath' = ('$.assets[?(@.name == ''{0}'')].digest' -f $fileName)
                }
                Write-Verbose ('[OK] {0} hash configured for API lookup: {1}' -f $architecture, $fileName)
                continue
            }

            $hash = $null
            if ($releaseAssets) {
                $hash = Get-ReleaseChecksum -Assets $releaseAssets -TargetAssetName $fileName
            }
            if (-not $hash) {
                $hash = Get-RemoteFileHash -Url $url
            }
            if (-not $hash) {
                throw "Could not calculate a SHA256 hash for $architecture URL: $url"
            }

            $manifestJson.architecture.$architecture.hash = $hash
            Write-Verbose ('[OK] {0} hash updated: {1}' -f $architecture, $hash)
        }

        if ($manifestJson.url) {
            $urlGeneric = $manifestJson.url
            Write-Verbose "Getting hash for generic URL: $urlGeneric"

            # Try to get checksum from GitHub release first
            $hashGeneric = $null
            if ($releaseAssets) {
                $fileName = Split-Path -Leaf $urlGeneric
                $hashGeneric = Get-ReleaseChecksum -Assets $releaseAssets -TargetAssetName $fileName
            }

            # Fall back to downloading and calculating if no checksum found
            if (-not $hashGeneric) {
                $hashGeneric = Get-RemoteFileHash -Url $urlGeneric
            }

            if (-not $hashGeneric) {
                throw "Could not calculate a SHA256 hash for generic URL: $urlGeneric"
            }

            $manifestJson.hash = $hashGeneric
            Write-Verbose ('[OK] Generic hash updated: {0}' -f $hashGeneric)
        }

        # Convert back to JSON and save with proper formatting
        $updatedJson = $manifestJson | ConvertTo-Json -Depth 10

        # Write JSON with UTF-8 encoding without BOM
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)

        # Format the JSON properly
        $bucketDir = Split-Path $ManifestPath -Parent
        $appName = [System.IO.Path]::GetFileNameWithoutExtension($ManifestPath)
        $formatJsonPath = Get-FormatJsonPath
        if ($formatJsonPath) {
            & $formatJsonPath -Dir $bucketDir -App $appName
        } else {
            Write-Verbose 'formatjson.ps1 not found; leaving JSON as-is'
        }

        Write-Host ('[OK] Manifest version updated from {0} to {1}' -f $oldVersion, $latestVersion)
        Write-Host '[OK] Architecture URLs and hashes updated'

        exit 0
    } else {
        Write-Host '[INFO] Run with -Update switch to apply the update'
        exit 0
    }
} catch {
    Write-Error "Error checking manifest version: $($_.Exception.Message)"
    exit -1
}
