Describe 'Invoke-ManifestCreation' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $libraryPath = Join-Path $PSScriptRoot '..\bin\lib-releasehelpers.ps1'
        . (Get-TestFunctionScriptBlock -Path $libraryPath -Name 'Invoke-PowerShellScript')
        $scriptPath = Join-Path $PSScriptRoot '..\bin\handle-issue.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Test-ManifestRequest',
                    'Invoke-ManifestCreation'
                ))) {
            . $functionBlock
        }
    }

    It 'recognizes labels used by the emulator request workflow' {
        Test-ManifestRequest -Issue @{
            labels = @(@{ name = 'request-emulator' })
            title  = ''
            body   = ''
        } | Should -BeTrue

        Test-ManifestRequest -Issue @{
            labels = @(@{ name = 'add-app' })
            title  = ''
            body   = ''
        } | Should -BeTrue
    }

    It 'passes supported issue-creation options to the child script' {
        $childScript = Join-Path $TestDrive 'manifest creator.ps1'
        @'
param(
    [int]$IssueNumber,
    [string]$GitHubToken,
    [switch]$NonInteractive,
    [switch]$CreatePR
)
"issue=$IssueNumber;token=$GitHubToken;nonInteractive=$NonInteractive;createPR=$CreatePR"
'@ | Set-Content -LiteralPath $childScript

        $output = Invoke-ManifestCreation -IssueNumber 42 -GitHubToken 'test-token' -ScriptPath $childScript

        ($output | Out-String) | Should -Match 'issue=42;token=test-token;nonInteractive=True;createPR=True'
    }

    It 'surfaces a nonzero child process exit code' {
        $childScript = Join-Path $TestDrive 'failed manifest creator.ps1'
        'exit 7' | Set-Content -LiteralPath $childScript

        {
            Invoke-ManifestCreation -IssueNumber 42 -GitHubToken 'test-token' -ScriptPath $childScript
        } | Should -Throw '*exit code 7*'
    }
}
