Describe 'Auto-fix validation helpers' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\autofix-manifest.ps1'
        $libraryPath = Join-Path $PSScriptRoot '..\bin\lib-releasehelpers.ps1'
        . (Get-TestFunctionScriptBlock -Path $libraryPath -Name 'Invoke-PowerShellScript')
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Invoke-ManifestInstallCheck',
                    'Publish-AutoFixFailureIssue',
                    'Add-Issue',
                    'Test-FixIntegrity',
                    'Get-IssueMarker',
                    'Get-GitHubApiHeaders',
                    'Get-OpenAutoFixIssues',
                    'New-GitHubIssue',
                    'Get-RepositoryInfo',
                    'Get-ReleaseAssetForArchitecture',
                    'Get-GitHubReleaseVersion',
                    'Test-VersionLooksValid'
                ))) {
            . $functionBlock
        }
    }

    It 'validates the manifest with retries disabled' {
        $script:installCall = $null
        Mock Invoke-PowerShellScript {
            $script:installCall = @{
                Path = $Path
                Arguments = @($ArgumentList)
            }
            [pscustomobject]@{ ExitCode = 0; Output = 'Installation successful' }
        }

        $result = Invoke-ManifestInstallCheck `
            -InstallScriptPath 'C:\bucket\bin\check-manifest-install.ps1' `
            -ManifestPath 'C:\bucket\bucket\sample.json' `
            -AppName 'sample'

        $result.ExitCode | Should -Be 0
        $script:installCall.Path | Should -Be 'C:\bucket\bin\check-manifest-install.ps1'
        $script:installCall.Arguments | Should -Contain '-AutoRetry'
        $script:installCall.Arguments | Should -Contain 'False'
        Should -Invoke Invoke-PowerShellScript -Times 1 -Exactly
    }

    It 'creates a tracking issue for an autofix validation failure' {
        $script:issues = @()
        $script:AutoCreateIssues = $true
        $script:NotifyOnIssues = $false
        $script:IssueLog = ''
        $script:GitHubRepo = 'owner/repo'
        $script:GitHubToken = 'test-token'

        Mock New-GitHubIssue { return 42 }

        Publish-AutoFixFailureIssue `
            -Title 'Auto-fix failed for sample - Copilot review needed' `
            -Description 'The install validation failed.'

        Should -Invoke New-GitHubIssue -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'Auto-fix failed for sample - Copilot review needed' -and
            $IssueType -eq 'manifest-error' -and
            $TagCopilot
        }
    }

    It 'uses a supported label when creating the tracking issue' {
        $script:appName = 'sample'
        $script:issues = @()
        $script:createdPayload = $null
        Mock Get-OpenAutoFixIssues { return @() }
        Mock Get-IssueMarker { return '<!-- autofix-app: sample -->' }
        Mock Invoke-RestMethod {
            $script:createdPayload = $Body | ConvertFrom-Json
            [pscustomobject]@{ number = 42 }
        }

        $result = New-GitHubIssue `
            -Title 'Auto-fix failed for sample' `
            -Description 'Install validation failed.' `
            -Repository 'owner/repo' `
            -Token 'test-token' `
            -IssueType 'manifest-error' `
            -TagCopilot

        $result | Should -Be 42
        ($script:createdPayload.labels -join ',') | Should -Be 'bug'
    }

    It 'infers a GitHub repository for shorthand checkver manifests' {
        $manifest = [pscustomobject]@{
            checkver = 'github'
            homepage = 'https://github.com/xtamqispeak/KirbyRecomp'
        }

        $repository = Get-RepositoryInfo -Manifest $manifest

        $repository.Platform | Should -Be 'github'
        $repository.Path | Should -Be 'xtamqispeak/KirbyRecomp'
    }

    It 'selects renamed Windows x64 release assets' {
        $marioAsset = Get-ReleaseAssetForArchitecture -Assets @(
            [pscustomobject]@{ name = 'SuperMarioBrosRecomp-linux-x64.zip'; size = 1 }
            [pscustomobject]@{ name = 'SuperMarioBrosRecomp-windows-x64.zip'; size = 1 }
        ) -Architecture '64bit'
        $wonderAsset = Get-ReleaseAssetForArchitecture -Assets @(
            [pscustomobject]@{ name = 'SuperWonders-v0.4.0-Windows-x64.zip'; size = 1 }
            [pscustomobject]@{ name = 'SuperWonders-v0.4.0-Linux-x64.zip'; size = 1 }
        ) -Architecture '64bit'

        $marioAsset.name | Should -Be 'SuperMarioBrosRecomp-windows-x64.zip'
        $wonderAsset.name | Should -Be 'SuperWonders-v0.4.0-Windows-x64.zip'
    }

    It 'finds prerelease versions when GitHub has no latest stable release' {
        $script:releasesUrl = $null
        Mock Invoke-RestMethod {
            $script:releasesUrl = $Uri
            @(
                [pscustomobject]@{ draft = $true; tag_name = 'v9.9-alpha.9'; name = 'Draft release' }
                [pscustomobject]@{ draft = $false; tag_name = 'v0.5.3-alpha.5'; name = 'Savage Wind 0.5.3' }
                [pscustomobject]@{ draft = $false; tag_name = 'v0.5.2-alpha.5'; name = 'Savage Wind 0.5.2' }
            )
        }

        $version = Get-GitHubReleaseVersion `
            -Repository 'Revivedx/SavageWindRecomp' `
            -Regex 'v([\d.]+-alpha\.\d+)'

        $version | Should -Be '0.5.3-alpha.5'
        $script:releasesUrl | Should -Be 'https://api.github.com/repos/Revivedx/SavageWindRecomp/releases?per_page=100'
    }

    It 'creates an issue when install-manifest validation fails' {
        $script:issues = @()
        $script:appName = 'sample'
        $script:invokeCount = 0
        Mock Test-Path { return $true }
        Mock Invoke-PowerShellScript {
            $script:invokeCount++
            if ($script:invokeCount -eq 1) {
                [pscustomobject]@{ ExitCode = 0; Output = 'Manifest updated' }
            } else {
                [pscustomobject]@{ ExitCode = 1; Output = 'Install failed' }
            }
        }
        Mock Publish-AutoFixFailureIssue {}

        $result = Test-FixIntegrity `
            -ManifestPath 'C:\bucket\bucket\sample.json' `
            -AppName 'sample' `
            -ScriptDirectory 'C:\bucket\bin'

        $result | Should -BeFalse
        Should -Invoke Invoke-PowerShellScript -Times 2 -Exactly
        Should -Invoke Publish-AutoFixFailureIssue -Times 1 -Exactly -ParameterFilter {
            $Title -eq 'Auto-fix failed for sample - Copilot review needed' -and
            $Description -match 'check-manifest-install.ps1 failed'
        }
    }
}
