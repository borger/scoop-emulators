#!/usr/bin/env pwsh

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
