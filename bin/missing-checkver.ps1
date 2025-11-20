#!/usr/bin/env pwsh
<#
.SYNOPSIS
Find manifests missing checkver configuration.

.DESCRIPTION
Identifies manifest files that do not have a checkver section configured.
Manifests without checkver cannot be automatically updated.

.PARAMETER Dir
Path to the bucket directory to scan for missing checkver.
If not specified, uses ../bucket relative to script location.

.EXAMPLE
# Find all manifests missing checkver
.\missing-checkver.ps1

# Scan specific bucket
.\missing-checkver.ps1 -Dir .\bucket

.OUTPUTS
List of manifest names that are missing checkver configuration.

.LINK
https://github.com/borger/scoop-emulators
#>

if (!$env:SCOOP_HOME) { $env:SCOOP_HOME = Convert-Path (scoop prefix scoop) }
$missing_checkver = "$env:SCOOP_HOME/bin/missing-checkver.ps1"
$dir = "$PSScriptRoot/../bucket" # checks the parent dir
& $missing_checkver -Dir $dir @Args
