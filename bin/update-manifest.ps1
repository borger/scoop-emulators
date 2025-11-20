#!/usr/bin/env pwsh

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

    Write-Verbose "✓ Manifest has both 'checkver' and 'autoupdate' sections"

    $currentVersion = $manifest.version
    Write-Verbose "Current version: $currentVersion"

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

    # Parse the output to find the latest version
    # checkver outputs either:
    # - "shadps4: 0.12.5 (scoop version is 0.12.0) autoupdate available" (outdated)
    # - "shadps4: 0.12.5" (already up to date)
    if ($checkverOutput -match ':\s+([\d\.]+)(\s+\(scoop version)?') {
        $latestVersion = $matches[1]
    } else {
        Write-Error "Could not parse version from checkver output: $checkverOutput"
        exit -1
    }

    Write-Verbose "Latest version found: $latestVersion"
    Write-Host "Found version: $latestVersion (current: $currentVersion)"

    if ($latestVersion -eq $currentVersion -and !$Force) {
        Write-Host "✓ Manifest is already up to date"
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

        # Process autoupdate to update URLs with the new version
        if ($manifestJson.autoupdate.architecture.'64bit'.url) {
            Write-Verbose "Updating 64bit URL..."
            $manifestJson.architecture.'64bit'.url = $manifestJson.autoupdate.architecture.'64bit'.url -replace '\$version', $latestVersion
        }

        if ($manifestJson.autoupdate.architecture.'32bit'.url) {
            Write-Verbose "Updating 32bit URL..."
            $manifestJson.architecture.'32bit'.url = $manifestJson.autoupdate.architecture.'32bit'.url -replace '\$version', $latestVersion
        }

        if ($manifestJson.autoupdate.'64bit'.url) {
            Write-Verbose "Updating 64bit URL (direct)..."
            $manifestJson.architecture.'64bit'.url = $manifestJson.autoupdate.'64bit'.url -replace '\$version', $latestVersion
        }

        if ($manifestJson.autoupdate.'32bit'.url) {
            Write-Verbose "Updating 32bit URL (direct)..."
            $manifestJson.architecture.'32bit'.url = $manifestJson.autoupdate.'32bit'.url -replace '\$version', $latestVersion
        }

        if ($manifestJson.autoupdate.url) {
            Write-Verbose "Updating generic URL..."
            $manifestJson.url = $manifestJson.autoupdate.url -replace '\$version', $latestVersion
        }

        # Now we need to get the hashes for the updated URLs
        Write-Verbose "Calculating hashes for updated URLs..."

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
            $hash64 = Get-RemoteFileHash -Url $url64
            if ($hash64) {
                $manifestJson.architecture.'64bit'.hash = $hash64
                Write-Verbose "✓ 64bit hash updated: $hash64"
            }
        }

        if ($manifestJson.architecture.'32bit'.url) {
            $url32 = $manifestJson.architecture.'32bit'.url
            Write-Verbose "Getting hash for 32bit: $url32"
            $hash32 = Get-RemoteFileHash -Url $url32
            if ($hash32) {
                $manifestJson.architecture.'32bit'.hash = $hash32
                Write-Verbose "✓ 32bit hash updated: $hash32"
            }
        }

        if ($manifestJson.url) {
            $urlGeneric = $manifestJson.url
            Write-Verbose "Getting hash for generic URL: $urlGeneric"
            $hashGeneric = Get-RemoteFileHash -Url $urlGeneric
            if ($hashGeneric) {
                $manifestJson.hash = $hashGeneric
                Write-Verbose "✓ Generic hash updated: $hashGeneric"
            }
        }

        # Convert back to JSON and save with proper formatting
        $updatedJson = $manifestJson | ConvertTo-Json -Depth 10

        # Write JSON with UTF-8 encoding (no BOM)
        [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", [System.Text.Encoding]::UTF8)

        Write-Host "✓ Manifest version updated from $oldVersion to $latestVersion"
        Write-Host "✓ Architecture URLs and hashes updated"

        exit 0
    } else {
        Write-Host "ℹ Run with -Update switch to apply the update"
        exit 0
    }
} catch {
    Write-Error "Error checking manifest version: $($_.Exception.Message)"
    exit -1
}
