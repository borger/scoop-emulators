Describe 'Get-ReleaseChecksum' {
    BeforeAll {
        . "$PSScriptRoot\..\bin\lib-releasehelpers.ps1"
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

Describe 'ConvertFrom-ChecksumContent' {
    BeforeAll {
        . "$PSScriptRoot\..\bin\lib-releasehelpers.ps1"
    }

    It 'parses checksum-first and filename-first entries case-insensitively' {
        $content = @"
$('a' * 64)  dist/APP[1].ZIP
other.zip  $('B' * 64)
"@

        ConvertFrom-ChecksumContent -Content $content -TargetAssetName 'app[1].zip' |
            Should -Be ('a' * 64)
        ConvertFrom-ChecksumContent -Content $content -TargetAssetName 'other.zip' |
            Should -Be ('b' * 64)
    }

    It 'ignores checksum entries for filenames that only partially match' {
        $content = ('b' * 64) + '  app.zip.old'

        ConvertFrom-ChecksumContent -Content $content -TargetAssetName 'app.zip' |
            Should -BeNullOrEmpty
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
