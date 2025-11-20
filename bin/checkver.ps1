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
    "$env:USERPROFILE\scoop\apps\scoop\current\bin\checkver.ps1",  # Alternative path
    "C:\Users\runneradmin\scoop\apps\scoop\current\bin\checkver.ps1",  # GitHub Actions default
    "C:\Users\runneradmin\scoop\apps\scoop\current/bin/checkver.ps1",  # Alternative slash
    "C:\tools\scoop\apps\scoop\current\bin\checkver.ps1",
    "/tools/scoop/apps/scoop/current/bin/checkver.ps1",
    "C:\scoop\apps\scoop\current\bin\checkver.ps1",  # Another common location
    "/scoop/apps/scoop/current/bin/checkver.ps1"
)

# Try explicit SCOOP_HOME first if set
if ($env:SCOOP_HOME) {
    $checkverScript = "$env:SCOOP_HOME/bin/checkver.ps1"
    if (Test-Path $checkverScript) {
        Write-Host "Found checkver at SCOOP_HOME: $checkverScript" -ForegroundColor Green
    } else {
        $checkverScript = $null
    }
}

# Try to get from scoop command if not found
if (!$checkverScript) {
    try {
        $scoopCmd = Get-Command scoop -ErrorAction SilentlyContinue
        if ($scoopCmd) {
            $scoopPrefix = & scoop prefix scoop 2>$null
            if ($scoopPrefix) {
                $env:SCOOP_HOME = $scoopPrefix
                $checkverScript = "$env:SCOOP_HOME/bin/checkver.ps1"
                if (Test-Path $checkverScript) {
                    Write-Host "Found checkver via scoop prefix: $checkverScript" -ForegroundColor Green
                } else {
                    $checkverScript = $null
                }
            }
        }
    } catch {
        Write-Host "Scoop command not available or failed: $_" -ForegroundColor Gray
    }
}

# Try fallback paths
if (!$checkverScript) {
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            $checkverScript = $path
            Write-Host "Found checkver at fallback path: $checkverScript" -ForegroundColor Green
            break
        }
    }
}

# Try to find scoop installation by searching common locations
if (!$checkverScript) {
    $searchPaths = @(
        "$env:ProgramData\scoop\apps\scoop\current\bin\checkver.ps1",
        "$env:USERPROFILE\scoop\apps\scoop\current\bin\checkver.ps1",
        "C:\scoop\apps\scoop\current\bin\checkver.ps1",
        "/opt/scoop/apps/scoop/current/bin/checkver.ps1"
    )
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            $checkverScript = $path
            Write-Host "Found checkver at search path: $checkverScript" -ForegroundColor Green
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
