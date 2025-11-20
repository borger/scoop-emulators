#!/usr/bin/env pwsh

param(
    [string]$App = $null,
    [string]$Dir = $null
)

# Try to locate Scoop's checkver script
$checkverScript = $null
$possiblePaths = @(
    "$env:SCOOP_HOME/bin/checkver.ps1",
    "$env:USERPROFILE\scoop\apps\scoop\current\bin\checkver.ps1",
    "C:\tools\scoop\apps\scoop\current\bin\checkver.ps1",
    "/tools/scoop/apps/scoop/current/bin/checkver.ps1"
)

# Try explicit SCOOP_HOME first if set
if ($env:SCOOP_HOME) {
    $checkverScript = "$env:SCOOP_HOME/bin/checkver.ps1"
    if (Test-Path $checkverScript) {
        # Use this path
    } else {
        $checkverScript = $null
    }
}

# Try to get from scoop command if not found
if (!$checkverScript) {
    try {
        $scoopCmd = Get-Command scoop -ErrorAction SilentlyContinue
        if ($scoopCmd) {
            $env:SCOOP_HOME = Convert-Path (scoop prefix scoop)
            $checkverScript = "$env:SCOOP_HOME/bin/checkver.ps1"
        }
    } catch {
        # Scoop command not available
    }
}

# Try fallback paths
if (!$checkverScript -or !(Test-Path $checkverScript)) {
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            $checkverScript = $path
            break
        }
    }
}

# If still not found, error out
if (!$checkverScript -or !(Test-Path $checkverScript)) {
    Write-Error "Scoop checkver script not found. Tried: $($possiblePaths -join ', ')" -ErrorAction Stop
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
