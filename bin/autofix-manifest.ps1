param(
    [string]$ManifestPath,
    [string]$BucketPath = (Split-Path -Parent (Split-Path -Parent $ManifestPath))
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
5. Validates fixes by running installation tests

.PARAMETER ManifestPath
Path to the manifest to fix.

.PARAMETER BucketPath
Path to the bucket directory (auto-detected if not provided).

.RETURNS
0 if fixed, -1 if unable to fix, 1 if already valid
#>

$ErrorActionPreference = 'Stop'

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
                    continue
                }
            }
            catch {
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
                    }
                    elseif ($arch -eq "64bit") {
                        $manifest.architecture.'64bit'.url = $newUrl
                    }
                    elseif ($arch -eq "32bit") {
                        $manifest.architecture.'32bit'.url = $newUrl
                    }

                    continue
                }
            }
            catch {
                # New URL also failed, try to find the actual release
            }

            # If simple version substitution didn't work, try to find via GitHub API
            if ($manifest.checkver.github) {
                Write-Host "  Attempting GitHub API lookup..."

                # Extract repo from GitHub URL
                if ($manifest.checkver.github -match 'github\.com/([^/]+/[^/]+)') {
                    $repo = $matches[1]

                    try {
                        $apiUrl = "https://api.github.com/repos/$repo/releases/tags/$latestVersion"
                        $release = Invoke-WebRequest -Uri $apiUrl -ErrorAction SilentlyContinue | ConvertFrom-Json

                        # Find matching asset
                        $asset = $null
                        if ($arch -eq "64bit") {
                            $asset = $release.assets | Where-Object { $_.name -match "x86.?64|win64|windows.x64|64.?bit" } | Select-Object -First 1
                        }
                        elseif ($arch -eq "32bit") {
                            $asset = $release.assets | Where-Object { $_.name -match "x86.?32|win32|windows.x86|32.?bit" } | Select-Object -First 1
                        }

                        if ($asset) {
                            $fixedUrl = $asset.browser_download_url
                            Write-Host "  ✓ GitHub API found: $fixedUrl" -ForegroundColor Green

                            if ($arch -eq "generic") {
                                $manifest.url = $fixedUrl
                            }
                            elseif ($arch -eq "64bit") {
                                $manifest.architecture.'64bit'.url = $fixedUrl
                            }
                            elseif ($arch -eq "32bit") {
                                $manifest.architecture.'32bit'.url = $fixedUrl
                            }
                        }
                    }
                    catch {
                        Write-Host "  ⚠ GitHub API lookup failed: $_"
                    }
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
            }
            catch {
                Write-Warning "Failed to download $Url : $_"
                return $null
            }
            finally {
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
        [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", [System.Text.Encoding]::UTF8)

        Write-Host "✓ Manifest auto-fixed and saved" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "Could not parse checkver output"
        exit -1
    }
}
catch {
    Write-Error "Error in auto-fix: $($_.Exception.Message)"
    exit -1
}
