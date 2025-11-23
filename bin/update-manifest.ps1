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

function Get-GitHubReleaseAssets {
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$TagName = 'latest'
    )

    $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases/$TagName"
    Write-Verbose "[INFO] Fetching GitHub release assets from: $apiUrl"

    try {
        $response = Invoke-WebRequest -Uri $apiUrl -ErrorAction Stop
        $releaseInfo = $response.Content | ConvertFrom-Json
        return $releaseInfo.assets
    } catch {
        Write-Verbose "[WARN] Could not fetch GitHub release assets: $_"
        return $null
    }
}

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
            Invoke-WebRequest -Uri $checksumAsset.browser_download_url -OutFile $tempFile -ErrorAction Stop

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

    Write-Verbose "[OK] Manifest has both 'checkver' and 'autoupdate' sections"

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
        Write-Host "[OK] Manifest is already up to date"
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

        # Process autoupdate to update URLs with the new version
        if ($manifestJson.autoupdate.architecture.'64bit'.url) {
            Write-Verbose "Updating 64bit URL..."
            $newUrl64 = $manifestJson.autoupdate.architecture.'64bit'.url -replace '\$version', $latestVersion
            if ($commitToken) { $newUrl64 = $newUrl64 -replace '\$matchCommit', $commitToken }
            $manifestJson.architecture.'64bit'.url = $newUrl64
        }

        if ($manifestJson.autoupdate.architecture.'32bit'.url) {
            Write-Verbose "Updating 32bit URL..."
            $newUrl32 = $manifestJson.autoupdate.architecture.'32bit'.url -replace '\$version', $latestVersion
            if ($commitToken) { $newUrl32 = $newUrl32 -replace '\$matchCommit', $commitToken }
            $manifestJson.architecture.'32bit'.url = $newUrl32
        }

        if ($manifestJson.autoupdate.'64bit'.url) {
            Write-Verbose "Updating 64bit URL (direct)..."
            $newUrl64 = $manifestJson.autoupdate.'64bit'.url -replace '\$version', $latestVersion
            if ($commitToken) { $newUrl64 = $newUrl64 -replace '\$matchCommit', $commitToken }
            $manifestJson.architecture.'64bit'.url = $newUrl64
        }

        if ($manifestJson.autoupdate.'32bit'.url) {
            Write-Verbose "Updating 32bit URL (direct)..."
            $newUrl32 = $manifestJson.autoupdate.'32bit'.url -replace '\$version', $latestVersion
            if ($commitToken) { $newUrl32 = $newUrl32 -replace '\$matchCommit', $commitToken }
            $manifestJson.architecture.'32bit'.url = $newUrl32
        }

        if ($manifestJson.autoupdate.url) {
            Write-Verbose "Updating generic URL..."
            $newUrl = $manifestJson.autoupdate.url -replace '\$version', $latestVersion
            if ($commitToken) { $newUrl = $newUrl -replace '\$matchCommit', $commitToken }
            $manifestJson.url = $newUrl
        }

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

        # Function to download and hash a file
        function Get-RemoteFileHash {
            param([string]$Url, [string]$Algorithm = "SHA256")

            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                Write-Verbose "Downloading: $Url"
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest -Uri $Url -OutFile $tempFile -ErrorAction Stop | Out-Null

                $hash = (Get-FileHash -Path $tempFile -Algorithm $Algorithm).Hash
                return $hash
            } catch {
                Write-Warning "Failed to download/hash $Url : $($_.Exception.Message)"
                return $null
            } finally {
                if (Test-Path $tempFile) {
                    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if ($manifestJson.architecture.'64bit'.url) {
            $url64 = $manifestJson.architecture.'64bit'.url
            Write-Verbose "Getting hash for 64bit: $url64"

            # If checksum files exist in release, use API-based hash lookup
            if ($hasChecksumFiles -and $releaseAssets) {
                $fileName = Split-Path -Leaf $url64
                $manifestJson.architecture.'64bit'.hash = [ordered]@{
                    "url"      = "https://api.github.com/repos/$gitHubOwner/$gitHubRepo/releases/latest"
                    "jsonpath" = "\$.assets[?(@.name == '$fileName')].digest"
                }
                Write-Verbose "[OK] 64bit hash configured for API lookup: $fileName"
            } else {
                # Fall back to static hash
                # Try to get checksum from GitHub release first
                $hash64 = $null
                if ($releaseAssets) {
                    $fileName = Split-Path -Leaf $url64
                    $hash64 = Get-ReleaseChecksum -Assets $releaseAssets -TargetAssetName $fileName
                }

                # Fall back to downloading and calculating if no checksum found
                if (-not $hash64) {
                    $hash64 = Get-RemoteFileHash -Url $url64
                }

                if ($hash64) {
                    $manifestJson.architecture.'64bit'.hash = $hash64
                    Write-Verbose "[OK] 64bit hash updated: $hash64"
                }
            }
        }

        if ($manifestJson.architecture.'32bit'.url) {
            $url32 = $manifestJson.architecture.'32bit'.url
            Write-Verbose "Getting hash for 32bit: $url32"

            # If checksum files exist in release, use API-based hash lookup
            if ($hasChecksumFiles -and $releaseAssets) {
                $fileName = Split-Path -Leaf $url32
                $manifestJson.architecture.'32bit'.hash = [ordered]@{
                    "url"      = "https://api.github.com/repos/$gitHubOwner/$gitHubRepo/releases/latest"
                    "jsonpath" = "\$.assets[?(@.name == '$fileName')].digest"
                }
                Write-Verbose "[OK] 32bit hash configured for API lookup: $fileName"
            } else {
                # Fall back to static hash
                # Try to get checksum from GitHub release first
                $hash32 = $null
                if ($releaseAssets) {
                    $fileName = Split-Path -Leaf $url32
                    $hash32 = Get-ReleaseChecksum -Assets $releaseAssets -TargetAssetName $fileName
                }

                # Fall back to downloading and calculating if no checksum found
                if (-not $hash32) {
                    $hash32 = Get-RemoteFileHash -Url $url32
                }

                if ($hash32) {
                    $manifestJson.architecture.'32bit'.hash = $hash32
                    Write-Verbose "[OK] 32bit hash updated: $hash32"
                }
            }
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

            if ($hashGeneric) {
                $manifestJson.hash = $hashGeneric
                Write-Verbose "[OK] Generic hash updated: $hashGeneric"
            }
        }

        # Convert back to JSON and save with proper formatting
        $updatedJson = $manifestJson | ConvertTo-Json -Depth 10

        # Write JSON with UTF-8 encoding without BOM
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", $utf8NoBom)

        Write-Host "[OK] Manifest version updated from $oldVersion to $latestVersion"
        Write-Host "[OK] Architecture URLs and hashes updated"

        exit 0
    } else {
        Write-Host "[INFO] Run with -Update switch to apply the update"
        exit 0
    }
} catch {
    Write-Error "Error checking manifest version: $($_.Exception.Message)"
    exit -1
}
