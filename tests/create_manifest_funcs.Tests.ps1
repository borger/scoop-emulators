Describe 'Manifest creation helper functions' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\create-manifest.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Write-Status',
                    'Invoke-ManifestValidation',
                    'New-PullRequest',
                    'Test-RepoUrl',
                    'Test-NightlyBuild',
                    'Get-AssetScore',
                    'Select-ArchitectureAssets',
                    'Get-ArchiveExtension',
                    'Get-ManifestVersion',
                    'Get-ManifestCheckver',
                    'Get-ManifestAutoupdate',
                    'Get-ManifestPreInstall',
                    'Get-ManifestLicense',
                    'Get-ManifestArchitecture',
                    'New-ScoopManifest',
                    'Resolve-GitHubRepository',
                    'Get-GitHubApiHeaders',
                    'Get-GitHubApiBaseUrl',
                    'Get-GitHubDefaultBranch',
                    'Invoke-GitHubPullRequestCreate'
                ))) {
            . $functionBlock
        }
        $libraryPath = Join-Path $PSScriptRoot '..\bin\lib-releasehelpers.ps1'
        . (Get-TestFunctionScriptBlock -Path $libraryPath -Name 'Invoke-PowerShellScript')

        function git {}
    }

    It 'accepts supported repository URLs and rejects unsupported values' {
        Test-RepoUrl -Url 'https://github.com/owner/repo' | Should -BeTrue
        Test-RepoUrl -Url 'https://gitlab.com/owner/repo' | Should -BeTrue
        Test-RepoUrl -Url 'https://sourceforge.net/projects/project' | Should -BeTrue
        Test-RepoUrl -Url 'https://example.com/owner/repo' | Should -BeFalse
        Test-RepoUrl -Url '' | Should -BeFalse
    }

    It 'identifies nightly build tags' {
        Test-NightlyBuild -TagName 'nightly' | Should -BeTrue
        Test-NightlyBuild -TagName 'main' | Should -BeTrue
        Test-NightlyBuild -TagName '1.2.3' | Should -BeFalse
    }

    It 'scores preferred archives and rejects unsupported assets' {
        Get-AssetScore -Name 'app-win-x64.zip' | Should -Be 100
        Get-AssetScore -Name 'GoldenEye-Recomp-Win.rar' | Should -Be 70
        Get-AssetScore -Name 'app-win-x64.tar.xz' | Should -Be 65
        Get-AssetScore -Name 'app-win-x64.msi' | Should -Be 50
        Get-AssetScore -Name 'installer.exe' | Should -Be -50
        Get-AssetScore -Name 'app.dmg' | Should -Be -1
    }

    It 'recognizes compound archive extensions' {
        Get-ArchiveExtension -ArchivePath 'app.tar.gz' | Should -Be '.tar.gz'
        Get-ArchiveExtension -ArchivePath 'app.TAR.GZ' | Should -Be '.tar.gz'
        Get-ArchiveExtension -ArchivePath 'app.zip' | Should -Be '.zip'
    }

    It 'selects the preferred asset for each supported architecture' {
        $assets = @(
            @{ name = 'app-win-x64.exe' }
            @{ name = 'app-win-x64.zip' }
            @{ name = 'app-win-x86.zip' }
            @{ name = 'app-win-arm64.zip' }
            @{ name = 'app-mac.dmg' }
        )

        $selection = Select-ArchitectureAssets -Assets $assets

        $selection['64bit'].name | Should -Be 'app-win-x64.zip'
        $selection['32bit'].name | Should -Be 'app-win-x86.zip'
        $selection['arm64'].name | Should -Be 'app-win-arm64.zip'
    }

    It 'selects supported Windows RAR packages when they are the only asset' {
        $selection = Select-ArchitectureAssets -Assets @(
            @{ name = 'GoldenEye-Recomp-Win.rar' }
        )

        $selection['64bit'].name | Should -Be 'GoldenEye-Recomp-Win.rar'
    }

    It 'uses the asset URL when a browser download URL is unavailable' {
        $repositoryInfo = @{ Version = '1.2.3' }
        $assets = @{
            '64bit' = @{ name = 'app-1.2.3.zip'; url = 'https://example.test/download/app-1.2.3.zip' }
        }

        $result = Get-ManifestAutoupdate -RepositoryInfo $repositoryInfo -ArchitectureAssets $assets

        $result.architecture['64bit'].url | Should -Be 'https://example.test/download/app-$version.zip'
    }

    It 'extracts the commit after a numeric timestamp in a nightly asset name' {
        $repositoryInfo = @{ Version = 'nightly'; CommitHash = 'fallback1234567' }
        $asset = @{ name = 'app-20261106064855-ecc8507-win64.zip' }

        Get-ManifestVersion -RepositoryInfo $repositoryInfo -Asset $asset -BuildType 'nightly' |
            Should -Be 'ecc8507'
    }

    It 'preserves a concrete version for a nightly build' {
        $repositoryInfo = @{ Version = '20261107-gbb4e9ac'; CommitHash = 'fallback1234567' }
        $asset = @{ name = 'app-abcdef0-win64.zip' }

        Get-ManifestVersion -RepositoryInfo $repositoryInfo -Asset $asset -BuildType 'nightly' |
            Should -Be '20261107-gbb4e9ac'
    }

    It 'reports an asset without a usable download URL' {
        $repositoryInfo = @{ Version = '1.2.3' }
        $assets = @{ '64bit' = @{ name = 'app-1.2.3.zip' } }

        {
            Get-ManifestAutoupdate -RepositoryInfo $repositoryInfo -ArchitectureAssets $assets
        } | Should -Throw "*app-1.2.3.zip*has no download URL*"
    }

    It 'builds a manifest from an ARM64-only release asset' {
        $repositoryInfo = @{
            Version    = 'nightly'
            Repo       = 'arm-emulator'
            RepoUrl    = 'https://github.com/owner/arm-emulator'
            Platform   = 'github'
            Owner      = 'owner'
            TagName    = 'nightly'
            CommitHash = 'abcdef0123456789'
        }
        $assets = @{
            'arm64' = @{
                name                 = 'arm-emulator-abcdef0-win-arm64.zip'
                browser_download_url = 'https://example.test/arm-emulator-abcdef0-win-arm64.zip'
            }
        }

        $manifest = New-ScoopManifest -RepositoryInfo $repositoryInfo `
            -ArchitectureAssets $assets `
            -ExecutableName 'emulator.exe' `
            -PersistItems @() `
            -Metadata @{ License = 'MIT' } `
            -Platform '' `
            -BuildType 'nightly' `
            -UsesStandardFolders $true

        $manifest.version | Should -Be 'abcdef0'
        $manifest.architecture.arm64.url | Should -Be 'https://example.test/arm-emulator-abcdef0-win-arm64.zip'
    }

    It 'writes each message from a pipeline separately' {
        $originalOutput = [System.Console]::Out
        $writer = New-Object System.IO.StringWriter
        try {
            [System.Console]::SetOut($writer)
            @('first', 'second') | Write-Status -Level Info
            $output = $writer.ToString()
        } finally {
            [System.Console]::SetOut($originalOutput)
            $writer.Dispose()
        }

        $output | Should -Be "first`r`nsecond`r`n"
    }

    It 'creates pull requests through the GitHub REST API' {
        $script:apiRequests = @()
        Mock Invoke-RestMethod {
            $script:apiRequests += [PSCustomObject]@{
                Uri     = $Uri
                Method  = $Method
                Headers = $Headers
                Body    = $Body
            }
            if ($Method -eq 'Get') {
                return [PSCustomObject]@{ default_branch = 'main' }
            }
            return [PSCustomObject]@{ html_url = 'https://github.com/owner/repo/pull/42' }
        }

        $defaultBranch = Get-GitHubDefaultBranch -Repository 'owner/repo' -Token 'test-token'
        $url = Invoke-GitHubPullRequestCreate -Repository 'owner/repo' -Token 'test-token' `
            -Head 'owner:add-app-1.2.3' -Base $defaultBranch -Title 'Title' -Body "Body`n"

        $defaultBranch | Should -Be 'main'
        $url | Should -Be 'https://github.com/owner/repo/pull/42'
        $apiRequests.Count | Should -Be 2
        $apiRequests[1].Uri | Should -Be 'https://api.github.com/repos/owner/repo/pulls'
        $apiRequests[1].Headers.Authorization | Should -Be 'Bearer test-token'
        $payload = $apiRequests[1].Body | ConvertFrom-Json
        $payload.head | Should -Be 'owner:add-app-1.2.3'
        $payload.base | Should -Be 'main'
        $payload.body | Should -Be "Body`n"
    }

    It 'resolves a GitHub repository from an HTTPS or SSH origin remote' {
        $script:remoteUrl = 'https://github.com/owner/repo.git'
        Mock git {
            $global:LASTEXITCODE = 0
            $script:remoteUrl
        }

        Resolve-GitHubRepository -Repository '' | Should -Be 'owner/repo'

        $script:remoteUrl = 'git@github.com:owner/repo.git'
        Resolve-GitHubRepository -Repository '' | Should -Be 'owner/repo'
    }

    It 'surfaces GitHub API pull request creation failures' {
        Mock Invoke-RestMethod { throw 'Forbidden' }

        {
            Invoke-GitHubPullRequestCreate -Repository 'owner/repo' -Token 'test-token' `
                -Head 'owner:branch' -Base 'main' -Title 'Title' -Body 'Body'
        } | Should -Throw "*GitHub API failed to create a pull request*Forbidden*"
    }

    It 'runs validation scripts in child processes and records their exit codes' {
        $script:validationCalls = @()
        Mock Test-Path { return $true }
        Mock Invoke-PowerShellScript {
            $script:validationCalls += $Path
            [PSCustomObject]@{ ExitCode = 0; Output = 'passed' }
        }

        $result = Invoke-ManifestValidation -ManifestPath 'bucket\app.json' `
            -BucketDirectory 'bucket' -AppName 'app' -ScriptDirectory $TestDrive

        $result.AllPassed | Should -BeTrue
        $result.Results.Count | Should -Be 3
        $script:validationCalls.Count | Should -Be 3
        Should -Invoke Invoke-PowerShellScript -Times 3
    }

    It 'continues validation after a child script exits with failure' {
        $script:validationCalls = @()
        Mock Test-Path { return $true }
        Mock Invoke-PowerShellScript {
            $script:validationCalls += $Path
            $exitCode = if ($Path -like '*check-autoupdate.ps1') { 1 } else { 0 }
            [PSCustomObject]@{ ExitCode = $exitCode; Output = 'validation output' }
        }

        $result = Invoke-ManifestValidation -ManifestPath 'bucket\app.json' `
            -BucketDirectory 'bucket' -AppName 'app' -ScriptDirectory $TestDrive

        $result.AllPassed | Should -BeFalse
        $result.Results.Status | Should -Be @('PASS', 'FAIL', 'PASS')
        $script:validationCalls.Count | Should -Be 3
    }

    It 'continues through scripts that call exit in a separate PowerShell process' {
        $scriptDirectory = Join-Path $TestDrive 'validation scripts'
        New-Item -ItemType Directory -Path $scriptDirectory | Out-Null
        @'
Write-Output 'checkver completed'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $scriptDirectory 'checkver.ps1')
        @'
Write-Output 'autoupdate failed'
exit 1
'@ | Set-Content -LiteralPath (Join-Path $scriptDirectory 'check-autoupdate.ps1')
        @'
Write-Output 'install completed'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $scriptDirectory 'check-manifest-install.ps1')

        $result = Invoke-ManifestValidation -ManifestPath 'bucket\app.json' `
            -BucketDirectory 'bucket' -AppName 'app' -ScriptDirectory $scriptDirectory

        $result.AllPassed | Should -BeFalse
        $result.Results.Status | Should -Be @('PASS', 'FAIL', 'PASS')
        $result.Results[1].Message | Should -Match 'autoupdate failed'
    }

    It 'does not report all checks passed when a validation script is missing' {
        Mock Test-Path { return $false }

        $result = Invoke-ManifestValidation -ManifestPath 'bucket\app.json' `
            -BucketDirectory 'bucket' -AppName 'app' -ScriptDirectory $TestDrive

        $result.AllPassed | Should -BeFalse
        $result.Results.Status | Should -Be @('SKIP', 'SKIP', 'SKIP')
    }

    It 'surfaces branch push failures instead of reporting PR creation as successful' {
        Mock Invoke-RestMethod {
            [PSCustomObject]@{ default_branch = 'main' }
        }
        Mock git {
            $script:gitCommands += ($args -join ' ')
            $global:LASTEXITCODE = if ($args[0] -eq 'push') { 1 } else { 0 }
        }
        $script:gitCommands = @()

        {
            New-PullRequest -ManifestPath 'bucket\app.json' -AppName 'app' `
                -Version '1.2.3' -RepoUrl 'https://github.com/owner/app' `
                -Token 'test-token' -Repository 'owner/repo'
        } | Should -Throw '*Failed to push the manifest branch*'

        $script:gitCommands | Should -Be @(
            'checkout -b add-app-1.2.3',
            'add bucket\app.json',
            'commit -m feat(app): add manifest for app v1.2.3',
            'push -u origin add-app-1.2.3'
        )
    }

    It 'formats the PR body with actual newlines' {
        Mock git { $global:LASTEXITCODE = 0 }
        Mock Invoke-RestMethod {
            if ($Method -eq 'Get') {
                return [PSCustomObject]@{ default_branch = 'main' }
            }
            $script:capturedPullRequestBody = (ConvertFrom-Json $Body).body
            return [PSCustomObject]@{ html_url = 'https://github.com/owner/repo/pull/42' }
        }

        $script:capturedPullRequestBody = $null
        $result = New-PullRequest -ManifestPath 'bucket\app.json' -AppName 'app' `
            -Version '1.2.3' -RepoUrl 'https://github.com/owner/app' `
            -Token 'test-token' -Repository 'owner/repo'

        $result | Should -Be 'https://github.com/owner/repo/pull/42'
        $script:capturedPullRequestBody | Should -Be "Added manifest for [app](https://github.com/owner/app) version 1.2.3`n`nAuto-generated by create-manifest.ps1."
    }

    It 'creates a requested pull request before marking the issue as manifest-created' {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path $scriptPath),
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors | Should -BeNullOrEmpty

        $pullRequestCall = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'New-PullRequest' -and
                $node.Extent.Text.Contains('-ManifestPath $manifestPath')
            }, $true)
        $successIssueUpdate = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq 'Update-IssueComment' -and
                $node.Extent.Text.Contains('-Comment $commentText')
            }, $true)

        $pullRequestCall | Should -Not -BeNullOrEmpty
        $successIssueUpdate | Should -Not -BeNullOrEmpty
        $pullRequestCall.Extent.StartOffset | Should -BeLessThan $successIssueUpdate.Extent.StartOffset
    }
}
