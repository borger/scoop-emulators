Describe 'Invoke-PowerShellScript' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\lib-releasehelpers.ps1'
        . (Get-TestFunctionScriptBlock -Path $scriptPath -Name 'Invoke-PowerShellScript')
    }

    It 'captures output and a nonzero exit code without exiting the test process' {
        $childScript = Join-Path $TestDrive 'child script.ps1'
        @'
param([string]$Value)
Write-Output $Value
exit 7
'@ | Set-Content -LiteralPath $childScript

        $result = Invoke-PowerShellScript -Path $childScript -ArgumentList @('output from child')

        $result.ExitCode | Should -Be 7
        $result.Output | Should -Match 'output from child'
    }

    It 'reports a successful child process' {
        $childScript = Join-Path $TestDrive 'successful child.ps1'
        @'
Write-Output 'completed'
exit 0
'@ | Set-Content -LiteralPath $childScript

        $result = Invoke-PowerShellScript -Path $childScript

        $result.ExitCode | Should -Be 0
        $result.Output | Should -Match 'completed'
    }

    It 'fails clearly when the child script does not exist' {
        $missingScript = Join-Path $TestDrive 'missing script.ps1'

        {
            Invoke-PowerShellScript -Path $missingScript
        } | Should -Throw "*PowerShell script not found*"
    }
}

Describe 'Resolve-BucketPath' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\validate-and-merge.ps1'
        . (Get-TestFunctionScriptBlock -Path $scriptPath -Name 'Resolve-BucketPath')
    }

    It 'defaults to the directory containing the manifest' {
        $manifestPath = Join-Path (Join-Path $TestDrive 'bucket') 'app.json'

        Resolve-BucketPath -ManifestPath $manifestPath |
            Should -Be (Split-Path -Parent $manifestPath)
    }

    It 'preserves an explicitly supplied bucket path' {
        Resolve-BucketPath -ManifestPath 'C:\repo\bucket\app.json' -BucketPath 'C:\custom\bucket' |
            Should -Be 'C:\custom\bucket'
    }
}
