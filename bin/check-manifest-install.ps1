param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [string]$AppName = $null
)

<#
.SYNOPSIS
Tests if a manifest can be successfully installed with Scoop.

.DESCRIPTION
This script performs the following:
1. Validates the manifest JSON structure
2. Extracts the app name from the manifest filename if not provided
3. Runs 'scoop install' with the manifest
4. Checks for installation success
5. Returns appropriate exit codes with error messages on failure

.PARAMETER ManifestPath
The path to the manifest JSON file to install.

.PARAMETER AppName
Optional. The name of the app. If not provided, extracted from the manifest filename.

.RETURNS
0 if installation succeeds
-1 if an error occurs (prints error message to stderr)
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

    # Parse app name from filename if not provided
    if (!$AppName) {
        $AppName = [System.IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf $ManifestPath))
        Write-Verbose "Extracted app name from filename: $AppName"
    }

    # Validate manifest JSON structure
    try {
        $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json
        Write-Verbose "✓ Manifest JSON is valid"
    } catch {
        Write-Error "Invalid manifest JSON in $ManifestPath : $($_.Exception.Message)"
        exit -1
    }

    # Check for required manifest fields
    if (!$manifest.version) {
        Write-Error "Manifest is missing required 'version' field"
        exit -1
    }

    Write-Verbose "Manifest version: $($manifest.version)"

    # Check if app is already installed
    $installedApps = scoop list 2>&1
    if ($installedApps -match $AppName) {
        Write-Verbose "App '$AppName' is already installed, uninstalling first..."
        scoop uninstall $AppName 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }

    # Attempt installation
    Write-Verbose "Installing app from manifest: $AppName"

    $installOutput = scoop install $ManifestPath 2>&1
    $installExitCode = $LASTEXITCODE

    if ($installExitCode -ne 0) {
        Write-Error "Installation failed with exit code $installExitCode`nOutput: $installOutput"
        exit -1
    }

    # Verify installation was successful
    $installedApps = scoop list 2>&1
    if ($installedApps -match $AppName) {
        Write-Verbose "✓ Installation successful: $AppName"

        # Clean up - uninstall after successful test
        Write-Verbose "Cleaning up: uninstalling $AppName"
        scoop uninstall $AppName 2>&1 | Out-Null

        exit 0
    } else {
        Write-Error "Installation verification failed: $AppName not found in installed apps list"
        exit -1
    }
} catch {
    Write-Error "Error during installation test: $($_.Exception.Message)"
    exit -1
}
