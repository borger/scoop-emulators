Describe 'Get-AutofixRunStatus' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\run-autofix-bucket.ps1'
        . (Get-TestFunctionScriptBlock -Path $scriptPath -Name 'Get-AutofixRunStatus')
    }

    It 'treats a nonzero process exit as failure even when output suggests a fix' {
        Get-AutofixRunStatus -Output 'Manifest auto-fixed and saved' -ExitCode 2 |
            Should -Be 'failed'
    }

    It 'classifies a successful manifest change as fixed' {
        Get-AutofixRunStatus -Output 'Manifest auto-fixed and saved' -ExitCode 0 |
            Should -Be 'fixed'
    }

    It 'classifies rejected versions and otherwise successful runs' {
        Get-AutofixRunStatus -Output 'Extracted version looks invalid' -ExitCode 0 |
            Should -Be 'rejected'
        Get-AutofixRunStatus -Output 'No changes were needed' -ExitCode 0 |
            Should -Be 'up-to-date'
    }
}
