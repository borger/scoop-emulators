$path = 'c:\Users\se7en\scoop\buckets\emulators\bin\autofix-manifest.ps1'
$code = Get-Content -Raw -LiteralPath $path
$errors = [ref]$null
$tokens = [ref]$null
try {
    [System.Management.Automation.Language.Parser]::ParseInput($code, $tokens, $errors) | Out-Null
    if ($errors.Value) {
        Write-Host 'PARSE_ERRORS:'
        $errors.Value | ForEach-Object { Write-Host $_ }
        exit 1
    } else {
        Write-Host 'PARSE_OK'
        exit 0
    }
} catch {
    Write-Host 'PARSE_EXCEPTION: ' $_
    exit 2
}
