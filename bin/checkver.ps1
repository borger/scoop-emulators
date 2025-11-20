#!/usr/bin/env pwsh
<#
.SYNOPSIS
Check version detection for a manifest using checkver configuration.

.DESCRIPTION
Validates that the checkver configuration in a manifest correctly detects the latest version from the repository.

.PARAMETER App
Name of the app/manifest to check (without .json extension).
If not specified, checks all manifests in the bucket.

.PARAMETER Dir
Path to the bucket directory containing manifests.
If not specified, uses ../bucket relative to script location.

.EXAMPLE
# Check specific app
.\checkver.ps1 -App gopher64 -Dir bucket

# Check all apps
.\checkver.ps1 -Dir bucket

.OUTPUTS
Version number if successful, or error message if detection fails.

.LINK
https://github.com/borger/scoop-emulators
#>

param(
    [string]$App = $null,
    [string]$Dir = $null
)

if (!$env:SCOOP_HOME) { $env:SCOOP_HOME = Convert-Path (scoop prefix scoop) }
$checkverScript = "$env:SCOOP_HOME/bin/checkver.ps1"
$bucketDir = if ($Dir) { $Dir } else { "$PSScriptRoot/../bucket" }

# Capture output from Scoop's checkver which uses Write-Host
# We use a temporary file to capture all output streams
$tempOutput = [System.IO.Path]::GetTempFileName()
try {
    # Run checkver and capture all output
    $output = & {
        & $checkverScript -Dir $bucketDir -App $App @args 6>&1 *>&1
    } | Tee-Object -FilePath $tempOutput

    # Output to pipeline
    $output

    # Also read from temp file to ensure nothing was lost
    if (Test-Path $tempOutput) {
        $fileContent = Get-Content -Path $tempOutput -Raw
        if ($fileContent -and -not ($output | Out-String).Contains($fileContent)) {
            Write-Output $fileContent
        }
    }
} finally {
    if (Test-Path $tempOutput) {
        Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
    }
}
