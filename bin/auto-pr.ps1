#!/usr/bin/env pwsh
<#
.SYNOPSIS
Create pull requests for manifest updates.

.DESCRIPTION
Automatically detects manifest updates and creates pull requests for merging to upstream.
Uses Scoop's auto-pr utility configured for the emulators bucket.

.PARAMETER upstream
Upstream repository in format "owner/repo:branch".
Default: "borger/scoop-emulators:master"

.EXAMPLE
# Create PRs for all updates
.\auto-pr.ps1

# Create PRs targeting specific upstream
.\auto-pr.ps1 -upstream "username/fork:develop"

.OUTPUTS
Pull request creation status and URLs.

.LINK
https://github.com/borger/scoop-emulators
#>

param(
    # overwrite upstream param
    [String]$upstream = "borger/scoop-emulators:master"
)

if (!$env:SCOOP_HOME) {
    try {
        $env:SCOOP_HOME = Convert-Path (scoop prefix scoop)
    } catch {
        $env:SCOOP_HOME = "$env:USERPROFILE\scoop\apps\scoop\current"
    }
}
$autopr = "$env:SCOOP_HOME/bin/auto-pr.ps1"
$dir = "$PSScriptRoot/../bucket" # checks the parent dir
& $autopr -Dir $dir -Upstream $Upstream @Args
