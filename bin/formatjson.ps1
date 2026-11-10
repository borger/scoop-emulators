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

function Get-JsonArrayEndIndex {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [int]$StartIndex
    )

    $depth = 0
    $inString = $false
    $escaped = $false

    for ($i = $StartIndex; $i -lt $Json.Length; $i++) {
        $character = $Json[$i]
        if ($inString) {
            if ($escaped) {
                $escaped = $false
            } elseif ($character -eq '\') {
                $escaped = $true
            } elseif ($character -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($character -eq '"') {
            $inString = $true
        } elseif ($character -eq '[') {
            $depth++
        } elseif ($character -eq ']') {
            $depth--
            if ($depth -eq 0) {
                return $i
            }
        }
    }

    throw "Unterminated JSON array at character $StartIndex."
}

function Get-CompactJsonArray {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [int]$StartIndex,

        [Parameter(Mandatory)]
        [int]$EndIndex
    )

    $builder = [System.Text.StringBuilder]::new()
    $inString = $false
    $escaped = $false
    $arrayDepth = 0
    $nestedArrayCount = 0

    for ($i = $StartIndex + 1; $i -lt $EndIndex; $i++) {
        $character = $Json[$i]
        if ($inString) {
            [void]$builder.Append($character)
            if ($escaped) {
                $escaped = $false
            } elseif ($character -eq '\') {
                $escaped = $true
            } elseif ($character -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($character -eq '"') {
            $inString = $true
            [void]$builder.Append($character)
        } elseif ($character -eq '{' -or $character -eq '}') {
            return $null
        } elseif ($character -eq '[') {
            if ($arrayDepth -eq 0) {
                $nestedArrayCount++
            }
            $arrayDepth++
            [void]$builder.Append($character)
        } elseif ($character -eq ']') {
            $arrayDepth--
            [void]$builder.Append($character)
        } elseif ($character -eq ',') {
            [void]$builder.Append(', ')
        } elseif (-not [char]::IsWhiteSpace($character)) {
            [void]$builder.Append($character)
        }
    }

    if ($nestedArrayCount -gt 1) {
        return $null
    }

    return '[' + $builder.ToString() + ']'
}

function Format-JsonArrays {
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [int]$PrintWidth = 100
    )

    $builder = [System.Text.StringBuilder]::new()
    $lineLength = 0
    $inString = $false
    $escaped = $false

    for ($i = 0; $i -lt $Json.Length; $i++) {
        $character = $Json[$i]
        if ($inString) {
            [void]$builder.Append($character)
            if ($escaped) {
                $escaped = $false
            } elseif ($character -eq '\') {
                $escaped = $true
            } elseif ($character -eq '"') {
                $inString = $false
            }
        } elseif ($character -eq '"') {
            $inString = $true
            [void]$builder.Append($character)
        } elseif ($character -eq '[') {
            $endIndex = Get-JsonArrayEndIndex -Json $Json -StartIndex $i
            $compactArray = Get-CompactJsonArray -Json $Json -StartIndex $i -EndIndex $endIndex
            if ($null -ne $compactArray -and $lineLength + $compactArray.Length -lt $PrintWidth) {
                [void]$builder.Append($compactArray)
                $lineLength += $compactArray.Length
                $i = $endIndex
                continue
            }
            [void]$builder.Append($character)
        } else {
            [void]$builder.Append($character)
        }

        if ($character -eq "`n") {
            $lineLength = 0
        } elseif ($character -ne "`r") {
            $lineLength++
        }
    }

    return $builder.ToString()
}

function Format-JsonManifest {
    param(
        [Parameter(Mandatory)]
        $Manifest
    )

    . (Join-Path $scoopHome 'lib\json.ps1')

    function normalize_values {
        param([psobject]$json)
        return $json
    }

    $Manifest | ConvertToPrettyJson
}

$scoopHome = Get-ScoopHome
$dir = Join-Path $PSScriptRoot '..\bucket'
$arguments = Get-DirectoryArgumentList -Arguments $Args -DefaultDirectory $dir

$targetDirectory = $dir
$app = '*'
for ($i = 0; $i -lt $arguments.Count; $i++) {
    $argument = [string]$arguments[$i]
    if ($argument -ieq '-Dir' -and $i + 1 -lt $arguments.Count) {
        $targetDirectory = [string]$arguments[++$i]
    } elseif ($argument -like '-Dir:*') {
        $targetDirectory = $argument.Substring(5)
    } elseif ($argument -ieq '-App' -and $i + 1 -lt $arguments.Count) {
        $app = [string]$arguments[++$i]
    } elseif ($argument -like '-App:*') {
        $app = $argument.Substring(5)
    } elseif ($argument -notlike '-*') {
        $app = $argument
    }
}

Get-ChildItem -LiteralPath $targetDirectory -Filter "$app.json" -File -Recurse | ForEach-Object {
    $content = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
    $manifest = $content | ConvertFrom-Json -ErrorAction Stop
    $formatted = Format-JsonManifest -Manifest $manifest
    $formatted = Format-JsonArrays -Json $formatted
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

