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

.PARAMETER AutoRetry
    Check asset URLs and attempt to repair unavailable manifests before installing.

.NOTES
    Verifies declared persist entries and always removes the temporary install.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ManifestPath,

    [string]$AppName,

    [bool]$AutoRetry = $true
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib-releasehelpers.ps1"

# Ensure TLS 1.2 is enabled (critical for PS 5.1)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

if (-not (Get-Command 'scoop' -ErrorAction SilentlyContinue)) {
    Write-Error "Scoop is not installed or not in PATH."
    exit 1
}

$scoopCommand = Get-Command 'scoop'
if (-not [string]::IsNullOrWhiteSpace($env:SCOOP)) {
    $scoopRoot = $env:SCOOP
} elseif ($scoopCommand.Source -and
    (Split-Path -Leaf (Split-Path -Parent $scoopCommand.Source)) -eq 'shims') {
    $scoopRoot = Split-Path -Parent (Split-Path -Parent $scoopCommand.Source)
} else {
    Write-Error 'Unable to determine the local Scoop root.'
    exit 1
}
$localAppsDirectory = Join-Path $scoopRoot 'apps'
$testExitCode = 0

function Uninstall-TestApp {
    param([string]$Name)

    $localAppPath = Join-Path $localAppsDirectory $Name
    if (-not (Test-Path -LiteralPath $localAppPath)) { return }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Seconds 3 }

        $uninstallOutput = @(scoop uninstall $Name 2>&1)
        $uninstallExitCode = $LASTEXITCODE
        if (-not (Test-Path -LiteralPath $localAppPath)) {
            Write-Host "Removed test install '$Name'." -ForegroundColor Green
            return
        }

        if ($attempt -eq 3) {
            $uninstallOutput | ForEach-Object { Write-Host $_ }
            throw "Unable to uninstall test app '$Name' after $attempt attempts (exit code $uninstallExitCode)."
        }

        Write-Host "App '$Name' is still installed after cleanup attempt $attempt; retrying." -ForegroundColor Yellow
    }
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
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
                return $false
            }

            throw
        }
    }

    function Resolve-ManifestAssetUrl {
        param(
            [string]$Template,
            [string]$Version,
            [string]$ConcreteUrl
        )

        if ($Template -match '\$match') {
            return $ConcreteUrl
        }

        return $Template.Replace('$version', $Version)
    }

    function Get-ManifestAssetUrls {
        param([object]$Manifest)

        $urls = @()
        $architectureNames = @()
        if ($Manifest.architecture) {
            $architectureNames += @($Manifest.architecture.PSObject.Properties.Name)
        }
        if ($Manifest.autoupdate -and $Manifest.autoupdate.architecture) {
            $architectureNames += @($Manifest.autoupdate.architecture.PSObject.Properties.Name)
        }
        foreach ($architecture in @('64bit', '32bit', 'arm64')) {
            if ($Manifest.autoupdate -and $Manifest.autoupdate.$architecture -and
                $architectureNames -notcontains $architecture) {
                $architectureNames += $architecture
            }
        }
        $architectureNames = @($architectureNames | Select-Object -Unique)

        if ($Manifest.autoupdate -and $Manifest.autoupdate.url) {
            $url = Resolve-ManifestAssetUrl -Template $Manifest.autoupdate.url `
                -Version ([string]$Manifest.version) -ConcreteUrl $Manifest.url
            if ($url) { $urls += $url }
        } elseif ($Manifest.url) {
            $urls += $Manifest.url
        }

        foreach ($architecture in $architectureNames) {
            $templates = @()
            $concreteUrl = $null
            if ($Manifest.architecture) {
                $concreteUrl = $Manifest.architecture.$architecture.url
            }
            if ($Manifest.autoupdate -and $Manifest.autoupdate.architecture) {
                $url = $Manifest.autoupdate.architecture.$architecture.url
                if ($url) { $templates += $url }
            }
            if ($Manifest.autoupdate -and $Manifest.autoupdate.$architecture.url) {
                $templates += $Manifest.autoupdate.$architecture.url
            }

            if ($templates.Count -gt 0) {
                foreach ($template in $templates) {
                    $url = Resolve-ManifestAssetUrl -Template $template `
                        -Version ([string]$Manifest.version) `
                        -ConcreteUrl $concreteUrl
                    if ($url -and $urls -notcontains $url) { $urls += $url }
                }
            } else {
                if ($concreteUrl -and $urls -notcontains $concreteUrl) { $urls += $concreteUrl }
            }
        }

        return $urls
    }

    function Test-ManifestAssetAvailability {
        param(
            [string]$ManifestPath,
            [int]$Retries = 1
        )

        for ($attempt = 0; $attempt -le $Retries; $attempt++) {
            $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
            $urls = @(Get-ManifestAssetUrls -Manifest $manifest)

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
                $updateResult = Invoke-PowerShellScript -Path (Join-Path $PSScriptRoot 'update-manifest.ps1') `
                    -ArgumentList @('-ManifestPath', $ManifestPath, '-Update')
                if ($updateResult.ExitCode -ne 0) {
                    throw "Manifest update failed with exit code $($updateResult.ExitCode). $($updateResult.Output)"
                }
                if ($updateResult.Output) { Write-Host $updateResult.Output }
                Start-Sleep -Seconds 1
                continue
            } else {
                Write-Host "Asset missing after updates; running autofix and rechecking..." -ForegroundColor Yellow
                $autofixResult = Invoke-PowerShellScript -Path (Join-Path $PSScriptRoot 'autofix-manifest.ps1') `
                    -ArgumentList @('-ManifestPath', $ManifestPath)
                if ($autofixResult.ExitCode -ne 0) {
                    throw "Manifest autofix failed with exit code $($autofixResult.ExitCode). $($autofixResult.Output)"
                }
                if ($autofixResult.Output) { Write-Host $autofixResult.Output }
                Start-Sleep -Seconds 1

                $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
                $urls = @(Get-ManifestAssetUrls -Manifest $manifest)

                foreach ($u in $urls) {
                    if (-not (Test-UrlExists $u)) { return $false }
                }

                return $true
            }
        }
    }

    if ($AutoRetry) {
        # Default to one retry; this keeps the behavior limited while handling
        # transient 404s caused by rotated nightly assets.
        if (-not (Test-ManifestAssetAvailability -ManifestPath $ManifestPath -Retries 1)) {
            throw "Asset URLs are unreachable even after update/autofix. Aborting."
        }
    }

    # Clean previous state
    $localAppPath = Join-Path $localAppsDirectory $AppName
    if (Test-Path -LiteralPath $localAppPath) {
        Write-Host "Cleaning up previous installation..." -ForegroundColor Yellow
        Uninstall-TestApp -Name $AppName
    }

    Write-Host "Installing $AppName..." -ForegroundColor Cyan

    # Install
    scoop install "$ManifestPath"
    if ($LASTEXITCODE -ne 0) {
        throw "Installation failed with exit code $LASTEXITCODE"
    }

    # Verify
    if (-not (Test-Path -LiteralPath $localAppPath)) {
        throw "Installation reported success but local app '$AppName' was not found."
    }

    $installPath = Convert-Path (scoop prefix $AppName)
    if ($json.persist) {
        $persistDirectory = Join-Path (Join-Path $scoopRoot 'persist') $AppName
        foreach ($entry in @($json.persist)) {
            $source = [string]$entry
            $target = $source
            if ($entry -is [array]) {
                $source = [string]$entry[0]
                if ($entry.Count -gt 1) { $target = [string]$entry[1] }
            }

            $installedPath = Join-Path $installPath $source
            $storedPath = Join-Path $persistDirectory $target
            if (-not (Test-Path -LiteralPath $installedPath) -or -not (Test-Path -LiteralPath $storedPath)) {
                throw "Persist entry '$source' was not created in both the app directory and persist store."
            }

            $persistedItem = Get-Item -LiteralPath $storedPath
            $itemType = if ($persistedItem.PSIsContainer) { 'folder' } else { 'file' }
            Write-Host "Persist verified ($itemType): $source" -ForegroundColor Green
        }
    } else {
        Write-Host "No persist entries declared."
    }

    Write-Host "Installation successful!" -ForegroundColor Green

} catch {
    Write-Error $_.Exception.Message -ErrorAction Continue
    $testExitCode = 1
} finally {
    # Cleanup
    if (Get-Command 'scoop' -ErrorAction SilentlyContinue) {
        if (Test-Path -LiteralPath (Join-Path $localAppsDirectory $AppName)) {
            Write-Host "Uninstalling cleanup..." -ForegroundColor Gray
            Uninstall-TestApp -Name $AppName
        }
    }
}

exit $testExitCode
