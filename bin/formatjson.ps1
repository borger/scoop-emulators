#!/usr/bin/env pwsh
<#
.SYNOPSIS
Format and validate JSON manifests.

.DESCRIPTION
Formats manifest JSON files with proper indentation and validates JSON structure.
Ensures all manifests follow consistent formatting.

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

if (!$env:SCOOP_HOME) { $env:SCOOP_HOME = Convert-Path (scoop prefix scoop) }
$formatjson = "$env:SCOOP_HOME/bin/formatjson.ps1"
$path = "$PSScriptRoot/../bucket" # checks the parent dir
& $formatjson -Dir $path @Args
