Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib-releasehelpers.ps1"
Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) | Out-Null
Set-Location ..\
$bucketPath = Join-Path (Get-Location) 'bucket'
$results = @()
$manifests = Get-ChildItem -Path $bucketPath -Filter *.json | Sort-Object Name

function Get-AutofixRunStatus {
    [CmdletBinding()]
    param(
        [string]$Output,
        [int]$ExitCode
    )

    if ($ExitCode -ne 0) { return 'failed' }
    if ($Output -match 'Manifest auto-fixed and saved|Rewriting manifest|Updated quoted version|Updated hash|Auto-fixing hash mismatch') {
        return 'fixed'
    }
    if ($Output -match 'Extracted version looks invalid|could not parse checkver output|Checkver Parse Failed') {
        return 'rejected'
    }
    return 'up-to-date'
}

foreach ($m in $manifests) {
    Write-Host "=== Running autofix for $($m.Name) ==="
    $mf = $m.FullName
    $app = [IO.Path]::GetFileNameWithoutExtension($m.Name)
    try {
        $result = Invoke-PowerShellScript -Path (Join-Path $PSScriptRoot 'autofix-manifest.ps1') `
            -ArgumentList @('-ManifestPath', $mf)
        $out = $result.Output
        $exit = $result.ExitCode
    } catch {
        $out = $_ | Out-String
        $exit = 1
    }
    $status = Get-AutofixRunStatus -Output $out -ExitCode $exit
    $snippet = ($out -split "`n") | Select-Object -First 40
    $results += [PSCustomObject]@{ manifest = $m.Name; app = $app; path = $mf; status = $status; exitcode = $exit; snippet = $snippet }
}
$reportPath = Join-Path (Get-Location) 'autofix-report.json'
$jsonString = ($results | ConvertTo-Json -Depth 6) + "`r`n"
[System.IO.File]::WriteAllText($reportPath, $jsonString)
Write-Host "REPORT_SAVED: $reportPath"
Write-Host "Done."
