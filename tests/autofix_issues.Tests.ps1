Describe 'Get-OpenAutoFixIssues' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\autofix-manifest.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Get-GitHubApiHeaders',
                    'Get-OpenAutoFixIssues'
                ))) {
            . $functionBlock
        }
    }

    It 'retrieves later pages and filters pull requests' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*page=1') {
                return @(1..100 | ForEach-Object {
                        [pscustomobject]@{ number = $_; body = '' }
                    })
            }

            if ($Uri -like '*page=2') {
                return @(
                    [pscustomobject]@{ number = 101; body = '<!-- autofix-app: example -->' }
                    [pscustomobject]@{ number = 102; body = ''; pull_request = @{ url = 'https://example.test' } }
                )
            }

            throw "Unexpected issues page: $Uri"
        }

        $issues = Get-OpenAutoFixIssues -Repository 'owner/repo' -Token 'test-token'

        $issues.Count | Should -Be 101
        $issues[-1].number | Should -Be 101
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly
    }
}
