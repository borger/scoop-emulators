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

Describe 'Get-ManifestVersionFromCheckverOutput' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\update-manifest.ps1'
        . (Get-TestFunctionScriptBlock -Path $scriptPath -Name 'Get-ManifestVersionFromCheckverOutput')
    }

    It 'does not parse an HTTP error message as the latest version' {
        $output = 'app: The remote server returned an error: (404) Not Found.'

        Get-ManifestVersionFromCheckverOutput -Output $output -AppName 'app' |
            Should -BeNullOrEmpty
    }

    It 'extracts a version from a separate line after the app name' {
        $output = "app:`r`n2.3.4 (scoop version is 2.2.0)"

        Get-ManifestVersionFromCheckverOutput -Output $output -AppName 'app' |
            Should -Be '2.3.4'
    }
}
