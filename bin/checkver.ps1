#!/usr/bin/env pwsh

param(
    [string]$App = $null,
    [string]$Dir = $null
)

# Get Scoop's checkver script from SCOOP_HOME
if (!$env:SCOOP_HOME) {
    # If SCOOP_HOME not set, try to get it from scoop command
    try {
        $env:SCOOP_HOME = & scoop prefix scoop 2>$null
    } catch {
        Write-Error "SCOOP_HOME not set and scoop command not available" -ErrorAction Stop
    }
}

$checkverScript = "$env:SCOOP_HOME/bin/checkver.ps1"

if (!(Test-Path $checkverScript)) {
    Write-Error "Scoop checkver script not found at: $checkverScript`nMake sure Scoop is installed." -ErrorAction Stop
}

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
