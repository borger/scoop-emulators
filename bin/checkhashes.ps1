#!/usr/bin/env pwsh
<#
.SYNOPSIS
Verify SHA256 hashes in manifests match downloaded files.

.DESCRIPTION
Validates that the SHA256 hashes in manifest architecture sections match the actual downloaded files.
Uses Scoop's built-in checkhashes utility.

.PARAMETER App
Name of the app/manifest to check hashes for.
If not specified, checks all manifests in the bucket.

.PARAMETER Dir
Path to the bucket directory containing manifests.
If not specified, uses ../bucket relative to script location.

.EXAMPLE
# Check specific app hashes
.\checkhashes.ps1 -App gopher64 -Dir bucket

# Check all manifests
.\checkhashes.ps1 -Dir bucket

.OUTPUTS
Validation results for each manifest hash.

.LINK
https://github.com/borger/scoop-emulators
#>

if (!$env:SCOOP_HOME) {
    try {
        $env:SCOOP_HOME = Convert-Path (scoop prefix scoop)
    } catch {
        $env:SCOOP_HOME = "$env:USERPROFILE\scoop\apps\scoop\current"
    }
}
$checkhashes = "$env:SCOOP_HOME/bin/checkhashes.ps1"
$dir = "$PSScriptRoot/../bucket" # checks the parent dir
& $checkhashes -Dir $dir @Args
