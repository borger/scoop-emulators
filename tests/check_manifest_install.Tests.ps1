Describe 'Test-UrlExists' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\check-manifest-install.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Test-UrlExists',
                    'Resolve-ManifestAssetUrl',
                    'Get-ManifestAssetUrls'
                ))) {
            . $functionBlock
        }
    }

    It 'returns false for an HTTP 404 response' {
        $exception = New-Object System.Exception 'Not found'
        $exception | Add-Member -MemberType NoteProperty -Name Response -Value ([pscustomobject]@{ StatusCode = 404 })
        Mock Invoke-WebRequest { throw $exception }

        Test-UrlExists -Url 'https://example.test/missing' | Should -BeFalse
    }

    It 'propagates non-404 request failures' {
        $exception = New-Object System.Exception 'Network unavailable'
        Mock Invoke-WebRequest { throw $exception }

        { Test-UrlExists -Url 'https://example.test/offline' } | Should -Throw 'Network unavailable'
    }

    It 'returns true when the URL responds successfully' {
        Mock Invoke-WebRequest { [pscustomobject]@{} }

        Test-UrlExists -Url 'https://example.test/available' | Should -BeTrue
    }

    It 'checks generic root URLs and substitutes the current version' {
        $manifest = @'
{
  "version": "2.3.4",
  "url": "https://example.test/old/app.zip",
  "autoupdate": {
    "url": "https://example.test/$version/app.zip"
  }
}
'@ | ConvertFrom-Json

        $urls = @(Get-ManifestAssetUrls -Manifest $manifest)

        $urls | Should -Contain 'https://example.test/2.3.4/app.zip'
        $urls.Count | Should -Be 1
    }

    It 'resolves match placeholders from concrete URLs and includes architectures without templates' {
        $manifest = @'
{
  "version": "1.5.0",
  "architecture": {
    "64bit": { "url": "https://example.test/app-1.5.0-abcdef0-x64.zip" },
    "32bit": { "url": "https://example.test/app-1.5.0-x86.zip" },
    "arm64": { "url": "https://example.test/app-1.5.0-arm64.zip" }
  },
  "autoupdate": {
    "architecture": {
      "64bit": { "url": "https://example.test/app-$matchVersion-x64.zip" },
      "arm64": { "url": "https://example.test/app-$version-arm64.zip" }
    }
  }
}
'@ | ConvertFrom-Json

        $urls = @(Get-ManifestAssetUrls -Manifest $manifest)

        $urls | Should -Contain 'https://example.test/app-1.5.0-abcdef0-x64.zip'
        $urls | Should -Contain 'https://example.test/app-1.5.0-x86.zip'
        $urls | Should -Contain 'https://example.test/app-1.5.0-arm64.zip'
        $urls.Count | Should -Be 3
    }

    It 'uses the concrete generic URL when no autoupdate template exists' {
        $manifest = @'
{
  "version": "3.74",
  "url": "https://example.test/firmware/3.74/update.pup"
}
'@ | ConvertFrom-Json

        Get-ManifestAssetUrls -Manifest $manifest |
            Should -Be 'https://example.test/firmware/3.74/update.pup'
    }
}
