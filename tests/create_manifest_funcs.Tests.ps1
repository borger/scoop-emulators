Describe 'Manifest creation helper functions' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\create-manifest.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Test-RepoUrl',
                    'Test-NightlyBuild',
                    'Get-AssetScore',
                    'Select-ArchitectureAssets'
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
        Get-AssetScore -Name 'installer.exe' | Should -Be -50
        Get-AssetScore -Name 'app.dmg' | Should -Be -1
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
}
