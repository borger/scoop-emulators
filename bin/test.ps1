#!/usr/bin/env pwsh
<#
.SYNOPSIS
Run Pester tests for the bucket.

.DESCRIPTION
Executes the repository's Pester tests.
Tests validate manifest structure, checksums, and functionality.

.EXAMPLE
# Run all tests
.\test.ps1

.OUTPUTS
Pester test results with pass/fail count.

.REQUIREMENTS
- Pester 6.2.0 or higher
- BuildHelpers 2.0.1 or higher

.LINK
https://github.com/borger/scoop-emulators
#>

#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'BuildHelpers'; ModuleVersion = '2.0.1' }
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.2.0' }

$pesterConfig = New-PesterConfiguration -Hashtable @{
    Run    = @{
        Path     = (Join-Path $PSScriptRoot '..')
        PassThru = $true
    }
    Output = @{
        Verbosity = 'Detailed'
    }
}
$result = Invoke-Pester -Configuration $pesterConfig
exit $result.FailedCount
