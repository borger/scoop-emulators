Describe 'checkver report token parsing' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\checkver-report.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Get-TokenFromText',
                    'Test-TokenValid'
                ))) {
            . $functionBlock
        }
    }

    It 'recognizes version forms currently used in the bucket' {
        $versions = @(
            '2609b',
            '2609-199',
            '4301-374cf8a',
            '20260419185636-585c49a',
            '20261107-gbb4e9ac',
            '0.1.0-rc3',
            '1.20.4-4777-gefdf633d8a24',
            '1794272405.6a767ac43a'
        )

        foreach ($version in $versions) {
            $token = Get-TokenFromText "app: $version"
            $token | Should -Be $version
            Test-TokenValid $token | Should -BeTrue
        }
    }

    It 'does not treat an HTTP 404 error as a valid version' {
        $token = Get-TokenFromText 'app: The remote server returned an error: (404) Not Found.'

        $token | Should -BeNullOrEmpty
        Test-TokenValid $token | Should -BeFalse
    }
}
