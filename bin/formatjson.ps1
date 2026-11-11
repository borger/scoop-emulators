#!/usr/bin/env pwsh
<#
.SYNOPSIS
Format and validate JSON manifests.

.DESCRIPTION
Formats manifest JSON files with Scoop's formatter and keeps short arrays in inline style.

.PARAMETER Dir
Path to the bucket directory containing manifests.
If not specified, uses ../bucket relative to script location.

.PARAMETER App
Specific app/manifest to format. If not specified, formats all manifests.

.EXAMPLE
# Format all manifests
.\formatjson.ps1

# Format specific bucket
.\formatjson.ps1 -Dir .\bucket

.OUTPUTS
Formatted and validated manifest files.

.LINK
https://github.com/borger/scoop-emulators
#>

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib-releasehelpers.ps1"

function Format-JsonManifest {
    param(
        [Parameter(Mandatory)]
        $Manifest
    )

    . (Join-Path $scoopHome 'lib\json.ps1')

    $Manifest | ConvertToPrettyJson
}

function Get-FormatJsonOptions {
    param(
        [object[]]$Arguments = @(),

        [Parameter(Mandatory)]
        [string]$DefaultDirectory
    )

    $targetDirectory = $DefaultDirectory
    $app = '*'
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $argument = [string]$Arguments[$i]
        if ($argument -ieq '-Dir') {
            if ($i + 1 -ge $Arguments.Count -or [string]$Arguments[$i + 1] -like '-*') {
                throw 'Option -Dir requires a directory path.'
            }
            $targetDirectory = [string]$Arguments[++$i]
        } elseif ($argument -like '-Dir:*') {
            $targetDirectory = $argument.Substring(5)
        } elseif ($argument -ieq '-App') {
            if ($i + 1 -ge $Arguments.Count -or [string]$Arguments[$i + 1] -like '-*') {
                throw 'Option -App requires an app name or pattern.'
            }
            $app = [string]$Arguments[++$i]
        } elseif ($argument -like '-App:*') {
            $app = $argument.Substring(5)
        } elseif ($argument.StartsWith('-')) {
            throw "Unknown option: $argument"
        } else {
            $app = $argument
        }

        if (($argument -ieq '-Dir' -or $argument -like '-Dir:*') -and [string]::IsNullOrWhiteSpace($targetDirectory)) {
            throw 'Option -Dir requires a directory path.'
        }
        if (($argument -ieq '-App' -or $argument -like '-App:*') -and [string]::IsNullOrWhiteSpace($app)) {
            throw 'Option -App requires an app name or pattern.'
        }
    }

    [PSCustomObject]@{
        Directory = $targetDirectory
        App       = $app
    }
}

function Get-JsonManifestFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [string]$App
    )

    $manifestFiles = @(Get-ChildItem -LiteralPath $Directory -Filter "$App.json" -File -Recurse)
    if ($App -ne '*' -and $manifestFiles.Count -eq 0) {
        throw "No manifest files matched '$App.json' in '$Directory'."
    }

    return $manifestFiles
}

$scoopHome = Get-ScoopHome
$dir = Join-Path $PSScriptRoot '..\bucket'
$arguments = Get-DirectoryArgumentList -Arguments $Args -DefaultDirectory $dir
$options = Get-FormatJsonOptions -Arguments $arguments -DefaultDirectory $dir
$targetDirectory = $options.Directory
$app = $options.App
$manifestFiles = Get-JsonManifestFiles -Directory $targetDirectory -App $app

$manifestFiles | ForEach-Object {
    $content = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
    $manifest = $content | ConvertFrom-Json -ErrorAction Stop
    $formatted = Format-JsonManifest -Manifest $manifest
    if (-not $formatted.EndsWith("`n")) {
        $formatted += [Environment]::NewLine
    }

    if ($formatted -cne $content) {
        [System.IO.File]::WriteAllText(
            $_.FullName,
            $formatted,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

