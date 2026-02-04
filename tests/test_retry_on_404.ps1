# Test: Ensure check-manifest-install will update manifest when asset URL 404s
$ErrorActionPreference = 'Stop'
$manifestPath = Convert-Path (Join-Path $PSScriptRoot '..\bucket\citron.json')
$backup = "$manifestPath.bak"
Copy-Item -Path $manifestPath -Destination $backup -Force
try {
    Write-Host 'Temporarily reverting upstream manifest to an older nightly (c788400b7) to simulate a removed asset...'
    (Get-Content $manifestPath -Raw) -replace '"version":\s*"[a-f0-9]{7,40}"', '"version": "c788400b7"' -replace '"hash":\s*"[a-f0-9]{64}"', '"hash": "51a27e031eb0bc397b098639d3f96a8dc6ce3c8d9d044668c4b30699620a1860"' | Set-Content -Path $manifestPath -NoNewline

    Write-Host "Running check-manifest-install; it should detect 404, update manifest, then install successfully..."
    & "$PSScriptRoot\..\bin\check-manifest-install.ps1" -ManifestPath $manifestPath
    if ($LASTEXITCODE -eq 0) { Write-Host 'Test passed: auto-retry recovered from 404 and installation succeeded' } else { Write-Host 'Test failed: installer did not succeed' ; exit 1 }
} finally {
    Write-Host 'Restoring original manifest file...' -ForegroundColor Gray
    Move-Item -Path $backup -Destination $manifestPath -Force
}
