Describe 'Get-ReleaseChecksum' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\lib-releasehelpers.ps1'
        . (Get-TestFunctionScriptBlock -Path $scriptPath -Name 'Get-ReleaseChecksum')
    }

    It 'matches checksum filenames exactly and case-insensitively' {
        Mock Invoke-RestMethod {
            ('a' * 64) + '  dist/APP[1].ZIP'
        }
        $assets = @(
            @{ name = 'checksums.sha256'; browser_download_url = 'https://example.test/checksums.sha256' }
        )

        Get-ReleaseChecksum -Assets $assets -TargetAssetName 'app[1].zip' |
            Should -Be ('a' * 64)
    }

    It 'does not use a checksum for a partially matching filename' {
        Mock Invoke-RestMethod {
            ('b' * 64) + '  app.zip.old'
        }
        $assets = @(
            @{ name = 'checksums.sha256'; browser_download_url = 'https://example.test/checksums.sha256' }
        )

        Get-ReleaseChecksum -Assets $assets -TargetAssetName 'app.zip' |
            Should -BeNullOrEmpty
    }

    It 'supports filename-first checksum lines and normalizes uppercase hashes' {
        Mock Invoke-RestMethod {
            'APP[1].ZIP  ' + ('A' * 64)
        }
        $assets = @(
            @{ name = 'checksums.sha256'; browser_download_url = 'https://example.test/checksums.sha256' }
        )

        Get-ReleaseChecksum -Assets $assets -TargetAssetName 'app[1].zip' |
            Should -Be ('a' * 64)
    }

    It 'does not request checksums without a target asset name' {
        Mock Invoke-RestMethod {
            throw 'Unexpected checksum request'
        }

        Get-ReleaseChecksum -Assets @(
            @{ name = 'checksums.sha256'; browser_download_url = 'https://example.test/checksums.sha256' }
        ) -TargetAssetName '' | Should -BeNullOrEmpty

        Should -Invoke Invoke-RestMethod -Times 0
    }
}

Describe 'Get-DirectoryArgumentList' {
    BeforeAll {
        . "$PSScriptRoot\..\bin\lib-releasehelpers.ps1"
    }

    It 'preserves an explicitly supplied directory argument' {
        $arguments = @(Get-DirectoryArgumentList -Arguments @('-App', 'gopher64', '-Dir', 'custom-bucket') `
                -DefaultDirectory 'bucket')

        $arguments | Should -Be @('-App', 'gopher64', '-Dir', 'custom-bucket')
    }

    It 'adds the default directory without changing other arguments' {
        $arguments = @(Get-DirectoryArgumentList -Arguments @('-App', 'gopher64') -DefaultDirectory 'bucket')

        $arguments | Should -Be @('-Dir', 'bucket', '-App', 'gopher64')
    }
}
