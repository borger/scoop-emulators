param(
    [string]$App = $null,
    [string]$Dir = $null
)

if (!$env:SCOOP_HOME) { $env:SCOOP_HOME = Convert-Path (scoop prefix scoop) }
$checkverScript = "$env:SCOOP_HOME/bin/checkver.ps1"
$bucketDir = if ($Dir) { $Dir } else { "$PSScriptRoot/../bucket" }

# Capture output from Scoop's checkver which uses Write-Host
# We use a temporary file to capture all output streams
$tempOutput = [System.IO.Path]::GetTempFileName()
try {
    # Run checkver and capture all output
    $output = & {
        & $checkverScript -Dir $bucketDir -App $App @args 6>&1 *>&1
    } | Tee-Object -FilePath $tempOutput

    # Output to pipeline
    $output

    # Also read from temp file to ensure nothing was lost
    if (Test-Path $tempOutput) {
        $fileContent = Get-Content -Path $tempOutput -Raw
        if ($fileContent -and -not ($output | Out-String).Contains($fileContent)) {
            Write-Output $fileContent
        }
    }
}
finally {
    if (Test-Path $tempOutput) {
        Remove-Item $tempOutput -Force -ErrorAction SilentlyContinue
    }
}
