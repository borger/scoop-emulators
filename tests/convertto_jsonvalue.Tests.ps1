Describe 'ConvertTo-JsonValue' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\create-manifest.ps1'
        . (Get-TestFunctionScriptBlock -Path $scriptPath -Name 'ConvertTo-JsonValue')
    }

    It 'serializes null' {
        ConvertTo-JsonValue -Value $null | Should -Be 'null'
    }

    It 'round-trips strings with quotes and backslashes' {
        $value = 'Line1"WithQuote\Backslash'

        (ConvertFrom-Json (ConvertTo-JsonValue -Value $value)) | Should -Be $value
    }

    It 'round-trips numeric and boolean values' {
        (ConvertFrom-Json (ConvertTo-JsonValue -Value 12345)) | Should -Be 12345
        (ConvertFrom-Json (ConvertTo-JsonValue -Value 3.14159)) | Should -Be 3.14159
        (ConvertFrom-Json (ConvertTo-JsonValue -Value $true)) | Should -BeTrue
    }

    It 'serializes empty arrays and objects' {
        ConvertTo-JsonValue -Value @() | Should -Be '[]'
        (ConvertFrom-Json (ConvertTo-JsonValue -Value @{})) | Should -BeOfType ([System.Management.Automation.PSCustomObject])
    }

    It 'round-trips nested arrays and hashtable values' {
        $value = @{
            array = @(@(1, 2), @(3, 4))
            text  = 'x"y'
        }

        $parsed = ConvertFrom-Json (ConvertTo-JsonValue -Value $value)
        $parsed.array[0][1] | Should -Be 2
        $parsed.array[1][0] | Should -Be 3
        $parsed.text | Should -Be 'x"y'
    }

    It 'keeps the parsed array value independent of indentation' {
        $value = @('a', 'b', 'c')
        $parsedWithoutIndent = ConvertFrom-Json (ConvertTo-JsonValue -Value $value -Indent 0)
        $parsedWithIndent = ConvertFrom-Json (ConvertTo-JsonValue -Value $value -Indent 10)

        ($parsedWithoutIndent -join ',') | Should -Be ($parsedWithIndent -join ',')
    }
}
