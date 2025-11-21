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
