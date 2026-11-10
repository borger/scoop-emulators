Describe 'Invoke-ManifestCreation' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $libraryPath = Join-Path $PSScriptRoot '..\bin\lib-releasehelpers.ps1'
        . (Get-TestFunctionScriptBlock -Path $libraryPath -Name 'Invoke-PowerShellScript')
        $scriptPath = Join-Path $PSScriptRoot '..\bin\handle-issue.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Test-ManifestRequest',
                    'Get-ManifestNamesFromIssue',
                    'Invoke-ManifestCreation',
                    'Invoke-GitCommand',
                    'Get-AutofixResultStatus',
                    'Publish-AutofixBranch',
                    'New-PullRequest'
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

        Test-ManifestRequest -Issue @{
            labels = @(@{ name = 'package-request' })
            title  = ''
            body   = ''
        } | Should -BeTrue
    }

    It 'requires request context before treating a GitHub link as a manifest request' {
        Test-ManifestRequest -Issue @{
            labels = @(@{ name = 'bug' })
            title  = 'Installation error'
            body   = 'Source repository: https://github.com/owner/repo'
        } | Should -BeFalse

        Test-ManifestRequest -Issue @{
            labels = @()
            title  = 'Please add this emulator'
            body   = 'Repository: https://github.com/owner/repo'
        } | Should -BeTrue
    }

    It 'extracts complete hyphenated manifest names and removes duplicates' {
        $names = @(Get-ManifestNamesFromIssue -Title 'Fix duckstation-preview.json' `
                -Body 'Also check bucket\cemu-dev.json and app duckstation-preview')

        $names | Should -Be @('duckstation-preview', 'cemu-dev')
    }

    It 'distinguishes changed manifests from successful no-op auto-fixes' {
        Get-AutofixResultStatus -ExitCode 0 -BeforeHash 'before' -AfterHash 'after' |
            Should -Be 'SUCCESS'
        Get-AutofixResultStatus -ExitCode 0 -BeforeHash 'same' -AfterHash 'same' |
            Should -Be 'UP_TO_DATE'
        Get-AutofixResultStatus -ExitCode 2 -BeforeHash 'before' -AfterHash 'after' |
            Should -Be 'FAILED'
    }

    It 'publishes only the changed manifest paths' {
        $script:gitCommands = @()
        Mock Invoke-GitCommand {
            $script:gitCommands += ($Arguments -join ' ')
            if ($Arguments[0] -eq 'status') {
                return ' M bucket/app.json'
            }
        }

        $manifestPath = Join-Path $TestDrive 'bucket\app.json'
        Publish-AutofixBranch -ManifestPaths @($manifestPath) -BranchName 'issue-42-autofix' `
            -CommitMessage 'fix: app' -RepositoryRoot $TestDrive

        $script:gitCommands | Should -Be @(
            'status --porcelain --untracked-files=all',
            'checkout -b issue-42-autofix',
            'add -- bucket/app.json',
            'commit --only --message fix: app -- bucket/app.json',
            'push --set-upstream origin issue-42-autofix'
        )
    }

    It 'refuses to publish unrelated worktree changes' {
        Mock Invoke-GitCommand {
            return ' M bucket/unrelated.json'
        }

        {
            Publish-AutofixBranch -ManifestPaths @(Join-Path $TestDrive 'bucket\app.json') `
                -BranchName 'issue-42-autofix' -CommitMessage 'fix: app' -RepositoryRoot $TestDrive
        } | Should -Throw '*Refusing to publish unrelated worktree change*'
    }

    It 'uses the GitHub repository default branch when creating a pull request' {
        $script:pullRequestPayload = $null
        Mock Invoke-RestMethod {
            return @{ default_branch = 'main' }
        }
        Mock Invoke-WebRequest {
            $script:pullRequestPayload = $Body | ConvertFrom-Json
            return @{ Content = '{"number":123}' }
        }

        $number = New-PullRequest -Title 'Fix app' -Body 'Details' -HeadBranch 'issue-42' `
            -Repo 'owner/repo' -Token 'test-token'

        $number | Should -Be 123
        $script:pullRequestPayload.base | Should -Be 'main'
    }

    It 'surfaces pull request creation failures' {
        Mock Invoke-RestMethod {
            return @{ default_branch = 'main' }
        }
        Mock Invoke-WebRequest {
            throw 'request failed'
        }

        {
            New-PullRequest -Title 'Fix app' -Body 'Details' -HeadBranch 'issue-42' `
                -Repo 'owner/repo' -Token 'test-token'
        } | Should -Throw '*Failed to create pull request*'
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
