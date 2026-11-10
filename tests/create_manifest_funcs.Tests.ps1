Describe 'Manifest creation helper functions' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\create-manifest.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Write-Status',
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
                    'New-ScoopManifest'
                ))) {
            . $functionBlock
        }
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
}
