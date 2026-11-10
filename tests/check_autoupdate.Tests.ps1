Describe 'Test-UrlAccessibility' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\check-autoupdate.ps1'
        . (Get-TestFunctionScriptBlock -Path $scriptPath -Name 'Test-UrlAccessibility')
    }

    It 'accepts successful 2xx responses' {
        Mock Invoke-WebRequest {
            [PSCustomObject]@{ StatusCode = 204 }
        }

        Test-UrlAccessibility -Url 'https://example.test/download' | Should -BeTrue
    }

    It 'returns false for non-success status codes' {
        Mock Invoke-WebRequest {
            [PSCustomObject]@{ StatusCode = 404 }
        }

        Test-UrlAccessibility -Url 'https://example.test/missing' | Should -BeFalse
    }

    It 'returns false for connection errors without terminating the check run' {
        Mock Invoke-WebRequest {
            throw 'request failed'
        }

        Test-UrlAccessibility -Url 'https://example.test/unavailable' | Should -BeFalse
    }
}
