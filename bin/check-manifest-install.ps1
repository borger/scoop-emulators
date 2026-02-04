#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Tests installation of a Scoop manifest.

.DESCRIPTION
    Validates JSON syntax, installs the app using Scoop, verifies installation,
    and performs cleanup.

.PARAMETER ManifestPath
    Path to the manifest JSON file.

.PARAMETER AppName
    Optional name override. Defaults to filename.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ManifestPath,

    [string]$AppName
)

$ErrorActionPreference = 'Stop'

# Ensure TLS 1.2 is enabled (critical for PS 5.1)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

if (-not (Get-Command 'scoop' -ErrorAction SilentlyContinue)) {
    Write-Error "Scoop is not installed or not in PATH."
    exit 1
}

try {
    $ManifestPath = Convert-Path $ManifestPath
    if ([string]::IsNullOrWhiteSpace($AppName)) {
        $AppName = [System.IO.Path]::GetFileNameWithoutExtension($ManifestPath)
    }

    # Validate JSON syntax
    try {
        $json = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        if (-not $json.version) { throw "Missing 'version' field" }
    } catch {
        throw "Invalid JSON or schema: $($_.Exception.Message)"
    }

    # Auto-retry behavior: if the manifest's asset URL returns 404, attempt
    # an update (via update-manifest.ps1) and retry once. If still failing,
    # run autofix-manifest.ps1 as a last-resort attempt.
    function Test-UrlExists {
        param([string]$Url)
        try {
            Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop | Out-Null
            return $true
        } catch {
            return $false
        }
    }

    function Ensure-ManifestAssetAvailable {
        param(
            [string]$ManifestPath,
            [int]$Retries = 1
        )

        for ($attempt = 0; $attempt -le $Retries; $attempt++) {
            $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
            $urls = @()

            # Prefer autoupdate templates when present
            if ($manifest.autoupdate -and $manifest.autoupdate.architecture) {
                foreach ($arch in $manifest.autoupdate.architecture.PSObject.Properties.Name) {
                    $u = $manifest.autoupdate.architecture.$arch.url
                    if ($u) { $urls += ($u -replace '\$version', [string]$manifest.version) }
                }
            }

            # Fallback to concrete architecture.url fields
            if ($urls.Count -eq 0 -and $manifest.architecture) {
                foreach ($arch in $manifest.architecture.PSObject.Properties.Name) {
                    $u = $manifest.architecture.$arch.url
                    if ($u) { $urls += $u }
                }
            }

            if ($urls.Count -eq 0) { return $true }

            $allGood = $true
            foreach ($u in $urls) {
                if (-not (Test-UrlExists $u)) {
                    $allGood = $false
                    break
                }
            }

            if ($allGood) { return $true }

            if ($attempt -lt $Retries) {
                Write-Host "One or more assets returned 404, attempting to update manifest (attempt $($attempt + 1) of $Retries)..." -ForegroundColor Yellow
                & "$PSScriptRoot/update-manifest.ps1" -ManifestPath $ManifestPath -Update
                Start-Sleep -Seconds 1
                continue
            } else {
                Write-Host "Asset missing after updates; running autofix and rechecking..." -ForegroundColor Yellow
                & "$PSScriptRoot/autofix-manifest.ps1" -ManifestPath $ManifestPath
                Start-Sleep -Seconds 1

                $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
                $urls = @()
                if ($manifest.autoupdate -and $manifest.autoupdate.architecture) {
                    foreach ($arch in $manifest.autoupdate.architecture.PSObject.Properties.Name) {
                        $u = $manifest.autoupdate.architecture.$arch.url
                        if ($u) { $urls += ($u -replace '\$version', [string]$manifest.version) }
                    }
                }
                if ($urls.Count -eq 0 -and $manifest.architecture) {
                    foreach ($arch in $manifest.architecture.PSObject.Properties.Name) {
                        $u = $manifest.architecture.$arch.url
                        if ($u) { $urls += $u }
                    }
                }

                foreach ($u in $urls) {
                    if (-not (Test-UrlExists $u)) { return $false }
                }

                return $true
            }
        }
    }

    if (-not $PSBoundParameters.ContainsKey('AutoRetry') -or $AutoRetry) {
        # Default to one retry; this keeps the behavior limited while handling
        # transient 404s caused by rotated nightly assets.
        if (-not (Ensure-ManifestAssetAvailable -ManifestPath $ManifestPath -Retries 1)) {
            throw "Asset URLs are unreachable even after update/autofix. Aborting."
        }
    }

    # Clean previous state
    if (scoop list $AppName) {
        Write-Host "Cleaning up previous installation..." -ForegroundColor Yellow
        scoop uninstall $AppName | Out-Null
    }

    Write-Host "Installing $AppName..." -ForegroundColor Cyan

    # Install
    scoop install "$ManifestPath"
    if ($LASTEXITCODE -ne 0) {
        throw "Installation failed with exit code $LASTEXITCODE"
    }

    # Verify
    if (-not (scoop list $AppName)) {
        throw "Installation reported success but app not found in list"
    }

    Write-Host "Installation successful!" -ForegroundColor Green
    exit 0

} catch {
    Write-Error $_.Exception.Message
    exit 1
} finally {
    # Cleanup
    if (Get-Command 'scoop' -ErrorAction SilentlyContinue) {
        if (scoop list $AppName) {
            Write-Host "Uninstalling cleanup..." -ForegroundColor Gray
            scoop uninstall $AppName | Out-Null
        }
    }
}
