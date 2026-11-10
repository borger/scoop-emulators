Describe 'Get-VersionFromCheckverOutput' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\autofix-manifest.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Get-VersionTokenFromText',
                    'Test-VersionLooksValid',
            'Get-VersionFromCheckverOutput',
            'ConvertTo-CanonicalVersion'
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

    It 'extracts and preserves version formats used by current bucket manifests' {
        $versions = @(
            '2609b',
            '2609-199',
            '9178-20261106',
            '4301-374cf8a',
            '20260419185636-585c49a',
            '20261106064855-ecc8507',
            '20261107-gbb4e9ac',
            '20261110150309-7021e18',
            '0.1.0-rc3',
            '1.20.4-4777-gefdf633d8a24',
            '1794272405.6a767ac43a'
        )

        foreach ($version in $versions) {
            $token = Get-VersionTokenFromText -Text "emulator: $version"
            $token | Should -Be $version
            Test-VersionLooksValid -v $token | Should -BeTrue
            ConvertTo-CanonicalVersion -RawVersion $token -Manifest $null -AppName '' | Should -Be $version
        }
    }
}
