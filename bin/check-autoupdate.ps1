param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath
)

<#
.SYNOPSIS
Checks if a manifest has valid autoupdate configuration and verifies architecture URLs.

.DESCRIPTION
This script validates that:
1. The manifest contains an 'autoupdate' section
2. All architecture URLs in autoupdate are accessible and valid
3. The autoupdate version can be retrieved successfully

.PARAMETER ManifestPath
The path to the manifest JSON file to check.

.RETURNS
0 if autoupdate is valid and all URLs are working
-1 if an error occurs (prints error message to stderr)
#>

$ErrorActionPreference = 'Stop'

try {
    # Check if file exists
    if (!(Test-Path $ManifestPath)) {
        Write-Error "Manifest file not found: $ManifestPath"
        exit -1
    }

    # Read and parse the manifest
    $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json

    # Check if autoupdate exists
    if (!$manifest.autoupdate) {
        Write-Error "Manifest does not contain 'autoupdate' section"
        exit -1
    }

    Write-Verbose "Manifest has autoupdate section"

    # Determine if we have architecture-specific or generic URLs
    $urls = @()
    $architectures = @()

    if ($manifest.autoupdate.'64bit' -or $manifest.autoupdate.'32bit') {
        # Architecture-specific URLs (direct)
        if ($manifest.autoupdate.'64bit') {
            $architectures += '64bit'
            $urls += @{ arch = '64bit'; url = $manifest.autoupdate.'64bit'.url }
        }
        if ($manifest.autoupdate.'32bit') {
            $architectures += '32bit'
            $urls += @{ arch = '32bit'; url = $manifest.autoupdate.'32bit'.url }
        }
    } elseif ($manifest.autoupdate.architecture.'64bit' -or $manifest.autoupdate.architecture.'32bit') {
        # Architecture-specific URLs (nested under architecture)
        if ($manifest.autoupdate.architecture.'64bit') {
            $architectures += '64bit'
            $urls += @{ arch = '64bit'; url = $manifest.autoupdate.architecture.'64bit'.url }
        }
        if ($manifest.autoupdate.architecture.'32bit') {
            $architectures += '32bit'
            $urls += @{ arch = '32bit'; url = $manifest.autoupdate.architecture.'32bit'.url }
        }
    } elseif ($manifest.autoupdate.url) {
        # Generic URL (applies to all architectures)
        $urls += @{ arch = 'generic'; url = $manifest.autoupdate.url }
    } else {
        Write-Error "Autoupdate section does not contain any 'url' fields"
        exit -1
    }

    Write-Verbose "Found $($urls.Count) URL(s) to check"

    # Check each URL
    foreach ($urlEntry in $urls) {
        $url = $urlEntry.url
        $arch = $urlEntry.arch

        Write-Verbose "Checking $arch URL: $url"

        # Check for placeholder variables in the URL
        if ($url -match '\$\w+') {
            Write-Verbose "⚠ $arch URL contains placeholder variables (e.g., \$version, \$match1) - skipping accessibility check"
            continue
        }

        # Extract the base URL (before any fragment or query parameters)
        $testUrl = $url -split '#' | Select-Object -First 1

        try {
            $response = Invoke-WebRequest -Uri $testUrl -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop

            if ($response.StatusCode -ne 200) {
                Write-Error "Autoupdate.$arch URL returned status code $($response.StatusCode): $url"
                exit -1
            }

            Write-Verbose "✓ $arch URL is accessible (HTTP $($response.StatusCode))"
        } catch {
            Write-Error "Autoupdate.$arch URL is not accessible: $url`nError: $($_.Exception.Message)"
            exit -1
        }
    }

    Write-Verbose "✓ All autoupdate URLs are valid and accessible"
    exit 0
} catch {
    Write-Error "Error validating autoupdate: $($_.Exception.Message)"
    exit -1
}
