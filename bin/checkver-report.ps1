#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$bucket = "$(Resolve-Path "$PSScriptRoot/../bucket")"
$outFile = Join-Path $PSScriptRoot "..\autofix-checkver-report.json"
$results = @()

function Get-TokenFromText($Text) {
    if (-not $Text) { return $null }
    $patterns = @(
        '(?<!\S)(?<ver>\d{4}-\d{2}-\d{2}-[a-f0-9]{7,40})(?!\S)',
        '(?<!\S)(?<ver>\d{4}-\d{2}-\d{2})(?!\S)',
        '(?<!\S)(?<ver>[a-f0-9]{7,40})(?!\S)',
        '(?<!\S)(?<ver>\d+(?:\.\d+)+[\w\.-_]*)',
        '(?<!\S)(?<ver>\d{2,})(?!\S)',
        '(?<!\S)(?<ver>\d)(?!\S)'
    )
    foreach ($p in $patterns) { if ($Text -match $p) { return $matches['ver'] } }
    $tokens = $Text -split '\s+' | ForEach-Object { $_.TrimEnd(':', ',', ';', '.') }
    foreach ($t in $tokens) { if ($t -match '\d') { if ($t -match '^\d' -or $t -match '\d$') { return $t } } }
    return $null
}

function Test-TokenValid($v) {
    if (-not $v) { return $false }
    if ($v -match '^[0-9]+$') { return $true }
    if ($v -match '^\d{4}-\d{2}-\d{2}$') { return $true }
    if ($v -match '^\d{4}-\d{2}-\d{2}-[a-f0-9]{7,40}$') { return $true }
    if ($v -match '^[a-f0-9]{7,40}$') { return $true }
    if ($v -match '^\d[0-9\.\-_]*\d$') { return $true }
    return $false
}

Get-ChildItem -Path $bucket -Filter '*.json' | Sort-Object Name | ForEach-Object {
    $app = $_.BaseName
    try {
        $raw = & "$PSScriptRoot\checkver.ps1" -App $app -Dir $bucket 2>&1 | Out-String
    } catch {
        $raw = $_.Exception.Message
    }
    $norm = ($raw -replace "`r", "") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }

    $token = $null; $valid = $false; $hasAppLine = $false; $appLineTail = $null; $nextLineToken = $null
    for ($i = 0; $i -lt $norm.Count; $i++) {
        $line = $norm[$i]
        if ($line -ieq "$($app):") {
            $hasAppLine = $true
            # look next non-empty
            for ($j = $i + 1; $j -lt $norm.Count; $j++) { if ($norm[$j] -notmatch '^\(scoop version') { $nextLineToken = Get-TokenFromText $norm[$j]; break } }
            break
        }
        if ($line -match '^' + [regex]::Escape($app) + '\s*:(?<tail>.*)$') {
            $hasAppLine = $true
            $appLineTail = $matches['tail'].Trim()
            if ($appLineTail -ne '') { $token = Get-TokenFromText $appLineTail; $valid = Test-TokenValid $token; break }
        }
    }
    if (-not $token -and -not $nextLineToken) {
        # fallback: scan all lines
        foreach ($l in $norm) { if ($l -match '\S') { $t = Get-TokenFromText $l; if ($t) { $token = $t; $valid = Test-TokenValid $token; break } } }
    } elseif ($nextLineToken -and -not $token) { $token = $nextLineToken; $valid = Test-TokenValid $token }

    $results += [ordered]@{
        manifest = $_.Name; app = $app; token = $token; valid = $valid; hasAppLine = $hasAppLine; appLineTail = $appLineTail; snippet = ($norm | Select-Object -First 6)
    }
}

$results | ConvertTo-Json -Depth 10 | Set-Content -Path $outFile -Encoding UTF8
Write-Host "Report written to $outFile"
