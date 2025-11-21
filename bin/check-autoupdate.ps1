#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Validates the autoupdate configuration in a Scoop manifest.

.DESCRIPTION
    Checks if the manifest contains a valid 'autoupdate' section and verifies that
    the configured URLs are accessible. Supports architecture-specific configurations
    (64bit, 32bit, arm64).

.PARAMETER ManifestPath
    Path to the manifest JSON file.

.EXAMPLE
    .\check-autoupdate.ps1 -ManifestPath "bucket/app.json"
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Ensure TLS 1.2 is enabled (critical for PS 5.1)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

function Test-UrlAccessibility {
    param([string]$Url)

    # Skip placeholders
    if ($Url -match '\$\w+') {
        Write-Verbose "[SKIP] URL contains placeholders: $Url"
        return $true
    }

    # Clean URL
    $cleanUrl = $Url -split '#' | Select-Object -First 1

    try {
        $params = @{
            Uri             = $cleanUrl
            Method          = 'Head'
            TimeoutSec      = 10
            UseBasicParsing = $true
            ErrorAction     = 'Stop'
            Headers         = @{ 'User-Agent' = 'Scoop-Manifest-Validator/1.0' }
        }
        $response = Invoke-WebRequest @params

        if ($response.StatusCode -eq 200) {
            return $true
        }
        Write-Error "HTTP Status $($response.StatusCode) for $cleanUrl"
        return $false
    } catch {
        Write-Error "Connection failed for $cleanUrl : $($_.Exception.Message)"
        return $false
    }
}

try {
    $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json

    if (-not $manifest.autoupdate) {
        throw "Manifest missing 'autoupdate' section"
    }

    $checks = @()

    # Helper to add checks
    function Add-Check {
        param($Arch, $Url)
        if ($Url) {
            $script:checks += [PSCustomObject]@{ Arch = $Arch; Url = $Url }
        }
    }

    # 1. Check root autoupdate URL (generic)
    Add-Check -Arch 'generic' -Url $manifest.autoupdate.url

    # 2. Check architecture specific (direct)
    foreach ($arch in @('64bit', '32bit', 'arm64')) {
        if ($manifest.autoupdate.$arch) {
            Add-Check -Arch $arch -Url $manifest.autoupdate.$arch.url
        }
    }

    # 3. Check architecture specific (nested)
    if ($manifest.autoupdate.architecture) {
        foreach ($arch in @('64bit', '32bit', 'arm64')) {
            if ($manifest.autoupdate.architecture.$arch) {
                Add-Check -Arch $arch -Url $manifest.autoupdate.architecture.$arch.url
            }
        }
    }

    if ($checks.Count -eq 0) {
        throw "No URLs found in autoupdate configuration"
    }

    Write-Host "Found $($checks.Count) URL(s) to validate." -ForegroundColor Cyan

    $failed = $false
    foreach ($check in $checks) {
        Write-Host "Checking [$($check.Arch)] $($check.Url)..." -NoNewline
        if (Test-UrlAccessibility -Url $check.Url) {
            Write-Host " [OK]" -ForegroundColor Green
        } else {
            Write-Host " [FAIL]" -ForegroundColor Red
            $failed = $true
        }
    }

    if ($failed) {
        exit 1
    }

    exit 0

} catch {
    Write-Error $_.Exception.Message
    exit 1
}
