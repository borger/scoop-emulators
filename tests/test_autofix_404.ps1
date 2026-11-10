$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot '..\bin\autofix-manifest.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $scriptPath),
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Could not parse autofix-manifest.ps1: $($parseErrors[0].Message)"
}

foreach ($functionName in 'Get-VersionTokenFromText', 'Test-VersionLooksValid', 'Get-VersionFromCheckverOutput') {
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if (-not $functionAst) {
        throw "Function not found: $functionName"
    }
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$errorOutput = @'
citron: The remote server returned an error: (404) Not Found.
URL [https://api.github.com/repos/citron-neo/emulator/releases/latest] is not valid
'@
$version = Get-VersionFromCheckverOutput -Output $errorOutput -AppName 'citron'
if ($null -ne $version) {
    throw "An HTTP 404 was incorrectly parsed as version '$version'"
}

$validOutput = 'citron: 0237a9b88'
$version = Get-VersionFromCheckverOutput -Output $validOutput -AppName 'citron'
if ($version -ne '0237a9b88') {
    throw "Expected checkver version 0237a9b88, got '$version'"
}

Write-Host 'test_autofix_404 passed'
