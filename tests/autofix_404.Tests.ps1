Describe 'Get-VersionFromCheckverOutput' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\autofix-manifest.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Get-VersionTokenFromText',
                    'Test-VersionLooksValid',
                    'Get-VersionFromCheckverOutput'
                ))) {
            . $functionBlock
        }
    }

    It 'does not parse an HTTP 404 message as a version' {
        $errorOutput = @'
citron: The remote server returned an error: (404) Not Found.
URL [https://api.github.com/repos/citron-neo/emulator/releases/latest] is not valid
'@

        Get-VersionFromCheckverOutput -Output $errorOutput -AppName 'citron' | Should -BeNullOrEmpty
    }

    It 'extracts a valid version from checkver output' {
        Get-VersionFromCheckverOutput -Output 'citron: 0237a9b88' -AppName 'citron' | Should -Be '0237a9b88'
    }
}
