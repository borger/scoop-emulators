param(
    [Parameter(Mandatory=$true)]
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

    if (!$env:SCOOP_HOME) {
        $env:SCOOP_HOME = Convert-Path (scoop prefix scoop)
    }

    $checkverScript = "$env:SCOOP_HOME/bin/checkver.ps1"

    if (!(Test-Path $checkverScript)) {
        Write-Error "Scoop checkver script not found at $checkverScript"
        exit -1
    }

    # Capture checkver output using pwsh directly to ensure Write-Host is captured
    $checkverOutput = pwsh -NoProfile -Command "& '$checkverScript' -App '$AppName' -Dir '$(Split-Path $ManifestPath)' 2>&1"

    Write-Verbose "Checkver output: '$checkverOutput'"

    # Parse the output to find the latest version
    # checkver outputs either:
    # - "shadps4: 0.12.5 (scoop version is 0.12.0) autoupdate available" (outdated)
    # - "shadps4: 0.12.5" (already up to date)
    if ($checkverOutput -match ':\s+([\d\.]+)(\s+\(scoop version)?') {
        $latestVersion = $matches[1]
    }
    else {
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

        # Update version
        $manifestJson.version = $latestVersion

        # Convert back to JSON and save with proper formatting
        $updatedJson = $manifestJson | ConvertTo-Json -Depth 10

        # Write JSON with UTF8 encoding
        [System.IO.File]::WriteAllText($ManifestPath, $updatedJson + "`n", [System.Text.Encoding]::UTF8)

        Write-Host "✓ Manifest version updated from $currentVersion to $latestVersion"
        Write-Host "ℹ Note: Run 'scoop checkver -Update $AppName' in the bucket directory to calculate hashes."

        exit 0
    }
    else {
        Write-Host "ℹ Run with -Update switch to apply the update"
        exit 0
    }
}
catch {
    Write-Error "Error checking manifest version: $($_.Exception.Message)"
    exit -1
}
