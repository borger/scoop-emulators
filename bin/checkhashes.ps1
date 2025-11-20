#!/usr/bin/env pwsh

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
