Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-Location -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) | Out-Null
Set-Location ..\
$bucketPath = Join-Path (Get-Location) 'bucket'
$results = @()
$manifests = Get-ChildItem -Path $bucketPath -Filter *.json | Sort-Object Name
foreach ($m in $manifests) {
    Write-Host "=== Running autofix for $($m.Name) ==="
    $mf = $m.FullName
    $app = [IO.Path]::GetFileNameWithoutExtension($m.Name)
    try {
        $out = & .\bin\autofix-manifest.ps1 -ManifestPath $mf 2>&1 | Out-String
        $exit = $LASTEXITCODE
    } catch {
        $out = $_ | Out-String
        $exit = 1
    }
    if ($out -match 'Manifest auto-fixed and saved' -or $out -match 'Rewriting manifest' -or $out -match 'Updated quoted version' -or $out -match 'Updated hash' -or $out -match 'Auto-fixing hash mismatch') {
        $status = 'fixed'
    } elseif ($out -match 'Extracted version looks invalid' -or $out -match 'could not parse checkver output' -or $out -match 'Checkver Parse Failed') {
        $status = 'rejected'
    } elseif ($out -match 'Manifest already up-to-date' -or $out -match 'already up-to-date') {
        $status = 'up-to-date'
    } elseif ($exit -ne 0) {
        $status = 'failed'
    } else {
        $status = 'up-to-date'
    }
    $snippet = ($out -split "`n") | Select-Object -First 40
    $results += [PSCustomObject]@{ manifest = $m.Name; app = $app; path = $mf; status = $status; exitcode = $exit; snippet = $snippet }
}
$reportPath = Join-Path (Get-Location) 'autofix-report.json'
$results | ConvertTo-Json -Depth 6 | Out-File -FilePath $reportPath -Encoding utf8
Write-Host "REPORT_SAVED: $reportPath"
Write-Host "Done."
