function Get-TestFunctionScriptBlock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string[]]$Name
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path $Path),
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "Could not parse $Path`: $($parseErrors[0].Message)"
    }

    foreach ($functionName in $Name) {
        $functionAst = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true)
        if (-not $functionAst) {
            throw "Function not found in ${Path}: $functionName"
        }

        [scriptblock]::Create($functionAst.Extent.Text)
    }
}
