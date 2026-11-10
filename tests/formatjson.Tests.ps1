Describe 'JSON array formatting' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\formatjson.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Get-JsonArrayEndIndex',
                    'Get-CompactJsonArray',
                    'Format-JsonArrays',
                    'Get-FormatJsonOptions',
                    'Get-JsonManifestFiles'
                ))) {
            . $functionBlock
        }
    }

    It 'compacts short scalar and nested arrays without changing string contents' {
        $json = @'
{
    "shortcuts": [
        [
            "app.exe",
            "App, [game]"
        ]
    ],
    "persist": [
        "mods",
        "save"
    ]
}
'@

        $formatted = Format-JsonArrays -Json $json
        $formatted | Should -Match '"shortcuts": \[\["app.exe", "App, \[game\]"\]\]'
        $formatted | Should -Match '"persist": \["mods", "save"\]'

        $parsed = ConvertFrom-Json $formatted
        $parsed.shortcuts[0][1] | Should -Be 'App, [game]'
        $parsed.persist.Count | Should -Be 2
    }

    It 'keeps long arrays and arrays of objects multiline' {
        $longValue = 'x' * 100
        $json = @"
{
    "long": [
        "$longValue",
        "tail"
    ],
    "objects": [
        {
            "name": "one"
        }
    ]
}
"@

        $formatted = Format-JsonArrays -Json $json
        $formatted | Should -Match '"long": \[\r?\n'
        $formatted | Should -Match '"objects": \[\r?\n'
    }

    It 'keeps multiple nested arrays multiline while compacting each entry' {
        $json = @'
{
    "bin": [
        [
            "first.exe",
            "first"
        ],
        [
            "second.exe",
            "second"
        ]
    ]
}
'@

        $formatted = Format-JsonArrays -Json $json
        $formatted | Should -Match '"bin": \[\r?\n\s+\["first.exe", "first"\],\r?\n\s+\["second.exe", "second"\]\r?\n'
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
