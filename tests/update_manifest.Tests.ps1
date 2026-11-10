Describe 'Update-ManifestUrls' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\update-manifest.ps1'
        foreach ($functionBlock in (Get-TestFunctionScriptBlock -Path $scriptPath -Name @(
                    'Resolve-ManifestUrl',
                    'Update-ManifestUrls'
                ))) {
            . $functionBlock
        }
    }

    It 'updates nested URLs for every supported architecture' {
        $manifest = @'
{
  "url": "https://example.test/$version/app.zip",
  "architecture": {
    "64bit": { "url": "https://example.test/64/$version/$matchCommit.zip" },
    "32bit": { "url": "https://example.test/32/$version/$matchCommit.zip" },
    "arm64": { "url": "https://example.test/arm/$version/$matchCommit.zip" }
  },
  "autoupdate": {
    "url": "https://example.test/$version/app.zip",
    "architecture": {
      "64bit": { "url": "https://example.test/64/$version/$matchCommit.zip" },
      "32bit": { "url": "https://example.test/32/$version/$matchCommit.zip" },
      "arm64": { "url": "https://example.test/arm/$version/$matchCommit.zip" }
    }
  }
}
'@ | ConvertFrom-Json

        Update-ManifestUrls -Manifest $manifest -Version '2.0.0-abcdef0' -CommitToken 'abcdef0' | Out-Null

        $manifest.architecture.'64bit'.url | Should -Be 'https://example.test/64/2.0.0-abcdef0/abcdef0.zip'
        $manifest.architecture.'32bit'.url | Should -Be 'https://example.test/32/2.0.0-abcdef0/abcdef0.zip'
        $manifest.architecture.arm64.url | Should -Be 'https://example.test/arm/2.0.0-abcdef0/abcdef0.zip'
        $manifest.url | Should -Be 'https://example.test/2.0.0-abcdef0/app.zip'
    }

    It 'supports direct architecture autoupdate entries' {
        $manifest = @'
{
  "architecture": {
    "arm64": { "url": "https://example.test/old-arm64.zip" }
  },
  "autoupdate": {
    "arm64": { "url": "https://example.test/$version-arm64.zip" }
  }
}
'@ | ConvertFrom-Json

        Update-ManifestUrls -Manifest $manifest -Version '3.2.1' | Out-Null

        $manifest.architecture.arm64.url | Should -Be 'https://example.test/3.2.1-arm64.zip'
    }

    It 'fails explicitly when an autoupdate architecture has no manifest counterpart' {
        $manifest = @'
{
  "architecture": {},
  "autoupdate": {
    "architecture": {
      "arm64": { "url": "https://example.test/$version-arm64.zip" }
    }
  }
}
'@ | ConvertFrom-Json

        {
            Update-ManifestUrls -Manifest $manifest -Version '3.2.1'
        } | Should -Throw "*'arm64'*no matching architecture*"
    }
}
