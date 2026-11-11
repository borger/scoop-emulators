Describe 'JSON manifest formatting' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\formatjson.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Format-JsonManifest',
                    'Get-FormatJsonOptions',
                    'Get-JsonManifestFiles'
                ))) {
            . $functionBlock
        }
    }

    It 'uses Scoop formatting for arrays while preserving manifest values' {
        $directory = Join-Path $TestDrive 'formatted-manifests'
        $null = New-Item -ItemType Directory -Path $directory
        $manifestPath = Join-Path $directory 'test.json'
        Set-Content -LiteralPath $manifestPath -Value '{"persist":["mods","save"],"shortcuts":[["game.exe","Game"]]}' -NoNewline

        & $scriptPath -Dir $directory -App 'test'

        $formatted = Get-Content -LiteralPath $manifestPath -Raw
        $formatted | Should -Match '"persist": \[\r?\n'
        $formatted | Should -Match '"shortcuts": \[\r?\n'

        $parsed = $formatted | ConvertFrom-Json
        $parsed.persist.Count | Should -Be 2
        $parsed.shortcuts[0][0] | Should -Be 'game.exe'
        $parsed.shortcuts[0][1] | Should -Be 'Game'
    }

    It 'rejects missing option values and unknown options rather than formatting all manifests' {
        { Get-FormatJsonOptions -Arguments @('-App') -DefaultDirectory '.\bucket' } |
            Should -Throw '*Option -App requires*'
        { Get-FormatJsonOptions -Arguments @('-Dir') -DefaultDirectory '.\bucket' } |
            Should -Throw '*Option -Dir requires*'
        { Get-FormatJsonOptions -Arguments @('-Ap', 'game') -DefaultDirectory '.\bucket' } |
            Should -Throw '*Unknown option: -Ap*'
    }

    It 'parses the app and directory options' {
        $options = Get-FormatJsonOptions -Arguments @('-Dir', '.\bucket', '-App', 'game') -DefaultDirectory '.\default'

        $options.Directory | Should -Be '.\bucket'
        $options.App | Should -Be 'game'
    }

    It 'fails when a requested app has no matching manifest' {
        $directory = Join-Path $TestDrive 'manifests'
        $null = New-Item -ItemType Directory -Path $directory

        { Get-JsonManifestFiles -Directory $directory -App 'missing' } |
            Should -Throw "*No manifest files matched 'missing.json'*"
    }
}
