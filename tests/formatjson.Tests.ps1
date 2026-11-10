Describe 'JSON array formatting' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\formatjson.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Get-JsonArrayEndIndex',
                    'Get-CompactJsonArray',
                    'Format-JsonArrays'
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
}
