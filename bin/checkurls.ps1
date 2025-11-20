#!/usr/bin/env pwsh
<#
.SYNOPSIS
Verify all download URLs in manifests are accessible.

.DESCRIPTION
Tests that all architecture URLs defined in manifest configuration are valid and return expected responses.
Useful for catching broken links before installation.

.PARAMETER App
Name of the app/manifest to check URLs for.
If not specified, checks all manifests in the bucket.

.PARAMETER Dir
Path to the bucket directory containing manifests.
If not specified, uses ../bucket relative to script location.

.EXAMPLE
# Check specific app URLs
.\checkurls.ps1 -App gopher64 -Dir bucket

# Check all manifests
.\checkurls.ps1 -Dir bucket

.OUTPUTS
Status for each URL (accessible or 404).

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
$checkurls = "$env:SCOOP_HOME/bin/checkurls.ps1"
$dir = "$PSScriptRoot/../bucket" # checks the parent dir
& $checkurls -Dir $dir @Args
